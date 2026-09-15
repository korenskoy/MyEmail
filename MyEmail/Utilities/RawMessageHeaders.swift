//
//  RawMessageHeaders.swift
//  MyEmail
//
//  Byte-level edits to the header block of a raw RFC 5322 message.
//

import Foundation

enum RawMessageHeaders {

    /// Replaces the Subject header of `raw` with `subject`, RFC 2047-encoded.
    /// The body is carried over as the original bytes.
    ///
    /// Works on bytes, not a decoded String: decoding the whole message as UTF-8
    /// fails on 8-bit Latin-1/CP1252 mail, and the subject rewrite rule used to
    /// skip such messages outright. The header block is read as ISO-8859-1,
    /// which maps every byte to one scalar and back, so non-ASCII header bytes
    /// come out unchanged.
    ///
    /// Returns nil when there is no header/body separator.
    nonisolated static func replacingSubject(in raw: Data, with subject: String) -> Data? {
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) ?? raw.range(of: Data("\n\n".utf8)),
              var header = String(data: raw[raw.startIndex..<separator.lowerBound], encoding: .isoLatin1)
        else { return nil }

        // Header line endings normalized to CRLF; the body is left as sent.
        header = header
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")

        // Lines are delimited with explicit `\r\n` and `[^\r\n]`, never
        // multiline `^` or `.`: ICU treats U+0085 as a line break, and
        // ISO-8859-1 turns every 0x85 byte into one — the second byte of a raw
        // UTF-8 "х". Requiring a line start also skips `Subject:` inside
        // DKIM-Signature's `h=` list.
        let subjectLine = "(?i)(?:^|\r\n)Subject:[^\r\n]*"
        let foldedSubject = "(?i)((?:^|\r\n)Subject:[^\r\n]*)\r\n[ \t]+"

        // Unfold a multiline Subject (RFC 5322 §2.2.3).
        while header.range(of: foldedSubject, options: .regularExpression) != nil {
            header = header.replacingOccurrences(of: foldedSubject, with: "$1 ", options: .regularExpression)
        }

        if let line = header.range(of: subjectLine, options: .regularExpression) {
            // Keep the CRLF that ended the previous header line.
            let lead = header[line].utf8.starts(with: "\r\n".utf8) ? "\r\n" : ""
            header.replaceSubrange(line, with: lead + "Subject: =?utf-8?b?\(Data(subject.utf8).base64EncodedString())?=")
        }

        guard var message = header.data(using: .isoLatin1) else { return nil }
        message.append(raw[separator.lowerBound...])
        return message
    }
}
