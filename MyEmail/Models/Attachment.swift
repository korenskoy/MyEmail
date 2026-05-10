//
//  Attachment.swift
//  MyEmail
//
//  GRDB record для `attachments` table.
//
//  **Inline images** (content-id, `is_inline = 1`) обязательно extract'ятся на
//  файловую систему в `attachments/{accountID}/{messageID}/{partID}-{filename}`
//  при парсинге MIME (см. §5.4 и CLAUDE.md). `body_html` в DB **никогда** не
//  содержит base64 data URLs — только `cid:` refs, которые WKWebView резолвит
//  через URL-scheme handler.
//

import Foundation
import GRDB

struct Attachment: Identifiable, Codable, Hashable, Sendable,
                   FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "attachments"

    var id: UUID
    var partID: String
    var filename: String
    var mimeType: String
    var size: Int
    var contentID: String?
    var isInline: Bool
    var localPath: String?
    var messageID: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case partID = "part_id"
        case filename
        case mimeType = "mime_type"
        case size
        case contentID = "content_id"
        case isInline = "is_inline"
        case localPath = "local_path"
        case messageID = "message_id"
    }
}
