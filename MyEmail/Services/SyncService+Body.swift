//
//  SyncService+Body.swift
//  MyEmail
//
//  Body fetch + persist. Inline CID attachments → filesystem.
//

import Foundation
import GRDB
import SwiftEmailParser

extension SyncService {

    /// Fetch message + folder + account in one DB read.
    func fetchMessageContext(messageID: UUID) async throws -> (Message, Folder, Account)? {
        try await pool.read { db in
            guard let msg = try Message.fetchOne(db, key: messageID),
                  let folder = try Folder.fetchOne(db, key: msg.folderID),
                  let account = try Account.fetchOne(db, key: msg.accountID)
            else { return nil }
            return (msg, folder, account)
        }
    }

    /// Load full message body on demand (called from MessageDetailView).
    /// Runs on the per-account command socket so it never races with
    /// sync/IDLE/backfill on the primary connection.
    func loadFullMessage(id: UUID) async throws -> Message? {
        // A user click is in flight for the whole open — tell prefetch to yield
        // the command socket instead of making us wait behind a full batch.
        foregroundOpenPending += 1
        defer { foregroundOpenPending -= 1 }
        guard let (msg, folder, account) = try await fetchMessageContext(messageID: id) else { return nil }
        // Viewing a message is a notability signal (delta=1). Fire-and-forget so
        // this telemetry write never blocks the open on the DB write queue.
        Task { [weak self] in await self?.incrementInteractionScore([id], delta: 1) }
        if msg.downloadState == .full { return msg }

        // Defensive: valid IMAP UIDs start at 1 (RFC 3501). uid=0 would overflow
        // SwiftMail's MessageIdentifierSet. The v10 migration drops any such
        // zombies, but guard here in case a stale row slips through.
        guard msg.uid > 0 else {
            LogService.log(.warning, .sync,
                           "Skipping body fetch for placeholder uid=0", detail: "id=\(id)")
            return msg
        }

        return try await runCommandSerializedPerAccount(account.id) { [weak self] in
            guard let self else { return nil }
            return try await self._loadFullMessageLocked(msg: msg, folder: folder, account: account, id: id)
        }
    }

    private func _loadFullMessageLocked(
        msg: Message, folder: Folder, account: Account, id: UUID
    ) async throws -> Message? {
        var msg = msg
        let imap = getOrCreateCommandIMAPService(for: account)
        await wireTokenProvider(for: account, imap: imap)

        do {
            if await !imap.isConnected { try await imap.connect() }
            try await imap.ensureFolderSelected(folder.path)
        } catch {
            let desc = "\(error)"
            // Poisoned connection (leftover bytes from a previous large fetch):
            // TCP is alive but server treats our SELECT as continuation. Reconnect once.
            guard SyncService.isTransportError(desc) else {
                LogService.log(.error, .sync, "Connect failed for body fetch", detail: desc)
                if SyncService.isAuthError(error), account.authType == .oauth2 {
                    markNeedsReauth(accountID: account.id, reason: "body fetch auth failure")
                }
                return msg
            }
            LogService.log(.warning, .sync,
                           "Poisoned command socket on SELECT, reconnecting", detail: desc)
            await imap.disconnect()
            do {
                try await imap.connect()
                try await imap.ensureFolderSelected(folder.path)
            } catch {
                LogService.log(.error, .sync,
                               "Reconnect failed for body fetch", detail: "\(error)")
                return msg
            }
        }

        // Thunderbird parity: always fetch whole RFC822 via BODY.PEEK[], parse
        // MIME locally. BODYSTRUCTURE-based selective fetch removed — Thunderbird
        // itself dropped it (Bug 1805186) due to server inconsistencies.
        let rawData: Data
        do {
            rawData = try await imap.fetchRawMessage(uid: msg.uid)
        } catch {
            let desc = "\(error)"
            // Poison errors (bad(invalid command), Broken pipe, etc.) mean the
            // server is still draining a previous response — reconnect and retry once.
            guard SyncService.isTransportError(desc) else {
                LogService.log(.error, .sync,
                               "Raw fetch failed for UID \(msg.uid)", detail: desc)
                return msg
            }
            LogService.log(.warning, .sync,
                           "Raw fetch: poisoned connection, reconnecting for UID \(msg.uid)",
                           detail: desc)
            await resetPoisonedConnection(imap: imap, folderPath: folder.path)
            do {
                rawData = try await imap.fetchRawMessage(uid: msg.uid)
            } catch {
                LogService.log(.error, .sync,
                               "Raw fetch failed after reconnect for UID \(msg.uid)",
                               detail: "\(error)")
                return msg
            }
        }

        return try await persistFullMessageBody(rawData: rawData, msg: msg, account: account)
    }

    /// Parse + persist a fetched RFC822 body. Shared by the single-message
    /// detail-view path (`_loadFullMessageLocked`) and the batched prefetch
    /// path (`runPrefetchLoop` via pipelined `fetchRawMessages`).
    func persistFullMessageBody(
        rawData: Data, msg: Message, account: Account
    ) async throws -> Message {
        var msg = msg
        let email: EmailMessage
        do {
            email = try EmailMessage(data: rawData)
        } catch {
            LogService.log(.error, .sync,
                           "MIME parse failed for UID \(msg.uid)", detail: "\(error)")
            return msg
        }

        let textBody = email.textBody
        let htmlBody = email.htmlBody

        // Mail client identity — first non-empty of the canonical headers.
        let userAgent = Self.firstHeader(email,
            "User-Agent", "X-Mailer", "X-Mail-Agent", "X-Newsreader")

        // Detect PGP/GPG encryption (PGP/MIME or inline PGP)
        let pgpEncrypted = email.isEncrypted
            || (textBody ?? "").contains("-----BEGIN PGP MESSAGE-----")

        let id = msg.id

        if pgpEncrypted {
            try await pool.write { db in
                try db.execute(sql: """
                    UPDATE messages SET download_state = 'full', is_encrypted = 1, size = ?,
                                        user_agent = ?
                    WHERE id = ?
                    """, arguments: [rawData.count, userAgent, id])
            }
            msg.downloadState = .full
            msg.isEncrypted = true
            msg.size = rawData.count
            msg.userAgent = userAgent
            LogService.log(.info, .sync, "PGP encrypted message, UID \(msg.uid)")
            return msg
        }

        // Save all attachments (inline + regular)
        let allAttachments = email.attachments
        if !allAttachments.isEmpty {
            try await saveAttachments(allAttachments, messageID: msg.id, accountID: account.id)
        }
        // Correct has_attachments to the post-parse truth (enumeration used
        // a Content-Type heuristic that may have false-positived).
        let hasNonInline = allAttachments.contains { !$0.isInline }

        // Raw data byte count ≈ RFC822.SIZE — populate if still zero
        let rawSize = rawData.count

        try await pool.write { db in
            try db.execute(sql: """
                UPDATE messages SET body_text = ?, body_html = ?, download_state = 'full',
                                    size = ?, has_attachments = ?, user_agent = ?
                WHERE id = ?
                """, arguments: [textBody, htmlBody, rawSize, hasNonInline, userAgent, id])
        }

        msg.bodyText = textBody
        msg.bodyHTML = htmlBody
        msg.downloadState = .full
        msg.size = rawSize
        msg.userAgent = userAgent
        LogService.log(.info, .sync, "Loaded body for UID \(msg.uid)", detail: "size=\(rawSize)")
        return msg
    }

    /// Return the first non-empty value among the given header names.
    /// Order matches the upstream dispmua detection order:
    /// User-Agent → X-Mailer → X-Mail-Agent → X-Newsreader.
    private static func firstHeader(_ email: EmailMessage, _ names: String...) -> String? {
        for name in names {
            if let value = email.header(name)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Load inline attachment refs for CID rewriting in MessageDetailView.
    func inlineRefs(for messageID: UUID) async throws -> [InlineRef] {
        try await pool.read { db in
            try Attachment
                .filter(Column("message_id") == messageID)
                .filter(Column("is_inline") == true)
                .fetchAll(db)
                .compactMap { att -> InlineRef? in
                    guard let path = att.localPath else { return nil }
                    return InlineRef(contentID: att.contentID, localPath: path)
                }
        }
    }

    /// Load all attachments and split into inline refs + regular attachments in one DB read.
    func loadAttachments(for messageID: UUID) async throws -> (inlineRefs: [InlineRef], regular: [Attachment]) {
        let all = try await pool.read { db in
            try Attachment
                .filter(Column("message_id") == messageID)
                .order(Column("filename").asc)
                .fetchAll(db)
        }
        let refs = all.compactMap { att -> InlineRef? in
            guard att.isInline, let path = att.localPath else { return nil }
            return InlineRef(contentID: att.contentID, localPath: path)
        }
        let regular = all.filter { !$0.isInline }
        return (refs, regular)
    }

    /// Re-fetch a single attachment from IMAP when local file was deleted.
    /// Runs on the command socket to avoid racing with sync.
    func refetchAttachment(_ attachment: Attachment) async throws -> Attachment? {
        guard let (msg, folder, account) = try await fetchMessageContext(messageID: attachment.messageID) else { return nil }

        return try await runCommandSerializedPerAccount(account.id) { [weak self] in
            guard let self else { return nil }
            let imap = self.getOrCreateCommandIMAPService(for: account)
            await self.wireTokenProvider(for: account, imap: imap)
            if await !imap.isConnected { try await imap.connect() }
            try await imap.ensureFolderSelected(folder.path)

            let rawData = try await imap.fetchRawMessage(uid: msg.uid)
            let email = try EmailMessage(data: rawData)

            // Match by contentId or filename
            guard let part = email.attachments.first(where: { att in
                if let cid = attachment.contentID, let partCid = att.contentId, cid == partCid {
                    return true
                }
                return att.filename == attachment.filename
            }) else {
                LogService.log(.warning, .sync, "Attachment part not found on re-fetch",
                               detail: attachment.filename)
                return nil
            }

            let base = self.attachmentsDirectory(accountID: account.id, messageID: msg.id)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let filename = Self.sanitizeFilename(attachment.filename)
            let fileURL = base.appendingPathComponent(filename)
            try part.data.write(to: fileURL)
            Self.setQuarantine(on: fileURL)

            var updated = attachment
            updated.localPath = fileURL.path
            try await self.pool.write { db in
                try updated.update(db)
            }
            LogService.log(.info, .sync, "Re-fetched attachment", detail: attachment.filename)
            return updated
        }
    }

    // MARK: - Save attachments (SwiftEmailParser)

    func saveAttachments(
        _ attachments: [SwiftEmailParser.Attachment], messageID: UUID, accountID: UUID
    ) async throws {
        let base = attachmentsDirectory(accountID: accountID, messageID: messageID)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        var records: [MyEmail.Attachment] = []
        var usedFilenames: Set<String> = []
        for att in attachments {
            let rawFilename = att.filename ?? (att.contentId ?? "attachment-\(UUID().uuidString.prefix(8))")
            var filename = Self.sanitizeFilename(rawFilename)
            // Avoid collisions within same message
            if usedFilenames.contains(filename) {
                filename = "\(UUID().uuidString.prefix(8))-\(filename)"
            }
            usedFilenames.insert(filename)

            let fileURL = base.appendingPathComponent(filename)
            try att.data.write(to: fileURL)
            Self.setQuarantine(on: fileURL)

            LogService.log(.debug, .sync, "Saved attachment",
                           detail: "file=\(filename) inline=\(att.isInline) cid=\(att.contentId ?? "nil") size=\(att.data.count) path=\(fileURL.path)")

            records.append(MyEmail.Attachment(
                id: UUID(), partID: att.contentId ?? "",
                filename: filename, mimeType: att.mimeType,
                size: att.size, contentID: att.contentId,
                isInline: att.isInline, localPath: fileURL.path,
                messageID: messageID
            ))
        }

        let hasNonInline = records.contains { !$0.isInline }
        try await pool.write { db in
            // Clear existing to avoid duplicates on re-fetch
            try Attachment
                .filter(Column("message_id") == messageID)
                .deleteAll(db)
            for var record in records {
                try record.insert(db)
            }
            // Keep has_attachments flag in sync
            if hasNonInline {
                try db.execute(sql: """
                    UPDATE messages SET has_attachments = 1 WHERE id = ?
                    """, arguments: [messageID])
            }
        }
    }

    /// Strip path separators, .., control chars; limit length.
    nonisolated private static func sanitizeFilename(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        name = String(name.unicodeScalars.filter { $0.value >= 0x20 })
        if name.count > 255 { name = String(name.prefix(255)) }
        if name.isEmpty { name = UUID().uuidString }
        return name
    }

    func attachmentsDirectory(accountID: UUID, messageID: UUID) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("MyEmail", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
            .appendingPathComponent(messageID.uuidString, isDirectory: true)
    }

    /// §21: tag a freshly-written attachment with `com.apple.quarantine` so
    /// Gatekeeper / LaunchServices treat it like a downloaded file — the user
    /// gets the standard "downloaded from the Internet" warning before opening
    /// an executable or document macro. Best-effort: failures are logged, not
    /// fatal (a missing xattr only loses the warning, never blocks the save).
    nonisolated static func setQuarantine(on url: URL) {
        // Format: flags;hexTimestamp;agentName;UUID  (LSQuarantine).
        let flags = "0083"
        let ts = String(format: "%x", UInt32(Date().timeIntervalSince1970))
        let value = "\(flags);\(ts);MyEmail;\(UUID().uuidString)"
        let name = "com.apple.quarantine"
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            value.withCString { cStr in
                if setxattr(path, name, cStr, strlen(cStr), 0, 0) != 0 {
                    LogService.log(.debug, .sync, "Quarantine xattr failed",
                                   detail: "\(url.lastPathComponent) errno=\(errno)")
                }
            }
        }
    }
}
