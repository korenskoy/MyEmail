//
//  GoogleOAuth.swift
//  MyEmail
//
//  Google OAuth2 endpoint constants, URL builders, token response DTO.
//  Все value-type helpers — `nonisolated`, зовётся из `AuthService` actor.
//
//  Scope: **только** `https://mail.google.com/` (IMAP + SMTP XOAUTH2). Никаких
//  contacts / profile / openid — `ContactsService` работает с локальным
//  `CNContactStore`, а email/display-name берётся из ID token только если
//  `openid` был запрошен (мы его не запрашиваем).
//

import Foundation

enum GoogleOAuth {

    // MARK: - Endpoints

    /// RFC 8252 §8.1: Google Auth endpoints
    /// https://accounts.google.com/.well-known/openid-configuration
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Один-единственный scope. **Не добавлять contacts/profile** — см. §6.1.
    static let scope = "https://mail.google.com/"

    /// UserInfo endpoint — извлекаем email и имя для только что залогинившегося
    /// аккаунта (у нас нет `openid` scope, поэтому ID token недоступен; email
    /// получим через XOAUTH2 SASL prelogin в IMAP — но для M2 DOD (row в
    /// accounts) нам нужно knowать email до того как появится IMAPService).
    ///
    /// Вместо userinfo можно использовать Gmail API `users/me/profile`, но
    /// это требует отдельной активации Gmail API в Cloud Console. Проще —
    /// request `openid email profile` scopes параллельно с mail.google.com
    /// и парсить `id_token`. Но тогда у нас два scope запроса, и user в
    /// consent screen видит extra permissions.
    ///
    /// M2 workaround: запрашиваем `mail.google.com + email` — email-scope
    /// даёт доступ к userinfo без полного profile. В dialog consent это
    /// читается как "See your email address".
    static let extraScopes = "email"

    static var combinedScope: String {
        "\(scope) \(extraScopes)"
    }

    static let userInfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!

    // MARK: - Authorization URL

    struct AuthorizationRequest: Sendable {
        let clientID: String
        let redirectURI: String
        let state: String
        let codeChallenge: String
        let loginHint: String?

        var url: URL {
            var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
            var items: [URLQueryItem] = [
                .init(name: "client_id", value: clientID),
                .init(name: "redirect_uri", value: redirectURI),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: combinedScope),
                .init(name: "code_challenge", value: codeChallenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state),
                .init(name: "access_type", value: "offline"),  // forces refresh_token
                .init(name: "prompt", value: "consent")        // always return refresh_token
            ]
            if let loginHint, !loginHint.isEmpty {
                items.append(.init(name: "login_hint", value: loginHint))
            }
            components.queryItems = items
            return components.url!
        }
    }

    // MARK: - Token exchange

    /// Response от token endpoint. `refresh_token` возвращается только на
    /// первый exchange (или если `prompt=consent`). На refresh Google **может**
    /// вернуть новый refresh_token — это Refresh Token Rotation, его нужно
    /// сохранять немедленно (§6.1).
    struct TokenResponse: Decodable, Sendable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        let tokenType: String
        let scope: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case scope
            case idToken = "id_token"
        }
    }

    /// Строит URLRequest к token endpoint для initial code exchange.
    static func codeExchangeRequest(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        clientID: String,
        clientSecret: String
    ) -> URLRequest {
        let body: [String: String] = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        return tokenRequest(body: body)
    }

    /// Refresh access token. Используется в `AuthService.refresh(account:)`
    /// и proactive sweep.
    static func refreshRequest(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) -> URLRequest {
        let body: [String: String] = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        return tokenRequest(body: body)
    }

    private static func tokenRequest(body: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        let encoded = body
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
        request.httpBody = encoded.data(using: .utf8)
        return request
    }

    private static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        // OAuth2 form-urlencoded требует более строгий escape: `+`, `&`, `=`
        // должны быть escaped, а stdlib `urlQueryAllowed` их пропускает.
        allowed.remove(charactersIn: "+&=")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - Error response

extension GoogleOAuth {
    struct ErrorResponse: Decodable, Sendable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}
