//
//  OAuthCallbackBroker.swift
//  MyEmail
//
//  Мост между `AppDelegate.application(_:open:)` и `AuthService`:
//    1. `AuthService` стартует OAuth → открывает auth URL в системном
//       браузере через `NSWorkspace.shared.open(_:)` → вызывает
//       `waitForCallback(expectedState:)` и висит на continuation'е.
//    2. Пользователь одобряет scope в Safari → Google редиректит на
//       `com.googleusercontent.apps.<CLIENT_ID>:/oauthredirect?code=…&state=…`.
//    3. macOS смотрит CFBundleURLTypes, находит, что этот scheme обрабатываем
//       мы, и запускает/переключает нас с URL в `application(_:open:)`.
//    4. `AppDelegate` зовёт `OAuthCallbackBroker.shared.deliver(_:)`.
//    5. Broker проверяет `state` и резюмит continuation → `AuthService`
//       продолжает со свежим callback URL, обменивает code на tokens.
//
//  Why not `ASWebAuthenticationSession`: на SwiftUI Settings scene anchor —
//  это private `AppKitWindow`, к которому AuthenticationServices не может
//  attach'ить свой in-app browser sheet. `start()` возвращает true, но
//  окно никогда не появляется. NSWorkspace+scheme-handler — тот же паттерн,
//  что у Mimestream/Airmail и рекомендованный Google для desktop apps
//  через iOS OAuth client type.
//

import AppKit
import Foundation

@MainActor
final class OAuthCallbackBroker {
    static let shared = OAuthCallbackBroker()

    private var continuation: CheckedContinuation<URL, Error>?
    private var expectedState: String?

    /// Window that was active when user clicked "Sign in with Google".
    /// After OAuth callback we restore focus here so the user doesn't
    /// lose the Add Account flow behind the main window.
    private weak var initiatingWindow: NSWindow?

    private init() {}

    /// §23: scheme+path only — strips the OAuth `code`/`state` query so the
    /// callback URL can be logged without leaking the authorization grant.
    nonisolated static func redactedURL(_ url: URL) -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        return comps?.string ?? "\(url.scheme ?? "")://\(url.path)"
    }

    // MARK: - Waiter side (AuthService)

    /// Приостанавливает поток до прихода callback URL с матчинг-state.
    /// Если уже висит предыдущий waiter — он отменяется (AuthError.userCancelled).
    func waitForCallback(expectedState: String) async throws -> URL {
        if let old = continuation {
            LogService.shared.log(
                .warning,
                .auth,
                "New OAuth wait cancels previous one",
                detail: nil
            )
            self.continuation = nil
            self.expectedState = nil
            old.resume(throwing: AuthError.userCancelled)
        }

        // Remember the window the user is looking at (Settings with Add
        // Account sheet). Walk up sheetParent chain to get the root window —
        // sheets are child windows and move together with parent.
        var w = NSApp.keyWindow
        while let parent = w?.sheetParent { w = parent }
        self.initiatingWindow = w

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.expectedState = expectedState
            LogService.shared.log(
                .debug,
                .auth,
                "Broker waiting for OAuth callback",
                detail: "state=\(String(expectedState.prefix(12)))… window=\(w?.title ?? "<nil>")"
            )
        }
    }

    // MARK: - Delivery side (AppDelegate)

    /// Вызывается из `AppDelegate.application(_:open:)`. Если никто не ждёт
    /// — логируем и игнорим (может быть лаг: пользователь нажал Back в sheet,
    /// но браузер уже успел редиректить — такие случаи не должны крашить
    /// приложение).
    func deliver(_ url: URL) {
        // §23: never log the raw callback URL — it carries the OAuth `code` and
        // `state` in the query. Log scheme+path only.
        LogService.shared.log(
            .info,
            .auth,
            "OAuth callback received",
            detail: Self.redactedURL(url)
        )

        guard let continuation else {
            LogService.shared.log(
                .warning,
                .auth,
                "OAuth callback but no waiter — ignoring",
                detail: Self.redactedURL(url)
            )
            return
        }

        let windowToRestore = self.initiatingWindow

        self.continuation = nil
        self.expectedState = nil
        self.initiatingWindow = nil
        continuation.resume(returning: url)

    }

    /// Cancel the current wait (user closed the Add Account sheet manually).
    /// Resumes the waiting continuation with `userCancelled`.
    func cancel() {
        guard let continuation else { return }
        self.continuation = nil
        self.expectedState = nil
        continuation.resume(throwing: AuthError.userCancelled)
    }
}
