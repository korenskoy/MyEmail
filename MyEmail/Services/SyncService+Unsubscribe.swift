//
//  SyncService+Unsubscribe.swift
//  MyEmail
//
//  RFC 2369 List-Unsubscribe / RFC 8058 one-click unsubscribe.
//

import Foundation
import GRDB
import SwiftMail

/// The single method we use for a message's List-Unsubscribe header.
/// Preference: RFC 8058 one-click POST → mailto → open page in browser.
nonisolated enum UnsubscribeMethod: Sendable, Equatable {
    case oneClick(URL)
    case mail(URL)
    case web(URL)

    /// RFC 6068 parts of a `.mail` request; subject/body default to "unsubscribe".
    nonisolated struct Mail: Sendable {
        let to: String
        let subject: String
        let body: String
    }

    nonisolated init?(header: String?, oneClick: Bool) {
        // Not allowed by RFC 2369, but some relays re-encode the whole value
        // as RFC 2047 encoded-words — decode first.
        guard let header = header?.decodeMIMEHeader() else { return nil }
        // RFC 2369 §2: angle-bracketed, comma-separated URIs; whitespace inside brackets is ignored.
        let uris = header.split(separator: "<").compactMap { part -> URL? in
            guard let end = part.firstIndex(of: ">") else { return nil }
            return URL(string: String(part[..<end].filter { !$0.isWhitespace }))
        }
        // The header comes from the message: never aim a request at the local network.
        func first(_ schemes: Set<String>) -> URL? {
            uris.first { schemes.contains($0.scheme?.lowercased() ?? "") && Self.isPublicHost($0) }
        }
        // RFC 8058 §3.1: one-click is HTTPS-only.
        if oneClick, let url = first(["https"]) {
            self = .oneClick(url)
        } else if let url = uris.first(where: { Self.mail(from: $0) != nil }) {
            self = .mail(url)
        } else if let url = first(["https", "http"]) {
            self = .web(url)
        } else {
            return nil
        }
    }

    /// Host for `.oneClick`/`.web`, recipient for `.mail` — shown in the confirmation dialog.
    nonisolated var target: String {
        switch self {
        case .oneClick(let url), .web(let url): url.host() ?? url.absoluteString
        case .mail(let url): Self.mail(from: url)?.to ?? url.absoluteString
        }
    }

    nonisolated var mail: Mail? {
        if case .mail(let url) = self { Self.mail(from: url) } else { nil }
    }

    /// Exactly one plain recipient: the message must not fan mail out from the account.
    nonisolated static func mail(from url: URL) -> Mail? {
        guard url.scheme?.lowercased() == "mailto",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let to = comps.path
        guard to.contains("@"), !to.contains(","), !to.contains(where: \.isWhitespace) else { return nil }
        func query(_ name: String) -> String? {
            comps.queryItems?.first { $0.name.lowercased() == name }?.value
        }
        return Mail(to: to, subject: query("subject") ?? "unsubscribe", body: query("body") ?? "unsubscribe")
    }

    /// Rejects localhost, `.local`, single-label names and IP literals (any TLD not
    /// starting with a letter — also catches `0x7f.1`-style forms inet_aton accepts).
    /// ponytail: name-based only; a public name resolving to a private IP still passes,
    /// closing that needs resolve-then-connect.
    nonisolated static func isPublicHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let labels = host.split(separator: ".")
        guard labels.count > 1, let tld = labels.last, tld.first?.isLetter == true else { return false }
        return !["localhost", "local"].contains(tld)
    }
}

/// Lets a one-click POST follow redirects only to public HTTPS hosts.
/// Completion-handler form: the async overload crashes SILGen's ObjC thunk (Xcode 27 toolchain).
nonisolated private final class UnsubscribeRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = request.url.map { $0.scheme?.lowercased() == "https" && UnsubscribeMethod.isPublicHost($0) }
        completionHandler(allowed == true ? request : nil)
    }
}

extension SyncService {

    /// Rows synced before `list_unsubscribe` existed hold NULL: fetch the two headers once
    /// and store "" when absent so the message is never asked about again.
    func backfillListUnsubscribe(messageID: UUID) async -> (header: String, oneClick: Bool)? {
        guard let (msg, folder, account) = try? await fetchMessageContext(messageID: messageID),
              msg.listUnsubscribe == nil, msg.uid > 0 else { return nil }
        do {
            let info = try await runCommandSerializedPerAccount(account.id) { [weak self] () -> MessageInfo? in
                guard let self else { return nil }
                let imap = self.getOrCreateCommandIMAPService(for: account)
                await self.wireTokenProvider(for: account, imap: imap)
                if await !imap.isConnected { try await imap.connect() }
                try await imap.ensureFolderSelected(folder.path)
                return try await imap.fetchUnsubscribeHeaders(uid: msg.uid)
            }
            guard let info else { return nil }
            let header = info.additionalFields?["list-unsubscribe"] ?? ""
            let oneClick = info.additionalFields?["list-unsubscribe-post"] != nil
            try await pool.write { db in
                try db.execute(sql: """
                    UPDATE messages SET list_unsubscribe = ?, list_unsubscribe_one_click = ?
                    WHERE id = ?
                    """, arguments: [header, oneClick, messageID])
            }
            return (header, oneClick)
        } catch {
            LogService.log(.warning, .sync, "List-Unsubscribe backfill failed", detail: "\(error)")
            return nil
        }
    }

    /// Performs a one-click POST or sends the mailto request. `.web` is opened by the caller.
    func unsubscribe(_ method: UnsubscribeMethod, accountID: UUID) async throws {
        switch method {
        case .oneClick(let url):
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
            // RFC 8058 §3.2: no cookies or other credentials.
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let (_, response) = try await session.data(for: request, delegate: UnsubscribeRedirectGuard())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                LogService.log(.error, .sync, "One-click unsubscribe failed",
                               detail: "\(url.host() ?? "") HTTP \(status)")
                throw URLError(.badServerResponse)
            }
            LogService.log(.info, .sync, "One-click unsubscribe sent", detail: url.host() ?? "")

        case .mail:
            guard let mail = method.mail else { throw SyncServiceError.invalidRecipient }
            guard let account = try await pool.read({ try Account.fetchOne($0, key: accountID) }) else {
                throw SyncServiceError.accountNotFound
            }
            try await sendMessage(from: account, to: [mail.to], subject: mail.subject, textBody: mail.body)
            LogService.log(.info, .smtp, "Unsubscribe mail sent", detail: mail.to)

        case .web:
            break
        }
    }
}
