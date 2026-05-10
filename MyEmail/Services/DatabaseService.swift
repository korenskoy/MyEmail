//
//  DatabaseService.swift
//  MyEmail
//
//  GRDB `DatabasePool` wrapper. Sendable, не MainActor-isolated — так
//  `IMAPService`/`SMTPService` actor'ы могут дернуть `.shared.pool` напрямую
//  без actor hops (см. §5.5). `DatabasePool` thread-safe и Sendable.
//
//  Schema — single canonical CREATE in `DatabaseService+Schema.swift`. No
//  DatabaseMigrator (single-user app — old DB is wiped on upgrade).
//

import Foundation
import GRDB

/// Lifetime: singleton. Конструируется при первом обращении из `AppEnvironment`.
/// Все поля `let` → структурно Sendable.
final class DatabaseService: Sendable {
    static let shared = DatabaseService()

    let pool: DatabasePool
    let databaseURL: URL

    /// Marker stored in UserDefaults — bumped when DB shape changes
    /// to trigger a one-shot wipe of the legacy db.sqlite + attachments.
    private static let wipeMarkerKey = "MyEmail.SchemaWipeVersion"
    private static let currentWipeVersion = 5  // v1.4: FTS5 tokenizer remove_diacritics=2 (ё→е, ü→u)

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let dir = appSupport.appendingPathComponent("MyEmail", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        let url = dir.appendingPathComponent("db.sqlite")
        self.databaseURL = url

        Self.wipeLegacyDataIfNeeded(databaseURL: url, attachmentsRoot: dir.appendingPathComponent("attachments"))

        do {
            var config = Configuration()
            config.qos = .userInitiated

            self.pool = try DatabasePool(path: url.path, configuration: config)
            try Self.createSchema(on: pool)
            try Self.backfillThreadIDsIfNeeded(on: pool)

            LogService.log(
                .info,
                .db,
                "DatabasePool opened",
                detail: url.path
            )
        } catch {
            LogService.log(
                .error,
                .db,
                "Failed to open DatabasePool",
                detail: "\(error)"
            )
            fatalError("DatabasePool open failed: \(error)")
        }
    }

    /// One-shot wipe of legacy DB + attachments when `currentWipeVersion`
    /// advances. Idempotent — runs only once per version bump.
    private static func wipeLegacyDataIfNeeded(databaseURL: URL, attachmentsRoot: URL) {
        let stored = UserDefaults.standard.integer(forKey: wipeMarkerKey)
        guard stored < currentWipeVersion else { return }

        let fm = FileManager.default
        // Remove SQLite + WAL/SHM sidecars. Tolerate missing files.
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
        if fm.fileExists(atPath: attachmentsRoot.path) {
            try? fm.removeItem(at: attachmentsRoot)
        }

        UserDefaults.standard.set(currentWipeVersion, forKey: wipeMarkerKey)
        LogService.log(.info, .db, "Wiped legacy DB and attachments for schema v\(currentWipeVersion)")
    }

    /// One-shot backfill of persistent `thread_id` for rows predating P2-T2.
    /// Idempotent: guarded by UserDefaults marker, UPDATEs only WHERE thread_id IS NULL.
    /// Does NOT wipe data; new INSERTs populate thread_id going forward.
    private static let threadIDBackfillKey = "MyEmail.ThreadIDBackfillV1"

    private static func backfillThreadIDsIfNeeded(on pool: DatabasePool) throws {
        guard !UserDefaults.standard.bool(forKey: threadIDBackfillKey) else { return }

        try pool.write { db in
            // Step A: inherit from parent by In-Reply-To (prefer parent.thread_id,
            // fall back to parent.message_id so future children join this root).
            try db.execute(sql: """
                UPDATE messages
                SET thread_id = (
                    SELECT COALESCE(p.thread_id, p.message_id)
                    FROM messages p
                    WHERE p.message_id = messages.in_reply_to
                      AND p.account_id = messages.account_id
                    LIMIT 1
                )
                WHERE thread_id IS NULL AND in_reply_to IS NOT NULL
            """)
            // Step B: remaining rows — use own message_id as thread root.
            try db.execute(sql: """
                UPDATE messages
                SET thread_id = message_id
                WHERE thread_id IS NULL AND message_id IS NOT NULL
            """)
        }

        UserDefaults.standard.set(true, forKey: threadIDBackfillKey)
        LogService.log(.info, .db, "Backfilled persistent thread_id (P2-T2)")
    }
}
