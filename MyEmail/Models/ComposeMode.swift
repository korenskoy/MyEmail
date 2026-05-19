//
//  ComposeMode.swift
//  MyEmail
//
//  Compose mode — stores only messageID + accountID.
//  Full Message is refetched by ComposeWindowContent.
//

import Foundation

/// Prefilled compose fields passed from external entry points (mailto: URLs,
/// drag-drop, AppleScript, etc). All values are RFC 6068-decoded strings;
/// recipient lists are pre-normalized comma-separated.
struct MailtoPrefill: Sendable, Hashable, Codable {
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var body: String
}

enum ComposeMode: Identifiable, Sendable, Hashable, Codable {
    case newMessage
    case mailto(id: UUID, prefill: MailtoPrefill)
    case reply(messageID: UUID, accountID: UUID)
    case replyAll(messageID: UUID, accountID: UUID)
    case forward(messageID: UUID, accountID: UUID)

    var id: String {
        switch self {
        case .newMessage: return "new"
        case .mailto(let mid, _): return "mailto-\(mid)"
        case .reply(let mid, _): return "reply-\(mid)"
        case .replyAll(let mid, _): return "replyAll-\(mid)"
        case .forward(let mid, _): return "fwd-\(mid)"
        }
    }

    var messageID: UUID? {
        switch self {
        case .newMessage, .mailto: return nil
        case .reply(let mid, _), .replyAll(let mid, _), .forward(let mid, _): return mid
        }
    }

    var accountID: UUID? {
        switch self {
        case .newMessage, .mailto: return nil
        case .reply(_, let aid), .replyAll(_, let aid), .forward(_, let aid): return aid
    }
    }
}
