//
//  Account.swift
//  MyEmail
//
//  GRDB value-type record для `accounts` table. Value struct, Sendable —
//  пересекает actor boundaries по значению (см. hard rule 2: через actor
//  boundaries — UUID, не object reference; refetch по id перед критичными
//  операциями).
//

import Foundation
import GRDB

struct Account: Identifiable, Codable, Hashable, Sendable,
                FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "accounts"

    var id: UUID
    var name: String
    var senderName: String?
    var email: String

    // IMAP
    var imapHost: String
    var imapPort: Int
    var imapSecurity: ConnectionSecurity

    // SMTP
    var smtpHost: String
    var smtpPort: Int
    var smtpSecurity: ConnectionSecurity

    var authType: AuthType
    var authState: AuthState
    var isEnabled: Bool
    var sortOrder: Int

    // Folder mapping (по SPECIAL-USE) — см. §9.11
    var sentFolderPath: String?
    var draftsFolderPath: String?
    var trashFolderPath: String?
    var junkFolderPath: String?
    var archiveRootPath: String?
    var archiveSubdivision: ArchiveSubdivision

    /// 0 = unlimited; см. §6.5.
    var smtpMaxAttachmentSizeMB: Int

    // MARK: - Codable column mapping

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case senderName = "sender_name"
        case email
        case imapHost = "imap_host"
        case imapPort = "imap_port"
        case imapSecurity = "imap_security"
        case smtpHost = "smtp_host"
        case smtpPort = "smtp_port"
        case smtpSecurity = "smtp_security"
        case authType = "auth_type"
        case authState = "auth_state"
        case isEnabled = "is_enabled"
        case sortOrder = "sort_order"
        case sentFolderPath = "sent_folder_path"
        case draftsFolderPath = "drafts_folder_path"
        case trashFolderPath = "trash_folder_path"
        case junkFolderPath = "junk_folder_path"
        case archiveRootPath = "archive_root_path"
        case archiveSubdivision = "archive_subdivision"
        case smtpMaxAttachmentSizeMB = "smtp_max_attachment_size_mb"
    }
}
