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

    nonisolated init?(header: String?, oneClick: Bool) {
        // Not allowed by RFC 2369, but some relays (e.g. Kaspersky KLMS) re-encode
        // the whole value as RFC 2047 encoded-words — decode first.
        guard let header = header?.decodeMIMEHeader() else { return nil }
        // RFC 2369 §2: angle-bracketed, comma-separated URIs; whitespace inside brackets is ignored.
        let uris = header.split(separator: "<").compactMap { part -> URL? in
            guard let end = part.firstIndex(of: ">") else { return nil }
            return URL(string: String(part[..<end].filter { !$0.isWhitespace }))
        }
        func first(_ schemes: Set<String>) -> URL? {
            uris.first { schemes.contains($0.scheme?.lowercased() ?? "") }
        }
        // RFC 8058 §3.1: one-click is HTTPS-only.
        if oneClick, let url = first(["https"]) {
            self = .oneClick(url)
        } else if let url = first(["mailto"]) {
            self = .mail(url)
        } else if let url = first(["https", "http"]) {
            self = .web(url)
        } else {
            return nil
        }
    }

    /// Where the request goes — shown in the confirmation dialog.
    nonisolated var target: String {
        switch self {
        case .oneClick(let url), .web(let url): url.host() ?? url.absoluteString
        case .mail(let url): URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.absoluteString
        }
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
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                LogService.log(.error, .sync, "One-click unsubscribe failed",
                               detail: "\(url.host() ?? "") HTTP \(status)")
                throw URLError(.badServerResponse)
            }
            LogService.log(.info, .sync, "One-click unsubscribe sent", detail: url.host() ?? "")

        case .mail(let url):
            // RFC 6068: mailto:addr1,addr2?subject=…&body=…
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let to = (comps?.path ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            guard !to.isEmpty else { throw SyncServiceError.invalidRecipient }
            func query(_ name: String) -> String? {
                comps?.queryItems?.first { $0.name.lowercased() == name }?.value
            }
            guard let account = try await pool.read({ try Account.fetchOne($0, key: accountID) }) else {
                throw SyncServiceError.accountNotFound
            }
            try await sendMessage(
                from: account, to: to,
                subject: query("subject") ?? "unsubscribe",
                textBody: query("body") ?? "unsubscribe"
            )
            LogService.log(.info, .smtp, "Unsubscribe mail sent", detail: to.joined(separator: ", "))

        case .web:
            break
        }
    }
}
