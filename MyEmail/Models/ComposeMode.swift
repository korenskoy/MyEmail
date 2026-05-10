//
//  ComposeMode.swift
//  MyEmail
//
//  Compose mode — stores only messageID + accountID.
//  Full Message is refetched by ComposeWindowContent.
//

import Foundation

enum ComposeMode: Identifiable, Sendable, Hashable, Codable {
    case newMessage
    case reply(messageID: UUID, accountID: UUID)
    case replyAll(messageID: UUID, accountID: UUID)
    case forward(messageID: UUID, accountID: UUID)

    var id: String {
        switch self {
        case .newMessage: return "new"
        case .reply(let mid, _): return "reply-\(mid)"
        case .replyAll(let mid, _): return "replyAll-\(mid)"
        case .forward(let mid, _): return "fwd-\(mid)"
        }
    }

    var messageID: UUID? {
        switch self {
        case .newMessage: return nil
        case .reply(let mid, _), .replyAll(let mid, _), .forward(let mid, _): return mid
        }
    }

    var accountID: UUID? {
        switch self {
        case .newMessage: return nil
        case .reply(_, let aid), .replyAll(_, let aid), .forward(_, let aid): return aid
    }
    }
}
