//
//  PendingAction.swift
//  MyEmail
//
//  GRDB record для `pending_actions` table. Очередь off-line операций
//  переживает рестарт приложения (§5.5, §6.4, §9.2 bug recipe).
//
//  `payload` — сериализованный `ComposedMessage` для `send`/`saveDraft`.
//  Используется `JSONEncoder`, кладётся в BLOB column.
//

import Foundation
import GRDB

struct PendingAction: Identifiable, Codable, Hashable, Sendable,
                      FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pending_actions"

    var id: UUID
    var type: PendingActionType
    var accountID: UUID
    var sourceFolderPath: String?
    var targetFolderPath: String?
    var messageUID: UInt32?

    /// UIDVALIDITY of source folder at enqueue time (RFC 3501 §2.3.1.1).
    /// Checked before replay — stale actions are discarded.
    var sourceUidValidity: UInt32?

    /// Сериализованный `ComposedMessage` для send/saveDraft. Для остальных
    /// action types — nil.
    var payload: Data?

    var status: PendingActionStatus
    var attemptCount: Int
    var lastError: String?
    var createdAt: Date

    init(
        id: UUID, type: PendingActionType, accountID: UUID,
        sourceFolderPath: String?, targetFolderPath: String?,
        messageUID: UInt32?, sourceUidValidity: UInt32? = nil,
        payload: Data?,
        status: PendingActionStatus, attemptCount: Int,
        lastError: String?, createdAt: Date
    ) {
        self.id = id; self.type = type; self.accountID = accountID
        self.sourceFolderPath = sourceFolderPath
        self.targetFolderPath = targetFolderPath
        self.messageUID = messageUID
        self.sourceUidValidity = sourceUidValidity
        self.payload = payload
        self.status = status; self.attemptCount = attemptCount
        self.lastError = lastError; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case accountID = "account_id"
        case sourceFolderPath = "source_folder_path"
        case targetFolderPath = "target_folder_path"
        case messageUID = "message_uid"
        case sourceUidValidity = "source_uid_validity"
        case payload
        case status
        case attemptCount = "attempt_count"
        case lastError = "last_error"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.type = try c.decode(PendingActionType.self, forKey: .type)
        self.accountID = try c.decode(UUID.self, forKey: .accountID)
        self.sourceFolderPath = try c.decodeIfPresent(String.self, forKey: .sourceFolderPath)
        self.targetFolderPath = try c.decodeIfPresent(String.self, forKey: .targetFolderPath)
        self.messageUID = try c.decodeIfPresent(UInt32.self, forKey: .messageUID)
        self.sourceUidValidity = try c.decodeIfPresent(UInt32.self, forKey: .sourceUidValidity)
        self.payload = try c.decodeIfPresent(Data.self, forKey: .payload)
        self.status = try c.decode(PendingActionStatus.self, forKey: .status)
        self.attemptCount = try c.decode(Int.self, forKey: .attemptCount)
        self.lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        let ts = try c.decode(Double.self, forKey: .createdAt)
        self.createdAt = Date(timeIntervalSince1970: ts)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(accountID, forKey: .accountID)
        try c.encodeIfPresent(sourceFolderPath, forKey: .sourceFolderPath)
        try c.encodeIfPresent(targetFolderPath, forKey: .targetFolderPath)
        try c.encodeIfPresent(messageUID, forKey: .messageUID)
        try c.encodeIfPresent(sourceUidValidity, forKey: .sourceUidValidity)
        try c.encodeIfPresent(payload, forKey: .payload)
        try c.encode(status, forKey: .status)
        try c.encode(attemptCount, forKey: .attemptCount)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
    }
}
