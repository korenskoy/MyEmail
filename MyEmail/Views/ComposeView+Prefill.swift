//
//  ComposeView+Prefill.swift
//  MyEmail
//
//  Reply/forward prefill for ComposeView. Builds attributed body with
//  HTML-backed <blockquote> for replies and From/Date/Subject header for
//  forwards. Separated from the main view to keep file under 500 lines.
//

import AppKit
import Foundation
import SwiftUI

extension ComposeView {

    /// Shared date formatter for attribution and forward-header lines.
    /// Cached to avoid per-invocation allocation.
    private static let replyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func prefill() {
        // Mailto needs no source Message — apply prefill regardless.
        if case .mailto(_, let prefill) = mode {
            toField = prefill.to
            ccField = prefill.cc
            bccField = prefill.bcc
            subjectField = prefill.subject
            if !prefill.body.isEmpty {
                attributedBody = NSAttributedString(
                    string: prefill.body,
                    attributes: RichTextSupport.defaultTypingAttributes
                )
            }
            return
        }
        guard let msg = message else { return }
        switch mode {
        case .newMessage, .mailto:
            break
        case .reply:
            toField = msg.replyToAddresses.first ?? msg.fromAddress
            subjectField = prefixed(msg.subject, prefix: "Re:")
            attributedBody = buildReplyBody(for: msg)
        case .replyAll:
            toField = msg.replyToAddresses.first ?? msg.fromAddress
            let others = (msg.toAddresses + msg.ccAddresses)
                .filter { !$0.isEmpty
                    && $0.caseInsensitiveCompare(selectedAccount.email) != .orderedSame }
            ccField = others.joined(separator: ", ")
            subjectField = prefixed(msg.subject, prefix: "Re:")
            attributedBody = buildReplyBody(for: msg)
        case .forward:
            subjectField = prefixed(msg.subject, prefix: "Fwd:")
            attributedBody = buildForwardBody(for: msg)
        }
    }

    /// Prepend `prefix` only if the subject does not already carry it
    /// (case-insensitive; tolerates variants like "RE:", "re:", "Re[2]:").
    private func prefixed(_ subject: String, prefix: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let base = prefix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let leading = trimmed.lowercased()
        if leading.hasPrefix(base + ":") || leading.hasPrefix(base + "[") {
            return subject
        }
        return "\(prefix) \(subject)"
    }

    /// Reply body: two blank lines for the cursor, attribution, then a
    /// <blockquote> containing the original message (HTML if available).
    private func buildReplyBody(for msg: Message) -> NSAttributedString {
        let attrs = RichTextSupport.defaultTypingAttributes
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "\n\n", attributes: attrs))
        out.append(NSAttributedString(string: attribution(msg) + "\n", attributes: attrs))
        out.append(buildQuote(for: msg))
        return out
    }

    /// Build the quoted original message. Parses the source HTML directly
    /// (avoids the nested-<html> pitfall of wrapping full documents in a
    /// <blockquote>) and then applies indentation + muted color as a paragraph
    /// style across the whole range — Mail.app / Thunderbird convention.
    private func buildQuote(for msg: Message) -> NSAttributedString {
        let base: NSAttributedString
        if let html = msg.bodyHTML, !html.isEmpty,
           let parsed = RichTextSupport.attributedFromHTML(html) {
            base = parsed
        } else {
            base = NSAttributedString(
                string: msg.bodyText ?? "",
                attributes: RichTextSupport.defaultTypingAttributes
            )
        }
        return RichTextSupport.applyQuoteStyle(to: base)
    }

    /// Forward body: header block, blank line, original body (HTML preserved
    /// when present).
    private func buildForwardBody(for msg: Message) -> NSAttributedString {
        let attrs = RichTextSupport.defaultTypingAttributes
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(
            string: "\n\n---------- Forwarded message ----------\n",
            attributes: attrs
        ))
        out.append(NSAttributedString(string: forwardHeader(msg) + "\n\n", attributes: attrs))
        if let html = msg.bodyHTML, !html.isEmpty,
           let parsed = RichTextSupport.attributedFromHTML(html) {
            out.append(parsed)
        } else {
            out.append(NSAttributedString(string: msg.bodyText ?? "", attributes: attrs))
        }
        return out
    }

    /// RFC 3676 / common MUA attribution line: "On <date>, <sender> wrote:".
    private func attribution(_ msg: Message) -> String {
        let sender: String = {
            if let name = msg.fromName, !name.isEmpty { return "\(name) <\(msg.fromAddress)>" }
            return msg.fromAddress
        }()
        return String(
            format: String(localized: "On %@, %@ wrote:"),
            Self.replyDateFormatter.string(from: msg.date),
            sender
        )
    }

    private func forwardHeader(_ msg: Message) -> String {
        var lines: [String] = []
        lines.append("From: \(msg.fromName.map { "\($0) <\(msg.fromAddress)>" } ?? msg.fromAddress)")
        lines.append("Date: \(Self.replyDateFormatter.string(from: msg.date))")
        lines.append("Subject: \(msg.subject)")
        if !msg.toAddresses.isEmpty {
            lines.append("To: \(msg.toAddresses.joined(separator: ", "))")
        }
        if !msg.ccAddresses.isEmpty {
            lines.append("Cc: \(msg.ccAddresses.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
