//
//  SMTPService.swift
//  MyEmail
//
//  Actor wrapping SwiftMail.SMTPServer. One-shot: every send opens a fresh
//  connection (connect → auth → sendEmail → QUIT + close). SMTP servers drop
//  idle sockets per RFC 5321 §4.5.3.2 (typical 5–10 min); a cached SMTPServer
//  surfaces the dead channel as NIOCore.ChannelError.outputClosed on the next
//  write. One-shot also matches the IMAPRawClient guideline (CLAUDE.md #19)
//  and prevents MultiThreadedEventLoopGroup leaks across sends.
//

import Foundation
import SwiftMail

actor SMTPService {
    private let account: Account
    private let keychain: KeychainService
    private var accessTokenProvider: (@Sendable () async throws -> String)?

    init(account: Account, keychain: KeychainService) {
        self.account = account
        self.keychain = keychain
    }

    func setAccessTokenProvider(_ provider: @escaping @Sendable () async throws -> String) {
        self.accessTokenProvider = provider
    }

    // MARK: - Send (one-shot)

    func send(_ email: Email) async throws {
        let srv = SMTPServer(host: account.smtpHost, port: account.smtpPort)
        try await srv.connect()

        switch account.authType {
        case .oauth2:
            let token: String
            if let provider = accessTokenProvider {
                token = try await provider()
            } else {
                token = try keychain.oauthAccessToken(for: account.id)
            }
            try await srv.authenticateXOAUTH2(email: account.email, accessToken: token)

        case .plain:
            try await srv.login(
                username: account.email,
                password: try keychain.password(for: account.id)
            )
        }

        // QUIT + close on the way out, regardless of send outcome.
        // Holds the EventLoopGroup until disconnect completes so it deinits cleanly.
        do {
            try await srv.sendEmail(email)
            try? await srv.disconnect()
            LogService.log(.info, .smtp, "Sent to \(email.recipients.map(\.address).joined(separator: ", "))")
        } catch {
            try? await srv.disconnect()
            throw error
        }
    }
}
