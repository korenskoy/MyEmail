//
//  RecipientHistory.swift
//  MyEmail
//
//  GRDB record для `recipient_history`. Используется в autocomplete для
//  `ComposeView.RecipientField` (ранжирование по `useCount` + recency).
//

import Foundation
import GRDB

struct RecipientHistory: Identifiable, Codable, Hashable, Sendable,
                         FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "recipient_history"

    var id: UUID
    var email: String
    var name: String?
    var useCount: Int
    var lastUsed: Date

    init(id: UUID, email: String, name: String?, useCount: Int, lastUsed: Date) {
        self.id = id; self.email = email; self.name = name
        self.useCount = useCount; self.lastUsed = lastUsed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
        case useCount = "use_count"
        case lastUsed = "last_used"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.email = try c.decode(String.self, forKey: .email)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.useCount = try c.decode(Int.self, forKey: .useCount)
        let ts = try c.decode(Double.self, forKey: .lastUsed)
        self.lastUsed = Date(timeIntervalSince1970: ts)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(email, forKey: .email)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(useCount, forKey: .useCount)
        try c.encode(lastUsed.timeIntervalSince1970, forKey: .lastUsed)
    }
}
