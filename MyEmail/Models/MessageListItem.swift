//
//  MessageListItem.swift
//  MyEmail
//
//  Projection struct для ЛЮБОГО списочного представления (MessageListView,
//  search results, threaded list, Unified Inbox).
//
//  **КРИТИЧНО** (§5.4, bug 9.4 recipe):
//  - Здесь НЕТ полей `bodyText`/`bodyHTML`/`headers`.
//  - `references`/`messageID`/`inReplyTo` included for JWZ threading (RFC 5256).
//  - Swift компилятор физически не даст прочитать body через этот type.
//  - Все `ValueObservation`-запросы для списков идут через
//    `MessageListItem.fetchAll(db, sql: "SELECT id, uid, subject, ... FROM messages ...")`
//    с явным SELECT только metadata-колонок.
//  - `MessageMatcher` принимает `MessageListItem`, не `Message`.
//  - Полный `Message` (с body) загружается только в `MessageDetailView` через
//    `loadFullMessage(id:)`.
//

import Foundation
import GRDB

struct MessageListItem: FetchableRecord, Decodable,
                        Identifiable, Hashable, Sendable {
    var id: UUID
    var uid: UInt32
    var subject: String
    var fromName: String?
    var fromAddress: String
    var toAddresses: [String]
    var date: Date
    var preview: String
    var isRead: Bool
    var isFlagged: Bool
    var isAnswered: Bool
    var hasAttachments: Bool
    var threadID: String?
    var folderID: UUID
    var accountID: UUID
    var size: Int

    /// User-interaction score (open/reply/flag/move). Used by FTS5 ranking.
    var interactionScore: Int

    // Threading headers (JWZ algorithm, RFC 5256)
    var messageID: String?
    var inReplyTo: String?
    var references: [String]

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case uid
        case subject
        case fromName = "from_name"
        case fromAddress = "from_address"
        case toAddresses = "to_addresses"
        case date
        case preview
        case isRead = "is_read"
        case isFlagged = "is_flagged"
        case isAnswered = "is_answered"
        case hasAttachments = "has_attachments"
        case threadID = "thread_id"
        case folderID = "folder_id"
        case accountID = "account_id"
        case size
        case interactionScore = "interaction_score"
        case messageID = "message_id"
        case inReplyTo = "in_reply_to"
        case references
    }

    /// Canonical SELECT projection for list queries. Use with `WHERE` clause appended.
    static let listSQL = """
        SELECT m.id, m.uid, m.subject, m.from_name, m.from_address,
               m.to_addresses, m.date, m.preview,
               m.is_read, m.is_flagged, m.is_answered,
               m.has_attachments,
               m.thread_id, m.folder_id, m.account_id, m.size, m.interaction_score,
               m.message_id, m.in_reply_to, m."references"
        FROM messages m
        """

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.uid = try c.decode(UInt32.self, forKey: .uid)
        self.subject = try c.decode(String.self, forKey: .subject)
        self.fromName = try c.decodeIfPresent(String.self, forKey: .fromName)
        self.fromAddress = try c.decode(String.self, forKey: .fromAddress)

        let toRaw = try c.decode(String.self, forKey: .toAddresses)
        if let data = toRaw.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            self.toAddresses = arr
        } else {
            self.toAddresses = []
        }

        let ts = try c.decode(Double.self, forKey: .date)
        self.date = Date(timeIntervalSince1970: ts)

        self.preview = try c.decode(String.self, forKey: .preview)
        self.isRead = try c.decode(Bool.self, forKey: .isRead)
        self.isFlagged = try c.decode(Bool.self, forKey: .isFlagged)
        self.isAnswered = try c.decode(Bool.self, forKey: .isAnswered)

        self.hasAttachments = try c.decode(Bool.self, forKey: .hasAttachments)

        self.threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
        self.folderID = try c.decode(UUID.self, forKey: .folderID)
        self.accountID = try c.decode(UUID.self, forKey: .accountID)
        self.size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        self.interactionScore = try c.decodeIfPresent(Int.self, forKey: .interactionScore) ?? 0

        self.messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
        self.inReplyTo = try c.decodeIfPresent(String.self, forKey: .inReplyTo)

        let refsRaw = try c.decodeIfPresent(String.self, forKey: .references) ?? "[]"
        if let data = refsRaw.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            self.references = arr
        } else {
            self.references = []
        }
    }
}
