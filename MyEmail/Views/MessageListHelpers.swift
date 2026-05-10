//
//  MessageListHelpers.swift
//  MyEmail
//
//  Focused-action passthrough + MessageListItem display helpers.
//  The former `TableStyleBridge` (KVO + CA-action patcher for SwiftUI
//  Table) was removed together with the SwiftUI Table itself —
//  MessageListNSTable uses plain NSTableView, which has predictable
//  layout semantics and needs no bridge.
//

import AppKit
import SwiftUI

// MARK: - Focused actions modifier (legacy passthrough)

/// After the AppKit migration all message keyboard shortcuts are routed
/// via the responder chain (MainWindowController @objc selectors), so this
/// modifier no longer wires any FocusedValue — it is kept as a no-op so
/// call sites in MessageListTable stay unchanged. Remove callers in V2.
struct MessageFocusedActions: ViewModifier {
    let selectedMessageID: UUID?
    let onArchive: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onReply: (UUID) -> Void
    let onReplyAll: (UUID) -> Void
    let onForward: (UUID) -> Void
    let onToggleRead: (UUID) -> Void
    let onToggleFlag: (UUID) -> Void
    let onJunk: (UUID) -> Void
    let onOpenInWindow: (UUID) -> Void

    func body(content: Content) -> some View { content }
}

// MARK: - Display helpers

extension MessageListItem {
    var displayFrom: String {
        // fromName may be "" (not nil) for messages whose From: header has
        // no display name — fall back to the address in that case too.
        let name = (fromName?.isEmpty == false) ? fromName! : fromAddress
        return extractName(name)
    }

    var formattedSize: String {
        FormatHelpers.formatByteCount(size)
    }

    /// Sent/Drafts column: comma-separated recipient names (Mail.app style).
    var displayTo: String {
        guard !toAddresses.isEmpty else { return "" }
        return toAddresses.map { extractName($0) }.joined(separator: ", ")
    }

    /// Extract display name from "Name <addr>" or return the address as-is.
    private func extractName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<"),
           let close = trimmed.lastIndex(of: ">"), open < close {
            let name = String(trimmed[trimmed.startIndex..<open])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !name.isEmpty { return name }
            return String(trimmed[trimmed.index(after: open)..<close])
        }
        return trimmed
    }
}
