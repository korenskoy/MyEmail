//
//  MailtoParser.swift
//  MyEmail
//
//  Parses `mailto:` URLs per RFC 6068 into a MailtoPrefill struct ready to
//  be handed to ComposeView. Percent-decoding is delegated to URLComponents.
//

import Foundation

enum MailtoParser {

    /// Returns nil only when the URL is not a `mailto:` URL. Empty mailto
    /// links (e.g. `mailto:?subject=Hi`) parse to a prefill with empty
    /// recipient strings — that is still a legitimate compose request.
    static func parse(_ url: URL) -> MailtoPrefill? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        // URLComponents correctly handles the unusual mailto layout
        // (recipients in the path, headers in the query).
        guard let comp = URLComponents(string: url.absoluteString) else {
            return nil
        }

        // Path-portion recipients. URLComponents decodes percent-encoding.
        var to = comp.path
        var cc = ""
        var bcc = ""
        var subject = ""
        var body = ""

        for item in comp.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "to":      to = append(to, value)
            case "cc":      cc = append(cc, value)
            case "bcc":     bcc = append(bcc, value)
            case "subject": if subject.isEmpty { subject = value }
            case "body":    if body.isEmpty { body = value }
            default:        break
            }
        }

        return MailtoPrefill(
            to: normalize(to),
            cc: normalize(cc),
            bcc: normalize(bcc),
            subject: subject,
            body: body
        )
    }

    private static func append(_ left: String, _ right: String) -> String {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return "\(left),\(right)"
    }

    /// Split on commas, trim whitespace, drop empties, rejoin with ", ".
    private static func normalize(_ recipients: String) -> String {
        recipients
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
