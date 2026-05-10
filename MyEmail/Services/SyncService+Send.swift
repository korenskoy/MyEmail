//
//  SyncService+Send.swift
//  MyEmail
//
//  Send message via SMTP + append to Sent folder via IMAP.
//  Save/update drafts via IMAP APPEND.
//

import Foundation
import GRDB
import SwiftMail

extension SyncService {

    /// RFC 5322-compliant User-Agent, matches Thunderbird convention.
    nonisolated static let userAgentString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        #if arch(arm64)
        let arch = "Silicon"
        #else
        let arch = "Intel"
        #endif
        return "MyEmail/\(version) (macOS/\(arch))"
    }()

    // MARK: - SMTP services

    private var smtpServices: [UUID: SMTPService] {
        get { smtpServiceStore }
        set { smtpServiceStore = newValue }
    }

    func getOrCreateSMTPService(for account: Account) -> SMTPService {
        if let existing = smtpServiceStore[account.id] { return existing }
        let service = SMTPService(account: account, keychain: keychain)
        smtpServiceStore[account.id] = service
        return service
    }

    // MARK: - Send message

    func sendMessage(
        from account: Account,
        to: [String], cc: [String] = [], bcc: [String] = [],
        replyTo: [String] = [],
        subject: String,
        textBody: String,
        htmlBody: String? = nil,
        attachments: [SwiftMail.Attachment]? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        originalMessageUID: UInt32? = nil,
        originalFolderPath: String? = nil,
        isForward: Bool = false
    ) async throws {
        let smtp = getOrCreateSMTPService(for: account)
        await wireSmtpTokenProvider(for: account, smtp: smtp)

        // Standard headers matching RFC 2822 / Thunderbird conventions
        var headers: [String: String] = [:]
        headers["User-Agent"] = Self.userAgentString
        headers["Content-Language"] = Locale.preferredLanguages.first ?? "en"

        // RFC 5322 §3.6.4: generate stable Message-ID using account domain
        let domain = account.email.components(separatedBy: "@").last ?? "myemail.local"
        let messageIDValue = "<\(UUID().uuidString)@\(domain)>"
        headers["Message-ID"] = messageIDValue

        // Threading headers for replies (RFC 2822 §3.6.4)
        if let replyID = inReplyTo, !replyID.isEmpty {
            headers["In-Reply-To"] = replyID
        }
        if !references.isEmpty {
            headers["References"] = references.joined(separator: " ")
        }
        if !replyTo.isEmpty {
            headers["Reply-To"] = replyTo.joined(separator: ", ")
        }

        var email = Email(
            sender: EmailAddress(name: account.senderName ?? account.name, address: account.email),
            recipients: to.map { EmailAddress(address: $0) },
            ccRecipients: cc.map { EmailAddress(address: $0) },
            bccRecipients: bcc.map { EmailAddress(address: $0) },
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            attachments: attachments
        )
        email.additionalHeaders = headers

        try await smtp.send(email)

        // Mark original message as \Answered or $Forwarded (RFC 3501)
        if let origUID = originalMessageUID, let origFolder = originalFolderPath {
            let imap = getOrCreateIMAPService(for: account)
            await wireTokenProvider(for: account, imap: imap)
            do {
                if await !imap.isConnected { try await imap.connect() }
                try await imap.selectFolder(origFolder)
                if isForward {
                    try await imap.addFlags([.custom("$Forwarded")], uids: [origUID])
                } else {
                    try await imap.addFlags([.answered], uids: [origUID])
                }
            } catch {
                LogService.log(.warning, .imap, "Failed to set reply/forward flag", detail: "\(error)")
            }
        }

        // Append to Sent folder via IMAP (§6.5)
        if let sentPath = account.sentFolderPath {
            // Gmail auto-saves to Sent — APPEND would create a duplicate
            let isGmail = await isGmailAccount(account)
            if isGmail {
                LogService.log(.info, .smtp, "Gmail: skipping APPEND (auto-saved)", detail: sentPath)
            } else {
                let imap = getOrCreateIMAPService(for: account)
                await wireTokenProvider(for: account, imap: imap)

                do {
                    if await !imap.isConnected { try await imap.connect() }
                    try await imap.appendMessage(email, to: sentPath)
                    LogService.log(.info, .smtp, "Appended to Sent", detail: sentPath)
                } catch {
                    // SMTP succeeded — don't lose the send. Enqueue APPEND for retry (§6.5).
                    LogService.log(.warning, .smtp, "APPEND to Sent failed, enqueueing", detail: "\(error)")
                    if let queue = offlineQueue {
                        let action = PendingAction(
                            id: UUID(), type: .appendToSent,
                            accountID: account.id,
                            sourceFolderPath: nil,
                            targetFolderPath: sentPath,
                            messageUID: nil, payload: nil,
                            status: .pending, attemptCount: 0,
                            lastError: "\(error)", createdAt: Date()
                        )
                        try? await queue.enqueue(action)
                    }
                }
            }
        } else {
            LogService.log(.info, .smtp, "No Sent folder configured", detail: account.email)
        }

        // Update recipient history
        let allRecipients = to + cc
        try await updateRecipientHistory(allRecipients)
    }

    // MARK: - Gmail detection (#15)

    /// Detects Gmail accounts by hostname or [Gmail] folder presence.
    /// Custom domain accounts using Google Workspace have non-gmail hostnames
    /// but still expose [Gmail]/ folders.
    private func isGmailAccount(_ account: Account) async -> Bool {
        let host = account.imapHost.lowercased()
        if host.contains("gmail") || host.contains("googlemail") { return true }
        let hasGmailFolder = (try? await pool.read { db in
            try Folder.filter(Column("account_id") == account.id)
                .filter(Column("path").like("[Gmail]%"))
                .fetchCount(db) > 0
        }) ?? false
        return hasGmailFolder
    }

    // MARK: - Wire SMTP token provider

    private func wireSmtpTokenProvider(for account: Account, smtp: SMTPService) async {
        guard account.authType == .oauth2, let auth = authService else { return }
        let accountID = account.id
        await smtp.setAccessTokenProvider {
            try await auth.currentAccessToken(for: accountID)
        }
    }

    // MARK: - Recipient history

    private func updateRecipientHistory(_ addresses: [String]) async throws {
        try await pool.write { db in
            for addr in addresses where !addr.isEmpty {
                let existing = try RecipientHistory
                    .filter(Column("email") == addr)
                    .fetchOne(db)
                if var entry = existing {
                    entry.useCount += 1
                    entry.lastUsed = Date()
                    try entry.update(db)
                } else {
                    var entry = RecipientHistory(
                        id: UUID(), email: addr, name: nil,
                        useCount: 1, lastUsed: Date()
                    )
                    try entry.insert(db)
                }
            }
        }
    }
}
