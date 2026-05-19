//
//  AppDelegate.swift
//  MyEmail
//
//  NSApplicationDelegate. Owns AppState, AppEnvironment, all window
//  controllers, and the main menu. Chrome is AppKit-owned; SwiftUI runs
//  only as content inside each window's NSHostingView.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let environment = AppEnvironment()
    let appState = AppState()

    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var messageControllers: [UUID: MessageWindowController] = [:]
    private var composeControllers: [UUID: ComposeWindowController] = [:]

    private var menuBuilder: MainMenuBuilder?

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Build menubar before didFinishLaunching so standard items render
        // correctly on first window activation.
        let builder = MainMenuBuilder(delegate: self)
        builder.install()
        menuBuilder = builder
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LogService.shared.log(.info, .uiDebug, "NSApplication didFinishLaunching")

        let theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "")
            ?? .system
        theme.apply()

        showMainWindow()
        trackDockBadge()
    }

    // MARK: - Dock badge (Unified Inbox unread count)

    private func trackDockBadge() {
        withObservationTracking {
            let total = appState.folders
                .filter { $0.specialUse == .inbox }
                .reduce(0) { $0 + $1.unreadCount }
            NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackDockBadge() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        LogService.shared.log(.info, .uiDebug, "NSApplication willTerminate")
    }

    // MARK: - URL / file open

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            LogService.shared.log(
                .debug, .auth,
                "application(_:open:) got URL",
                detail: url.absoluteString
            )
            if isOAuthCallback(url) {
                OAuthCallbackBroker.shared.deliver(url)
            } else if url.scheme?.lowercased() == "mailto" {
                if let prefill = MailtoParser.parse(url) {
                    openCompose(mode: .mailto(id: UUID(), prefill: prefill))
                }
            } else if url.isFileURL,
                      url.pathExtension.lowercased() == "eml" {
                EmlViewerService.shared.open(url: url)
            }
        }
    }

    private func isOAuthCallback(_ url: URL) -> Bool {
        guard let scheme = url.scheme else { return false }
        return scheme == Secrets.googleRedirectScheme
    }

    // MARK: - Window orchestration

    func showMainWindow() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController(
                appState: appState, environment: environment
            )
        }
        mainWindowController?.showMain()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                appState: appState, environment: environment
            )
        }
        settingsWindowController?.show()
    }

    func openCompose(mode: ComposeMode) {
        let controller = ComposeWindowController(
            mode: mode,
            appState: appState,
            environment: environment,
            onClose: { [weak self] instanceID in
                self?.composeControllers[instanceID] = nil
            }
        )
        composeControllers[controller.instanceID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        // Reply/Forward/ReplyAll are strong notability signals (delta=5).
        // New message has no source ID, skipped.
        if let sourceID = mode.messageID {
            Task { [environment] in
                await environment.syncService.incrementInteractionScore([sourceID], delta: 5)
            }
        }
    }

    func openMessage(id: UUID) {
        if let existing = messageControllers[id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = MessageWindowController(
            messageID: id,
            appState: appState,
            environment: environment,
            onClose: { [weak self] msgID in
                self?.messageControllers[msgID] = nil
            }
        )
        messageControllers[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu actions routed to AppDelegate

    @objc func toggleDebugLog(_ sender: Any?) {
        let key = "debugLogPanelVisible"
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: key), forKey: key)
    }

    @objc func setLayoutWide(_ sender: Any?) {
        UserDefaults.standard.set("wide", forKey: "windowLayout")
    }

    @objc func setLayoutClassic(_ sender: Any?) {
        UserDefaults.standard.set("classic", forKey: "windowLayout")
    }
}
