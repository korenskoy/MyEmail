//
//  Folder.swift
//  MyEmail
//
//  GRDB value-type record для `folders` table.
//

import Foundation
import GRDB

struct Folder: Identifiable, Codable, Hashable, Sendable,
               FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "folders"

    var id: UUID
    var accountID: UUID
    var path: String
    var name: String

    /// IMAP UTF-7 → Unicode (см. §6.9, `IMAPUTF7.decode`). Заполняется в sync,
    /// используется напрямую в UI.
    var displayName: String

    var separator: String
    var specialUse: SpecialUse?
    var subscribed: Bool

    var uidValidity: UInt32?
    var uidNext: UInt32?

    /// CONDSTORE: highest MODSEQ seen via STATUS (or FETCH). When the server
    /// reports the same value, we can skip incremental sync entirely.
    var highestModSequence: Int?

    /// Thunderbird §7: how many recent messages to sync/display.
    /// Grows when user scrolls to "load more".
    var visibleLimit: Int

    /// Thunderbird §7.4: whether older messages exist beyond the visible window.
    var moreMessages: MoreMessages

    /// Highest UID seen in this folder — used for new-message notifications.
    var highestKnownUid: UInt32?

    var totalCount: Int
    var unreadCount: Int

    /// True for Sent and Drafts folders — used for From↔To column auto-switch (§4.4).
    var isSentOrDrafts: Bool {
        specialUse == .sent || specialUse == .drafts
    }

    /// Localized name for special-use folders; raw displayName for custom folders.
    var localizedName: String {
        guard let specialUse else { return displayName }
        return switch specialUse {
        case .inbox:   String(localized: "Inbox")
        case .sent:    String(localized: "Sent")
        case .drafts:  String(localized: "Drafts")
        case .trash:   String(localized: "Trash")
        case .junk:    String(localized: "Junk")
        case .archive: String(localized: "Archive")
        case .all:     String(localized: "All Mail")
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case path
        case name
        case displayName = "display_name"
        case separator
        case specialUse = "special_use"
        case subscribed
        case uidValidity = "uid_validity"
        case uidNext = "uid_next"
        case highestModSequence = "highest_mod_sequence"
        case visibleLimit = "visible_limit"
        case moreMessages = "more_messages"
        case highestKnownUid = "highest_known_uid"
        case totalCount = "total_count"
        case unreadCount = "unread_count"
    }
}
