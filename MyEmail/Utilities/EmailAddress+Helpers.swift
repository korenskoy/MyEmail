//
//  EmailAddress+Helpers.swift
//  MyEmail
//
//  Convenience wrappers over SwiftMail's EmailAddress parser
//  for extracting parts from raw RFC 5322 address strings.
//

import SwiftMail

extension EmailAddress {
    /// Extract just the email from a possibly RFC 5322 formatted string.
    nonisolated static func emailOnly(from raw: String) -> String {
        EmailAddress(raw)?.address ?? raw
    }

    /// Extract display name, falling back to email.
    nonisolated static func displayName(from raw: String) -> String {
        guard let parsed = EmailAddress(raw) else { return raw }
        return parsed.name ?? parsed.address
    }

    /// Format array of RFC 5322 addresses as comma-separated display names.
    nonisolated static func formatList(_ addresses: [String]) -> String {
        addresses.map { displayName(from: $0) }.joined(separator: ", ")
    }
}
