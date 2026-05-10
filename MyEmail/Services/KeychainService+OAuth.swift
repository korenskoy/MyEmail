//
//  KeychainService+OAuth.swift
//  MyEmail
//
//  Convenience wrappers для OAuth credentials (Gmail и другие OAuth2
//  провайдеры). Ключи в Keychain:
//
//    {accountID}.oauth.refresh     — refresh_token (long-lived)
//    {accountID}.oauth.access      — access_token (short-lived)
//    {accountID}.oauth.expiresAt   — Unix timestamp, ISO-8601 как String
//    {accountID}.password          — plain auth password (для non-OAuth accounts)
//
//  Всё через `kSecAttrAccessibleAfterFirstUnlock` (inherited от
//  `KeychainService.set`) — hard rule 17.
//

import Foundation

extension KeychainService {

    // MARK: - Account-scoped OAuth key names

    private nonisolated func refreshKey(for accountID: UUID) -> String {
        "\(accountID.uuidString).oauth.refresh"
    }

    private nonisolated func accessKey(for accountID: UUID) -> String {
        "\(accountID.uuidString).oauth.access"
    }

    private nonisolated func expiresAtKey(for accountID: UUID) -> String {
        "\(accountID.uuidString).oauth.expiresAt"
    }

    private nonisolated func passwordKey(for accountID: UUID) -> String {
        "\(accountID.uuidString).password"
    }

    // MARK: - OAuth tokens

    /// Сохраняет полный tokenset после code exchange. Если `refreshToken` nil
    /// (Google вернул response без refresh — бывает на refresh без
    /// `prompt=consent`) — существующий refresh token **не трогаем**, чтобы
    /// не потерять сессию.
    nonisolated func saveOAuthTokens(
        for accountID: UUID,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date
    ) throws {
        try set(accessToken, for: accessKey(for: accountID))
        if let refreshToken {
            try set(refreshToken, for: refreshKey(for: accountID))
        }
        let iso = ISO8601DateFormatter().string(from: expiresAt)
        try set(iso, for: expiresAtKey(for: accountID))
    }

    nonisolated func oauthAccessToken(for accountID: UUID) throws -> String {
        try getString(for: accessKey(for: accountID))
    }

    nonisolated func oauthRefreshToken(for accountID: UUID) throws -> String {
        try getString(for: refreshKey(for: accountID))
    }

    nonisolated func oauthExpiresAt(for accountID: UUID) -> Date? {
        guard let iso = try? getString(for: expiresAtKey(for: accountID)),
              let date = ISO8601DateFormatter().date(from: iso) else {
            return nil
        }
        return date
    }

    nonisolated func deleteOAuthTokens(for accountID: UUID) throws {
        // Ошибки `itemNotFound` глотаем — удаление должно быть идемпотентным.
        for key in [
            refreshKey(for: accountID),
            accessKey(for: accountID),
            expiresAtKey(for: accountID)
        ] {
            do {
                try delete(for: key)
            } catch KeychainError.itemNotFound {
                continue
            }
        }
    }

    // MARK: - Plain password

    nonisolated func savePassword(_ password: String, for accountID: UUID) throws {
        try set(password, for: passwordKey(for: accountID))
    }

    nonisolated func password(for accountID: UUID) throws -> String {
        try getString(for: passwordKey(for: accountID))
    }

    nonisolated func deletePassword(for accountID: UUID) throws {
        do {
            try delete(for: passwordKey(for: accountID))
        } catch KeychainError.itemNotFound {
            // ok
        }
    }

    // MARK: - Account deletion cascade

    /// Удаление всех credentials для аккаунта. Используется при delete
    /// account (§6.1 — cascade delete GRDB + Keychain + CacheService).
    nonisolated func deleteAllCredentials(for accountID: UUID) throws {
        try deleteOAuthTokens(for: accountID)
        try deletePassword(for: accountID)
    }
}
