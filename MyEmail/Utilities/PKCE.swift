//
//  PKCE.swift
//  MyEmail
//
//  RFC 7636 — Proof Key for Code Exchange. Обязательно для desktop app
//  OAuth flow (§6.1): client secret извлекается из бинаря, поэтому
//  authorization code protection должен идти через PKCE, не через secret.
//
//  Все методы — `nonisolated static`, value-type helper. Зовётся из
//  `AuthService` actor.
//

import CryptoKit
import Foundation

enum PKCE {

    /// `code_verifier`: 43..128 символов из unreserved-set (`[A-Za-z0-9-._~]`).
    /// Мы генерим 64 байта random → base64url-encode → получаем ~86 символов.
    /// Этого с запасом для entropy и в пределах лимитов.
    nonisolated static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedString()
    }

    /// `code_challenge = BASE64URL(SHA256(code_verifier))` (method = S256).
    nonisolated static func challenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest).base64URLEncodedString()
    }

    /// `state` parameter для CSRF-защиты. В callback сверяется побайтно с
    /// отправленным значением. 32 байта random → base64url.
    nonisolated static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedString()
    }
}

// MARK: - Base64URL encoding

extension Data {
    /// RFC 4648 §5 — base64url, без padding. Заменяет `+`/`/` на `-`/`_`,
    /// обрезает trailing `=`. Именно этот формат требует OAuth PKCE spec.
    fileprivate func base64URLEncodedString() -> String {
        var s = self.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}
