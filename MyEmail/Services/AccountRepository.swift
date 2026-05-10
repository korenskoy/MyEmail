//
//  AccountRepository.swift
//  MyEmail
//
//  GRDB CRUD для `accounts` table. `Sendable` final class — вызывается и из
//  MainActor (Settings UI, ValueObservation), и из actor-изолированных
//  сервисов (`IMAPService`, `AuthService`). `DatabasePool` — thread-safe, нет
//  hop'ов.
//
//  **Удаление аккаунта** каскадно:
//    - GRDB (ON DELETE CASCADE) убирает folders/messages/attachments/etc
//    - Keychain entries (`deleteAllCredentials`) — тут же
//    - CacheService cleanup — в M3+ (attachments/{accountID}/)
//

import Foundation
import GRDB

final class AccountRepository: Sendable {
    let pool: DatabasePool
    let keychain: KeychainService

    init(
        pool: DatabasePool = DatabaseService.shared.pool,
        keychain: KeychainService = KeychainService.shared
    ) {
        self.pool = pool
        self.keychain = keychain
    }

    // MARK: - Read

    nonisolated func allEnabled() throws -> [Account] {
        try pool.read { db in
            try Account
                .filter(Column("is_enabled") == true)
                .order(Column("sort_order").asc, Column("name").asc)
                .fetchAll(db)
        }
    }

    nonisolated func all() throws -> [Account] {
        try pool.read { db in
            try Account
                .order(Column("sort_order").asc, Column("name").asc)
                .fetchAll(db)
        }
    }

    nonisolated func find(id: UUID) throws -> Account? {
        try pool.read { db in
            try Account.fetchOne(db, key: id)
        }
    }

    nonisolated func find(email: String) throws -> Account? {
        try pool.read { db in
            try Account
                .filter(Column("email") == email)
                .fetchOne(db)
        }
    }

    // MARK: - Write

    /// Insert-only. Для обновления — используй `update(_:)`.
    nonisolated func insert(_ account: Account) throws {
        try pool.write { db in
            var mutable = account
            try mutable.insert(db)
        }
        LogService.log(
            .info,
            .auth,
            "Inserted account \(account.email)",
            detail: account.id.uuidString
        )
    }

    nonisolated func update(_ account: Account) throws {
        try pool.write { db in
            try account.update(db)
        }
    }

    /// Bump `sort_order` so the new account is appended to the end.
    nonisolated func nextSortOrder() throws -> Int {
        try pool.read { db in
            let max = try Int.fetchOne(
                db,
                sql: "SELECT MAX(sort_order) FROM accounts"
            ) ?? -1
            return max + 1
        }
    }

    // MARK: - Delete

    /// Cascade delete: GRDB row (ON DELETE CASCADE) → Keychain → attachment files.
    nonisolated func delete(id: UUID) throws {
        try pool.write { db in
            _ = try Account.deleteOne(db, key: id)
        }
        try keychain.deleteAllCredentials(for: id)

        // Clean up attachment files for this account
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let accountDir = appSupport
                .appendingPathComponent("MyEmail/attachments/\(id.uuidString)", isDirectory: true)
            try? fm.removeItem(at: accountDir)
        }

        LogService.log(.info, .auth, "Deleted account", detail: id.uuidString)
    }

    // MARK: - Auth state

    /// Используется в `invalid_grant` path (§6.1). При ошибке refresh —
    /// `.needsReauth`, UI показывает баннер, offline queue замораживается.
    nonisolated func setAuthState(_ state: AuthState, for id: UUID) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE accounts SET auth_state = ? WHERE id = ?",
                arguments: [state.rawValue, id]
            )
        }
        LogService.log(
            .info,
            .auth,
            "Auth state → \(state.rawValue)",
            detail: id.uuidString
        )
    }
}
