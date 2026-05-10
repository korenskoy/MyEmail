//
//  IMAPUTF7.swift
//  MyEmail
//
//  Modified UTF-7 decoder for IMAP folder names (RFC 3501 §5.1.3).
//  Nonisolated value type — called from IMAPService actor.
//

import Foundation

enum IMAPUTF7 {
    /// Encode Unicode folder name to IMAP modified UTF-7 (RFC 3501 §5.1.3).
    /// ASCII printable 0x20-0x7E pass through (except '&' → '&-').
    /// Non-ASCII runs are UTF-16BE → modified base64 (',' instead of '/').
    nonisolated static func encode(_ input: String) -> String {
        var result = ""
        var nonASCII: [UInt16] = []

        func flushNonASCII() {
            guard !nonASCII.isEmpty else { return }
            let data = Data(nonASCII.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
            let b64 = data.base64EncodedString()
                .replacingOccurrences(of: "/", with: ",")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            result += "&\(b64)-"
            nonASCII.removeAll()
        }

        for scalar in input.unicodeScalars {
            let val = scalar.value
            if val >= 0x20 && val <= 0x7E {
                if scalar == "&" {
                    flushNonASCII()
                    result += "&-"
                } else {
                    flushNonASCII()
                    result.append(Character(scalar))
                }
            } else {
                // Encode as UTF-16BE
                let utf16 = String(scalar).utf16
                for unit in utf16 { nonASCII.append(unit) }
            }
        }
        flushNonASCII()
        return result
    }

    /// Decode IMAP modified UTF-7 folder name to Unicode.
    /// Falls through to input unchanged if no shift sequences found.
    nonisolated static func decode(_ input: String) -> String {
        var result = ""
        var base64Buf = ""
        var inShift = false

        for ch in input {
            if inShift {
                if ch == "-" {
                    if base64Buf.isEmpty {
                        result.append("&")
                    } else {
                        let standard = base64Buf
                            .replacingOccurrences(of: ",", with: "/")
                        if let data = Data(base64Encoded: padBase64(standard)) {
                            result += decodeUTF16BE(data)
                        }
                    }
                    base64Buf = ""
                    inShift = false
                } else {
                    base64Buf.append(ch)
                }
            } else if ch == "&" {
                inShift = true
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private nonisolated static func padBase64(_ s: String) -> String {
        let remainder = s.count % 4
        if remainder == 0 { return s }
        return s + String(repeating: "=", count: 4 - remainder)
    }

    private nonisolated static func decodeUTF16BE(_ data: Data) -> String {
        let encoding = String.Encoding.utf16BigEndian
        return String(data: data, encoding: encoding) ?? ""
    }
}
