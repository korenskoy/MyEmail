//
//  SyncService+Resync.swift
//  MyEmail
//
//  Force-resync a single message: re-fetch headers + body from IMAP,
//  overwrite all GRDB fields, notify MessageDetailView to reload.
//

import Foundation
import GRDB
import SwiftEmailParser

extension Notification.Name {
    static let messageDidResync = Notification.Name("me.messageDidResync")
}

extension SyncService {

    /// Re-fetch headers + body for a single message from IMAP and persist
    /// everything to GRDB. Posts `.messageDidResync` when done so any open
    /// detail view reloads.
    func resyncMessage(id: UUID) async {
        guard let (msg, folder, account) = try? await fetchMessageContext(messageID: id) else {
            LogService.log(.warning, .sync, "Resync: message not found", detail: "\(id)")
            return
        }
        LogService.log(.info, .sync,
                       "Resync requested UID \(msg.uid)", detail: folder.path)
        do {
            try await runCommandSerializedPerAccount(account.id) { [weak self] in
                guard let self else { return }
                try await self._resyncLocked(msg: msg, folder: folder, account: account, id: id)
            }
        } catch {
            LogService.log(.error, .sync,
                           "Resync failed UID \(msg.uid)", detail: "\(error)")
        }
    }

    private func _resyncLocked(
        msg: Message, folder: Folder, account: Account, id: UUID
    ) async throws {
        let imap = getOrCreateCommandIMAPService(for: account)
        await wireTokenProvider(for: account, imap: imap)

        // Connect + SELECT with poison recovery (same pattern as SyncService+Body).
        do {
            if await !imap.isConnected { try await imap.connect() }
            try await imap.ensureFolderSelected(folder.path)
        } catch {
            let desc = "\(error)"
            guard SyncService.isTransportError(desc) else { throw error }
            LogService.log(.warning, .sync, "Resync: poisoned socket on SELECT, reconnecting", detail: desc)
            await imap.disconnect()
            try await imap.connect()
            try await imap.ensureFolderSelected(folder.path)
        }

        // Full RFC822 fetch — gets headers + body in one round trip.
        var rawData: Data
        do {
            rawData = try await imap.fetchRawMessage(uid: msg.uid)
        } catch {
            let desc = "\(error)"
            guard SyncService.isTransportError(desc) else { throw error }
            await resetPoisonedConnection(imap: imap, folderPath: folder.path)
            rawData = try await imap.fetchRawMessage(uid: msg.uid)
        }

        let email = try EmailMessage(data: rawData)

        // Respect locally-edited subject (rewriteSubject rule). If the row
        // has an entry in `message_subject_overrides`, keep `msg.subject`
        // (already the edited value) instead of clobbering it with the
        // server copy.
        let subjectOverridden: Bool = (try? await pool.read { db in
            (try Bool.fetchOne(db, sql:
                "SELECT 1 FROM message_subject_overrides WHERE message_id = ?",
                arguments: [id])) ?? false
        }) ?? false

        // Build the updated Message, preserving ID/folder/account fields.
        var updated = msg
        let fromParsed = email.from.first
        updated.fromAddress = fromParsed?.address ?? msg.fromAddress
        updated.fromName    = fromParsed?.name.flatMap { $0.isEmpty ? nil : $0 }
        updated.subject     = subjectOverridden
            ? msg.subject
            : SyncService.sanitizeSubject(email.subject ?? msg.subject)
        updated.toAddresses = email.to.map(\.formatted)
        updated.ccAddresses = email.cc.map(\.formatted)
        updated.bccAddresses = email.bcc.map(\.formatted)
        updated.toSearch    = updated.toAddresses.joined(separator: " ")
        updated.ccSearch    = updated.ccAddresses.joined(separator: " ")
        updated.bccSearch   = updated.bccAddresses.joined(separator: " ")
        updated.bodyText    = email.textBody
        updated.bodyHTML    = email.htmlBody
        updated.downloadState = .full
        updated.isEncrypted = email.isEncrypted
            || (email.textBody ?? "").contains("-----BEGIN PGP MESSAGE-----")
        updated.size        = rawData.count
        if let text = email.textBody, !text.isEmpty {
            updated.preview = String(text.prefix(160))
        }

        // Attachments
        let allAttachments = email.attachments
        if !allAttachments.isEmpty {
            try await saveAttachments(allAttachments, messageID: msg.id, accountID: account.id)
        }
        updated.hasAttachments = allAttachments.contains { !$0.isInline }

        try await pool.write { db in
            try updated.update(db)
        }

        LogService.log(.info, .sync,
                       "Resync complete UID \(msg.uid)", detail: "size=\(rawData.count)")
        NotificationCenter.default.post(name: .messageDidResync, object: id.uuidString)
    }
}
