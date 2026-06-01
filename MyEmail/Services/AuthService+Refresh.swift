//
//  AuthService+Refresh.swift
//  MyEmail
//
//  Token refresh, proactive sweep, re-auth via OAuth.
//

import AppKit
import Foundation

extension AuthService {

    // MARK: - Refresh with coalescing lock (§6.1, §9.9, hard rule 15)

    /// Refresh access token. Concurrent callers for the same account
    /// await the same in-flight Task instead of firing duplicate requests.
    /// Sequential callers are gated by a 30-second cooldown — Google rotates
    /// the refresh-token on every refresh and invalidates the grant if
    /// rotations come too fast.
    ///
    /// `reason` is logged so flood sources can be diagnosed.
    ///
    /// `force` bypasses the proactive back-off and cooldown — used by the
    /// reactive auth-failure-retry path where the server actually rejected the
    /// current token, so we must mint a new one regardless of our timers.
    func refresh(accountID: UUID, reason: String = "explicit", force: Bool = false) async throws {
        // (1) Coalesce concurrent callers onto the same in-flight Task.
        if let existing = refreshTasks[accountID] {
            try await existing.value
            return
        }

        if !force {
            // (2a) Proactive back-off: Google handed back a token it would not
            //      extend, so re-refreshing before its real expiry is futile and
            //      only floods the grant endpoint (→ invalid_grant). Park until
            //      the token actually expires, then refresh reactively.
            if let until = proactiveBackoffUntil[accountID], Date() < until {
                LogService.log(.debug, .auth, "Refresh skipped (backoff)",
                               detail: "account=\(accountID) reason=\(reason)")
                return
            }

            // (2b) Cooldown — UNCONDITIONAL. The previous `&& !isTokenExpiringSoon`
            //      escape disarmed this gate for the token's whole final 5-min
            //      window and let sweep + lazy flood Google (hard rule 15, §9.9).
            //      A token refreshed < minRefreshInterval ago is still usable, so
            //      reusing it for that window is always safe.
            if let last = lastRefreshAt[accountID],
               Date().timeIntervalSince(last) < AuthConstants.minRefreshInterval {
                LogService.log(.debug, .auth, "Refresh skipped (cooldown)",
                               detail: "account=\(accountID) reason=\(reason)")
                return
            }
        }

        let task = Task { [self] in
            defer { refreshTasks.removeValue(forKey: accountID) }
            // (3) Double-check inside the Task: a previous caller may have
            //     just finished refreshing between our enqueue and our run.
            //     Forced callers always proceed — the server rejected the token.
            if !force, !isTokenExpiringSoon(for: accountID) {
                LogService.log(.debug, .auth, "Refresh skipped (token fresh)",
                               detail: "account=\(accountID) reason=\(reason)")
                return
            }
            try await performRefresh(accountID: accountID, reason: reason)
        }
        refreshTasks[accountID] = task
        try await task.value
    }

    private func performRefresh(accountID: UUID, reason: String) async throws {
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
        lastRefreshAt[accountID] = Date()

        // If Google handed back a token that is ITSELF still expiring soon, it
        // served the cached near-expiry token and will not mint a fresh one
        // until this one truly expires. Park proactive refreshes until then so a
        // single refresh — not a 5-minute flood — covers the token's tail end.
        if TimeInterval(tokens.expiresIn) < AuthConstants.tokenRefreshThreshold {
            proactiveBackoffUntil[accountID] = expiresAt
        } else {
            proactiveBackoffUntil.removeValue(forKey: accountID)
        }

        LogService.log(.info, .auth, "Token refreshed",
                       detail: "account=\(accountID) reason=\(reason) expiresIn=\(tokens.expiresIn)s")
    }

    // MARK: - Current token (lazy refresh)

    /// Returns valid access token, refreshing if near expiry.
    func currentAccessToken(for accountID: UUID) async throws -> String {
        if isTokenExpiringSoon(for: accountID) {
            try await refresh(accountID: accountID, reason: "lazy")
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
                try? await refresh(accountID: account.id, reason: "sweep")
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
        // Fresh grant — wipe stale rate-limit/backoff history so the new
        // long-lived token isn't suppressed by the dead token's timers.
        proactiveBackoffUntil.removeValue(forKey: accountID)
        lastRefreshAt.removeValue(forKey: accountID)
        try accountRepository.setAuthState(.ok, for: accountID)
        LogService.log(.info, .auth, "Re-authenticated \(email)")
    }
}
