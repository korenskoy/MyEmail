//
//  Message.swift
//  MyEmail
//
//  Full GRDB record для `messages` table с `body_text` и `body_html`.
//
//  ВАЖНО (bug 9.4 recipe, §5.4): `Message` загружается ТОЛЬКО в
//  `MessageDetailView` через `loadFullMessage(id:)`. Списки, search results,
//  threaded views — всегда через `MessageListItem` projection. Swift компилятор
//  не даст случайно прочитать body через projection — там этих полей нет.
//
//  Никогда не использовать `Message.fetchAll` в контексте списков.
//

import Foundation
import GRDB

struct Message: Identifiable, Codable, Hashable, Sendable,
                FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "messages"

    var id: UUID
    var uid: UInt32

    // RFC822 headers
    var messageID: String?
    var inReplyTo: String?

    /// JSON array → [String] через custom coder (см. extension ниже)
    var references: [String]

    var subject: String
    var fromName: String?
    var fromAddress: String
    var toAddresses: [String]
    var ccAddresses: [String]
    var bccAddresses: [String]
    var replyToAddresses: [String]

    /// Denormalized plain-text mirrors of `to/cc/bccAddresses` for FTS5.
    /// Always kept in sync via `Message.searchJoin(_:)`. Not part of the
    /// public API — purely an index helper.
    var toSearch: String
    var ccSearch: String
    var bccSearch: String

    /// List-ID / List-Post mailing-list header for `list:` operator.
    var listID: String?

    /// Sender's mail client — first populated value of
    /// `User-Agent` / `X-Mailer` / `X-Mail-Agent` / `X-Newsreader`.
    /// Parsed in persistHeaders; rendered as an icon in MessageHeaderBar
    /// via the MUAResolver XPC service.
    var userAgent: String?

    var date: Date
    var preview: String

    // Flags
    var isRead: Bool
    var isFlagged: Bool
    var isAnswered: Bool
    var isForwarded: Bool
    var isDraft: Bool

    var size: Int

    var threadID: String?

    /// User-interaction score (open/reply/flag/move). Used by FTS5 ranking.
    var interactionScore: Int

    /// NULL до первого `fetchBody`.
    var bodyText: String?
    /// HTML body с `cid:`-ссылками на inline-images (НЕ base64 data URLs —
    /// см. §9.4 и attachment extraction rule).
    var bodyHTML: String?

    /// Thunderbird §6.3: how much of this message has been downloaded.
    var downloadState: DownloadState

    /// Convenience accessor for code that only checks "is body loaded?"
    var hasBody: Bool { downloadState == .full }

    var isEncrypted: Bool
    var hasAttachments: Bool

    var folderID: UUID
    var accountID: UUID

    // MARK: - Memberwise init (needed because custom Codable suppresses synthesis)

    init(
        id: UUID, uid: UInt32, messageID: String?, inReplyTo: String?,
        references: [String], subject: String, fromName: String?,
        fromAddress: String, toAddresses: [String], ccAddresses: [String],
        bccAddresses: [String], replyToAddresses: [String],
        date: Date, preview: String,
        isRead: Bool, isFlagged: Bool, isAnswered: Bool,
        isForwarded: Bool, isDraft: Bool, size: Int, threadID: String?,
        interactionScore: Int = 0,
        bodyText: String?, bodyHTML: String?, downloadState: DownloadState = .envelope,
        isEncrypted: Bool = false, hasAttachments: Bool = false,
        listID: String? = nil,
        userAgent: String? = nil,
        folderID: UUID, accountID: UUID
    ) {
        self.id = id; self.uid = uid; self.messageID = messageID
        self.inReplyTo = inReplyTo; self.references = references
        self.subject = subject; self.fromName = fromName
        self.fromAddress = fromAddress; self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses; self.bccAddresses = bccAddresses
        self.replyToAddresses = replyToAddresses; self.date = date
        self.preview = preview; self.isRead = isRead
        self.isFlagged = isFlagged; self.isAnswered = isAnswered
        self.isForwarded = isForwarded; self.isDraft = isDraft
        self.size = size; self.threadID = threadID
        self.interactionScore = interactionScore
        self.bodyText = bodyText; self.bodyHTML = bodyHTML
        self.downloadState = downloadState; self.isEncrypted = isEncrypted
        self.hasAttachments = hasAttachments; self.folderID = folderID
        self.accountID = accountID
        self.toSearch = Self.searchJoin(toAddresses)
        self.ccSearch = Self.searchJoin(ccAddresses)
        self.bccSearch = Self.searchJoin(bccAddresses)
        self.listID = listID
        self.userAgent = userAgent
    }

    /// Build space-joined, lowercased, comma-stripped representation of an
    /// address list for FTS5 indexing.
    nonisolated static func searchJoin(_ addresses: [String]) -> String {
        addresses
            .map { $0.replacingOccurrences(of: ",", with: " ").lowercased() }
            .joined(separator: " ")
    }

    // MARK: - Codable column mapping

    enum CodingKeys: String, CodingKey {
        case id
        case uid
        case messageID = "message_id"
        case inReplyTo = "in_reply_to"
        case references
        case subject
        case fromName = "from_name"
        case fromAddress = "from_address"
        case toAddresses = "to_addresses"
        case ccAddresses = "cc_addresses"
        case bccAddresses = "bcc_addresses"
        case replyToAddresses = "reply_to_addresses"
        case toSearch = "to_search"
        case ccSearch = "cc_search"
        case bccSearch = "bcc_search"
        case listID = "list_id"
        case userAgent = "user_agent"
        case date
        case preview
        case isRead = "is_read"
        case isFlagged = "is_flagged"
        case isAnswered = "is_answered"
        case isForwarded = "is_forwarded"
        case isDraft = "is_draft"
        case size
        case threadID = "thread_id"
        case interactionScore = "interaction_score"
        case bodyText = "body_text"
        case bodyHTML = "body_html"
        case downloadState = "download_state"
        case isEncrypted = "is_encrypted"
        case hasAttachments = "has_attachments"
        case folderID = "folder_id"
        case accountID = "account_id"
    }

    // MARK: - JSON array encoding for address lists and references

    /// References stored as JSON text. Provide explicit encoding/decoding
    /// so GRDB sees a String column instead of an array type.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.uid = try c.decode(UInt32.self, forKey: .uid)
        self.messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
        self.inReplyTo = try c.decodeIfPresent(String.self, forKey: .inReplyTo)
        self.references = try Self.decodeJSONArray(c, .references)

        self.subject = try c.decode(String.self, forKey: .subject)
        self.fromName = try c.decodeIfPresent(String.self, forKey: .fromName)
        self.fromAddress = try c.decode(String.self, forKey: .fromAddress)

        self.toAddresses = try Self.decodeJSONArray(c, .toAddresses)
        self.ccAddresses = try Self.decodeJSONArray(c, .ccAddresses)
        self.bccAddresses = try Self.decodeJSONArray(c, .bccAddresses)
        self.replyToAddresses = try Self.decodeJSONArray(c, .replyToAddresses)
        self.toSearch = (try? c.decode(String.self, forKey: .toSearch)) ?? Self.searchJoin(self.toAddresses)
        self.ccSearch = (try? c.decode(String.self, forKey: .ccSearch)) ?? Self.searchJoin(self.ccAddresses)
        self.bccSearch = (try? c.decode(String.self, forKey: .bccSearch)) ?? Self.searchJoin(self.bccAddresses)
        self.listID = try c.decodeIfPresent(String.self, forKey: .listID)
        self.userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)

        // `date` stored as REAL (Unix timestamp).
        let ts = try c.decode(Double.self, forKey: .date)
        self.date = Date(timeIntervalSince1970: ts)

        self.preview = try c.decode(String.self, forKey: .preview)
        self.isRead = try c.decode(Bool.self, forKey: .isRead)
        self.isFlagged = try c.decode(Bool.self, forKey: .isFlagged)
        self.isAnswered = try c.decode(Bool.self, forKey: .isAnswered)
        self.isForwarded = try c.decode(Bool.self, forKey: .isForwarded)
        self.isDraft = try c.decode(Bool.self, forKey: .isDraft)

        self.size = try c.decode(Int.self, forKey: .size)
        self.threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
        self.interactionScore = try c.decodeIfPresent(Int.self, forKey: .interactionScore) ?? 0

        self.bodyText = try c.decodeIfPresent(String.self, forKey: .bodyText)
        self.bodyHTML = try c.decodeIfPresent(String.self, forKey: .bodyHTML)
        self.downloadState = try c.decode(DownloadState.self, forKey: .downloadState)
        self.isEncrypted = try c.decode(Bool.self, forKey: .isEncrypted)
        self.hasAttachments = try c.decode(Bool.self, forKey: .hasAttachments)

        self.folderID = try c.decode(UUID.self, forKey: .folderID)
        self.accountID = try c.decode(UUID.self, forKey: .accountID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(uid, forKey: .uid)
        try c.encodeIfPresent(messageID, forKey: .messageID)
        try c.encodeIfPresent(inReplyTo, forKey: .inReplyTo)
        try c.encode(Self.encodeJSONArray(references), forKey: .references)

        try c.encode(subject, forKey: .subject)
        try c.encodeIfPresent(fromName, forKey: .fromName)
        try c.encode(fromAddress, forKey: .fromAddress)

        try c.encode(Self.encodeJSONArray(toAddresses), forKey: .toAddresses)
        try c.encode(Self.encodeJSONArray(ccAddresses), forKey: .ccAddresses)
        try c.encode(Self.encodeJSONArray(bccAddresses), forKey: .bccAddresses)
        try c.encode(Self.encodeJSONArray(replyToAddresses), forKey: .replyToAddresses)
        try c.encode(toSearch, forKey: .toSearch)
        try c.encode(ccSearch, forKey: .ccSearch)
        try c.encode(bccSearch, forKey: .bccSearch)
        try c.encodeIfPresent(listID, forKey: .listID)
        try c.encodeIfPresent(userAgent, forKey: .userAgent)

        try c.encode(date.timeIntervalSince1970, forKey: .date)
        try c.encode(preview, forKey: .preview)
        try c.encode(isRead, forKey: .isRead)
        try c.encode(isFlagged, forKey: .isFlagged)
        try c.encode(isAnswered, forKey: .isAnswered)
        try c.encode(isForwarded, forKey: .isForwarded)
        try c.encode(isDraft, forKey: .isDraft)

        try c.encode(size, forKey: .size)
        try c.encodeIfPresent(threadID, forKey: .threadID)
        try c.encode(interactionScore, forKey: .interactionScore)

        try c.encodeIfPresent(bodyText, forKey: .bodyText)
        try c.encodeIfPresent(bodyHTML, forKey: .bodyHTML)
        try c.encode(downloadState, forKey: .downloadState)
        try c.encode(isEncrypted, forKey: .isEncrypted)
        try c.encode(hasAttachments, forKey: .hasAttachments)

        try c.encode(folderID, forKey: .folderID)
        try c.encode(accountID, forKey: .accountID)
    }

    private static func decodeJSONArray(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> [String] {
        let raw = try container.decode(String.self, forKey: key)
        guard let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func encodeJSONArray(_ value: [String]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
