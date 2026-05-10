//
//  TrustedSenderService.swift
//  MyEmail
//
//  Trusted sender DB operations. Views access this instead of DatabaseService.shared.pool.
//

import Foundation
import GRDB

@MainActor
final class TrustedSenderService {
    private let pool: DatabasePool

    init(pool: DatabasePool = DatabaseService.shared.pool) {
        self.pool = pool
    }

    func isTrusted(_ email: String) -> Bool {
        (try? pool.read { db in
            try TrustedSender
                .filter(Column("email") == email.lowercased())
                .fetchCount(db) > 0
        }) ?? false
    }

    func addTrusted(_ email: String) {
        let normalized = email.lowercased()
        var sender = TrustedSender(id: UUID(), email: normalized, createdAt: Date())
        try? pool.write { db in try sender.insert(db) }
        LogService.log(.info, .sync, "Trusted sender added", detail: normalized)
    }

    func removeTrusted(_ senderID: UUID) {
        try? pool.write { db in
            try TrustedSender.filter(Column("id") == senderID).deleteAll(db)
        }
    }

    func allTrusted() -> [TrustedSender] {
        (try? pool.read { db in
            try TrustedSender.order(Column("email")).fetchAll(db)
        }) ?? []
    }
}
