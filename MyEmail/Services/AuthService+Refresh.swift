//
//  AuthService+Refresh.swift
//  MyEmail
//
//  Token refresh, proactive sweep, re-auth via OAuth.
//

import AppKit
import Foundation

extension AuthService {

    // MARK: - Refresh with coalescing lock (§6.1, §9.9)

    /// Refresh access token. Concurrent callers for the same account
    /// await the same in-flight Task instead of firing duplicate requests.
    func refresh(accountID: UUID) async throws {
        // If refresh already in progress, await the existing task
        if let existing = refreshTasks[accountID] {
            try await existing.value
            return
        }

        let task = Task { [self] in
            defer { refreshTasks.removeValue(forKey: accountID) }
            try await performRefresh(accountID: accountID)
        }
        refreshTasks[accountID] = task
        try await task.value
    }

    private func performRefresh(accountID: UUID) async throws {
        let refreshToken: String
        do {
            refreshToken = try keychain.oauthRefreshToken(for: accountID)
        } catch {
            LogService.log(.error, .auth, "No refresh token", detail: "\(accountID)")
            try? accountRepository.setAuthState(.needsReauth, for: accountID)
            throw AuthError.tokenExchangeFailed("no refresh token")
        }

        let request = GoogleOAuth.refreshRequest(
            refreshToken: refreshToken,
            clientID: Secrets.googleClientID,
            clientSecret: Secrets.googleClientSecret
        )
        let (data, response) = try await httpSession.data(for: request)

        // invalid_grant → needsReauth
        if let http = response as? HTTPURLResponse, http.statusCode == 400,
           let errResp = try? JSONDecoder().decode(GoogleOAuth.ErrorResponse.self, from: data),
           errResp.error == "invalid_grant" {
            LogService.log(.error, .auth, "invalid_grant → needsReauth", detail: "\(accountID)")
            try? accountRepository.setAuthState(.needsReauth, for: accountID)
            throw AuthError.tokenExchangeFailed("invalid_grant")
        }

        try Self.validate(response: response, data: data, context: "refresh")
        let tokens = try JSONDecoder().decode(GoogleOAuth.TokenResponse.self, from: data)

        let expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        try keychain.saveOAuthTokens(
            for: accountID, accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken, expiresAt: expiresAt
        )
        LogService.log(.info, .auth, "Token refreshed", detail: "\(accountID)")
    }

    // MARK: - Current token (lazy refresh)

    /// Returns valid access token, refreshing if near expiry.
    func currentAccessToken(for accountID: UUID) async throws -> String {
        if isTokenExpiringSoon(for: accountID) {
            try await refresh(accountID: accountID)
        }
        return try keychain.oauthAccessToken(for: accountID)
    }

    // MARK: - Proactive sweep (§9.9)

    func startProactiveSweep() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { break }
                await self.sweepOnce()
            }
        }
    }

    private func sweepOnce() async {
        guard let accounts = try? accountRepository.allEnabled() else { return }
        for account in accounts where account.authType == .oauth2 && account.authState == .ok {
            if isTokenExpiringSoon(for: account.id) {
                try? await refresh(accountID: account.id)
            }
        }
    }

    // MARK: - Re-auth via OAuth (for needsReauth accounts)

    func refreshViaOAuth(accountID: UUID, email: String) async throws {
        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.generateState()
        let redirectURI = Secrets.googleRedirectURI

        let authRequest = GoogleOAuth.AuthorizationRequest(
            clientID: Secrets.googleClientID,
            redirectURI: redirectURI, state: state,
            codeChallenge: challenge, loginHint: email
        )

        await MainActor.run { NSWorkspace.shared.open(authRequest.url) }

        let callbackURL = try await OAuthCallbackBroker.shared
            .waitForCallback(expectedState: state)

        let (code, returnedState) = try parseCallback(callbackURL)
        guard returnedState == state else { throw AuthError.stateMismatch }

        let tokens = try await exchangeCode(code, verifier: verifier, redirectURI: redirectURI)
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))

        try keychain.saveOAuthTokens(
            for: accountID, accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken, expiresAt: expiresAt
        )
        try accountRepository.setAuthState(.ok, for: accountID)
        LogService.log(.info, .auth, "Re-authenticated \(email)")
    }
}
