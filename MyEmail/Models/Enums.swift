//
//  Enums.swift
//  MyEmail
//
//  Shared enum types. Все конформят `DatabaseValueConvertible` через String
//  rawValue (см. §5.3 требований) — это делает `DatabaseService+Schema` и
//  GRDB Record types прозрачными: enum поля сериализуются/десериализуются
//  автоматически.
//
//  ВАЖНО: все enum здесь — `Sendable` и не требуют изоляции. Они используются
//  и с MainActor (AppState, Views), и из actor-изолированных сервисов
//  (IMAPService, SMTPService) — без hops.
//

import Foundation
import GRDB

// MARK: - ConnectionSecurity

enum ConnectionSecurity: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case starttls
    case ssl
}

extension ConnectionSecurity: DatabaseValueConvertible {}

// MARK: - AuthType

enum AuthType: String, Codable, Hashable, Sendable, CaseIterable {
    case oauth2
    case plain
}

extension AuthType: DatabaseValueConvertible {}

// MARK: - AuthState

/// Per-account auth health. `needsReauth` означает что refresh-токен умер
/// (Gmail `invalid_grant`, см. §6.1), и UI показывает баннер с кнопкой
/// повторного логина.
enum AuthState: String, Codable, Hashable, Sendable, CaseIterable {
    case ok
    case needsReauth
}

extension AuthState: DatabaseValueConvertible {}

// MARK: - SpecialUse

/// RFC 6154 SPECIAL-USE flags. Folder mapping (`sentFolderPath` etc) определяется
/// ТОЛЬКО через specialUse, не по имени (см. §9.11 bug recipe).
enum SpecialUse: String, Codable, Hashable, Sendable, CaseIterable {
    case inbox
    case sent
    case drafts
    case trash
    case junk
    case archive
    case all        // Gmail `\All Mail` — скрывается из sidebar (см. §9.11)
}

extension SpecialUse: DatabaseValueConvertible {}

// MARK: - ArchiveSubdivision

/// Куда класть письмо при Archive-операции. `byMonthThunderbird` создаёт
/// `Archive/2026/2026-04` subfolders (default, совместимо с Thunderbird).
enum ArchiveSubdivision: String, Codable, Hashable, Sendable, CaseIterable {
    case flat                    // Archive/
    case byYear                  // Archive/2026/
    case byMonthThunderbird      // Archive/2026/2026-04/
}

extension ArchiveSubdivision: DatabaseValueConvertible {}

extension ArchiveSubdivision {
    /// Compute target IMAP folder path for archiving a message with given date.
    nonisolated func targetPath(for date: Date, root: String, separator: String = "/") -> String {
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: date)
        let month = cal.component(.month, from: date)

        switch self {
        case .flat:
            return root
        case .byYear:
            return "\(root)\(separator)\(year)"
        case .byMonthThunderbird:
            let monthStr = String(format: "%04d-%02d", year, month)
            return "\(root)\(separator)\(year)\(separator)\(monthStr)"
        }
    }
}

// MARK: - MoreMessages (Thunderbird §7.4)

/// Persistent pagination state per folder — tracks whether older messages
/// exist beyond the current visible window.
enum MoreMessages: String, Codable, Hashable, Sendable, CaseIterable {
    case unknown
    case `true`
    case `false`
}

extension MoreMessages: DatabaseValueConvertible {}

// MARK: - DownloadState (Thunderbird §6.3)

/// How much of a message has been downloaded from the server.
enum DownloadState: String, Codable, Hashable, Sendable, CaseIterable {
    case envelope   // Headers only
    case full       // Complete body + attachments metadata
}

extension DownloadState: DatabaseValueConvertible {}

// MARK: - PendingAction types

/// Тип отложенной операции в `pending_actions` table. Используется для offline
/// queue (см. §6.4, §9.2).
enum PendingActionType: String, Codable, Hashable, Sendable, CaseIterable {
    case markRead
    case markUnread
    case flag
    case unflag
    case move
    case delete
    case send
    case saveDraft
    case deleteDraft
    case archive
    case appendToSent
    case markJunk
}

extension PendingActionType: DatabaseValueConvertible {}

enum PendingActionStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case pending
    case running
    case failed
    case cancelled
}

extension PendingActionStatus: DatabaseValueConvertible {}
