//
//  TrustedSender.swift
//  MyEmail
//
//  GRDB record для `trusted_senders`. Используется в image-loading policy
//  (см. §6.7): если sender в trusted списке — remote images показываются
//  автоматически, иначе — баннер "Show remote images".
//

import Foundation
import GRDB

struct TrustedSender: Identifiable, Codable, Hashable, Sendable,
                      FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "trusted_senders"

    var id: UUID
    var email: String
    var createdAt: Date

    init(id: UUID, email: String, createdAt: Date) {
        self.id = id; self.email = email; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.email = try c.decode(String.self, forKey: .email)
        let ts = try c.decode(Double.self, forKey: .createdAt)
        self.createdAt = Date(timeIntervalSince1970: ts)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(email, forKey: .email)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
    }
}
