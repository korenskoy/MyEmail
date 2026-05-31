//
//  AuthService.swift
//  MyEmail
//
//  OAuth2 actor: add accounts, token exchange, helpers.
//  Refresh/sweep/re-auth in AuthService+Refresh.swift.
//

import AppKit
import Foundation

// MARK: - Errors

enum AuthError: Error, Sendable {
    case secretsMissing
    case userCancelled
    case noCallbackURL
    case invalidCallback(String)
    case stateMismatch
    case tokenExchangeFailed(String)
    case userInfoFetchFailed(String)
    case accountAlreadyExists(email: String)
}

// MARK: - Constants

enum AuthConstants {
    /// Refresh token if it expires within this many seconds (§9.9).
    static let tokenRefreshThreshold: TimeInterval = 300 // 5 min
    /// Minimum interval between two refresh attempts for a single account.
    /// Prevents refresh-token rotation flood that would make Google
    /// invalidate the grant (hard rule 15).
    static let minRefreshInterval: TimeInterval = 30
}

// MARK: - AuthService

actor AuthService {
    let accountRepository: AccountRepository
    let keychain: KeychainService
    let httpSession: URLSession

    /// Per-account coalescing lock: concurrent callers await the same refresh Task.
    var refreshTasks: [UUID: Task<Void, Error>] = [:]

    /// Last successful refresh timestamp per account — enforces cooldown
    /// so concurrent callers cannot flood Google's refresh endpoint and
    /// cause refresh-token rotation to invalidate the grant.
    var lastRefreshAt: [UUID: Date] = [:]

    var sweepTask: Task<Void, Never>?

    init(
        accountRepository: AccountRepository = AccountRepository(),
        keychain: KeychainService = KeychainService.shared,
        httpSession: URLSession = .shared
    ) {
        self.accountRepository = accountRepository
        self.keychain = keychain
        self.httpSession = httpSession
    }

    // MARK: - Add Gmail account

    func addGmailAccount(loginHint: String? = nil) async throws -> Account {
        guard Secrets.googleClientID != "REPLACE_ME.apps.googleusercontent.com",
              !Secrets.googleClientID.isEmpty,
              Secrets.googleClientSecret != "REPLACE_ME",
              !Secrets.googleClientSecret.isEmpty,
              !Secrets.googleRedirectURI.isEmpty,
              !Secrets.googleRedirectScheme.isEmpty
        else {
            LogService.log(.error, .auth, "Secrets.swift not configured")
            throw AuthError.secretsMissing
        }

        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.generateState()
        let redirectURI = Secrets.googleRedirectURI

        let authRequest = GoogleOAuth.AuthorizationRequest(
            clientID: Secrets.googleClientID,
            redirectURI: redirectURI, state: state,
            codeChallenge: challenge, loginHint: loginHint
        )

        LogService.log(.info, .auth, "Starting Gmail OAuth flow")

        await MainActor.run { NSWorkspace.shared.open(authRequest.url) }

        let callbackURL = try await OAuthCallbackBroker.shared
            .waitForCallback(expectedState: state)

        LogService.log(.info, .auth, "Received OAuth callback")

        let (code, returnedState) = try parseCallback(callbackURL)
        guard returnedState == state else {
            LogService.log(.error, .auth, "State mismatch")
            throw AuthError.stateMismatch
        }

        let tokens = try await exchangeCode(code, verifier: verifier, redirectURI: redirectURI)
        guard let refreshToken = tokens.refreshToken else {
            throw AuthError.tokenExchangeFailed("No refresh_token returned")
        }

        let userInfo = try await fetchUserInfo(accessToken: tokens.accessToken)
        let accountID = UUID()
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))

        let account = Account(
            id: accountID, name: userInfo.email,
            senderName: userInfo.displayName,
            email: userInfo.email,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .ssl,
            smtpHost: "smtp.gmail.com", smtpPort: 587, smtpSecurity: .starttls,
            authType: .oauth2, authState: .ok, isEnabled: true,
            sortOrder: (try? accountRepository.nextSortOrder()) ?? 0,
            sentFolderPath: nil, draftsFolderPath: nil,
            trashFolderPath: nil, junkFolderPath: nil,
            archiveRootPath: nil, archiveSubdivision: .byMonthThunderbird,
            smtpMaxAttachmentSizeMB: 25
        )

        if let existing = try accountRepository.find(email: userInfo.email) {
            LogService.log(.warning, .auth, "Account already exists", detail: existing.id.uuidString)
            throw AuthError.accountAlreadyExists(email: userInfo.email)
        }

        try accountRepository.insert(account)
        try keychain.saveOAuthTokens(
            for: accountID, accessToken: tokens.accessToken,
            refreshToken: refreshToken, expiresAt: expiresAt
        )

        LogService.log(.info, .auth, "Added Gmail account \(userInfo.email)")
        return account
    }

    // MARK: - Add generic account

    func addGenericAccount(draft: GenericAccountDraft) async throws -> Account {
        let accountID = UUID()
        let account = Account(
            id: accountID, name: draft.accountName, senderName: draft.name,
            email: draft.email,
            imapHost: draft.imapHost, imapPort: draft.imapPort,
            imapSecurity: draft.imapSecurity,
            smtpHost: draft.smtpHost, smtpPort: draft.smtpPort,
            smtpSecurity: draft.smtpSecurity,
            authType: .plain, authState: .ok, isEnabled: true,
            sortOrder: (try? accountRepository.nextSortOrder()) ?? 0,
            sentFolderPath: nil, draftsFolderPath: nil,
            trashFolderPath: nil, junkFolderPath: nil,
            archiveRootPath: nil, archiveSubdivision: .byMonthThunderbird,
            smtpMaxAttachmentSizeMB: 25
        )

        if let existing = try accountRepository.find(email: draft.email) {
            throw AuthError.accountAlreadyExists(email: existing.email)
        }

        try accountRepository.insert(account)
        try keychain.savePassword(draft.password, for: accountID)
        LogService.log(.info, .auth, "Added plain account \(draft.email)")
        return account
    }

    // MARK: - Helpers

    func parseCallback(_ url: URL) throws -> (code: String, state: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            throw AuthError.invalidCallback("no query string")
        }

        if let oauthError = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value ?? ""
            if oauthError == "access_denied" { throw AuthError.userCancelled }
            throw AuthError.invalidCallback("\(oauthError): \(desc)")
        }

        guard let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value else {
            throw AuthError.invalidCallback("missing code or state")
        }
        return (code, state)
    }

    func exchangeCode(
        _ code: String, verifier: String, redirectURI: String
    ) async throws -> GoogleOAuth.TokenResponse {
        let request = GoogleOAuth.codeExchangeRequest(
            code: code, codeVerifier: verifier, redirectURI: redirectURI,
            clientID: Secrets.googleClientID, clientSecret: Secrets.googleClientSecret
        )
        let (data, response) = try await httpSession.data(for: request)
        try Self.validate(response: response, data: data, context: "token exchange")
        return try JSONDecoder().decode(GoogleOAuth.TokenResponse.self, from: data)
    }

    struct UserInfoResponse: Decodable, Sendable {
        let email: String
        let name: String?
        let givenName: String?
        let familyName: String?

        enum CodingKeys: String, CodingKey {
            case email, name
            case givenName = "given_name"
            case familyName = "family_name"
        }

        /// Best available display name, falling back through name → given+family → email.
        var displayName: String {
            if let name, !name.isEmpty { return name }
            let parts = [givenName, familyName].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") }
            return email
        }
    }

    func fetchUserInfo(accessToken: String) async throws -> UserInfoResponse {
        var request = URLRequest(url: GoogleOAuth.userInfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await httpSession.data(for: request)
        try Self.validate(response: response, data: data, context: "userinfo")
        return try JSONDecoder().decode(UserInfoResponse.self, from: data)
    }

    static func validate(response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.tokenExchangeFailed("\(context): non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            LogService.log(.error, .auth, "\(context) HTTP \(http.statusCode)", detail: body)
            if let oauthError = try? JSONDecoder().decode(GoogleOAuth.ErrorResponse.self, from: data) {
                throw context == "userinfo"
                    ? AuthError.userInfoFetchFailed(oauthError.error)
                    : AuthError.tokenExchangeFailed(oauthError.error)
            }
            throw context == "userinfo"
                ? AuthError.userInfoFetchFailed("HTTP \(http.statusCode)")
                : AuthError.tokenExchangeFailed("HTTP \(http.statusCode)")
        }
    }

    /// Check if token is expiring soon.
    func isTokenExpiringSoon(for accountID: UUID) -> Bool {
        guard let expiresAt = keychain.oauthExpiresAt(for: accountID) else { return true }
        return expiresAt.timeIntervalSinceNow < AuthConstants.tokenRefreshThreshold
    }
}

// MARK: - GenericAccountDraft

struct GenericAccountDraft: Sendable {
    /// Sidebar label (Account.name)
    var accountName: String
    /// Sender display name for outgoing "From" header (Account.senderName)
    var name: String
    var email: String
    var password: String
    var imapHost: String
    var imapPort: Int
    var imapSecurity: ConnectionSecurity
    var smtpHost: String
    var smtpPort: Int
    var smtpSecurity: ConnectionSecurity
}
