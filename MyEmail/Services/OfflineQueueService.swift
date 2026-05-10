//
//  OfflineQueueService.swift
//  MyEmail
//
//  Persistent offline queue backed by GRDB `pending_actions` table.
//  Drain: FIFO by created_at, max 5 retries, freeze .needsReauth accounts.
//

import Foundation
import GRDB
import Observation

@Observable
@MainActor
final class OfflineQueueService {
    private let pool: DatabasePool

    private(set) var pendingCount: Int = 0
    private(set) var failedCount: Int = 0
    private(set) var isDraining = false

    init(pool: DatabasePool = DatabaseService.shared.pool) {
        self.pool = pool
        Task { await refreshCounts() }
    }

    // MARK: - Enqueue

    func enqueue(_ action: PendingAction) async throws {
        try await pool.write { db in
            var mutable = action
            try mutable.insert(db)
        }
        await refreshCounts()
        LogService.log(.info, .sync, "Enqueued \(action.type.rawValue)", detail: "uid=\(action.messageUID ?? 0)")
    }

    // MARK: - Drain

    /// Process all pending actions. Called on reconnect (NWPathMonitor).
    /// Returns number of actions attempted (success + failure) — caller uses
    /// this to skip a redundant post-drain refresh when the queue was empty.
    @discardableResult
    func drain(using executor: @escaping (PendingAction) async throws -> Void) async -> Int {
        guard !isDraining else { return 0 }
        isDraining = true
        defer { isDraining = false }
        var processed = 0

        // Accounts in needsReauth — freeze their actions
        let frozenAccountIDs: Set<UUID> = (try? await pool.read { db in
            let ids = try Account
                .filter(Column("auth_state") == AuthState.needsReauth.rawValue)
                .select(Column("id"))
                .asRequest(of: UUID.self)
                .fetchAll(db)
            return Set(ids)
        }) ?? []

        while true {
            // Fetch next pending action (FIFO)
            let next: PendingAction? = try? await pool.read { db in
                try PendingAction
                    .filter(Column("status") == PendingActionStatus.pending.rawValue)
                    .order(Column("created_at").asc)
                    .fetchOne(db)
            }

            guard var action = next else { break }

            // Skip frozen accounts
            if frozenAccountIDs.contains(action.accountID) { continue }

            // Mark running
            action.status = .running
            try? await pool.write { db in
                try db.execute(sql: "UPDATE pending_actions SET status = 'running' WHERE id = ?",
                               arguments: [action.id])
            }

            processed += 1
            do {
                try await executor(action)
                // Success — remove from queue
                try? await pool.write { db in
                    _ = try PendingAction.deleteOne(db, key: action.id)
                }
            } catch {
                // Failure — increment retry, mark failed if exhausted
                action.attemptCount += 1
                let newStatus: PendingActionStatus = action.attemptCount >= 5 ? .failed : .pending
                try? await pool.write { db in
                    try db.execute(sql: """
                        UPDATE pending_actions SET status = ?, attempt_count = ?, last_error = ?
                        WHERE id = ?
                        """, arguments: [newStatus.rawValue, action.attemptCount, "\(error)", action.id])
                }
                if newStatus == .failed {
                    LogService.log(.error, .sync, "Action failed permanently: \(action.type.rawValue)",
                                   detail: "\(error)")
                }
            }

            await refreshCounts()
        }

        await refreshCounts()
        return processed
    }

    // MARK: - Failed actions management

    /// Reset all `.failed` rows to `.pending` (attempt_count = 0) so the next
    /// drain re-attempts them. Caller is responsible for triggering the drain.
    func retryFailed() async {
        try? await pool.write { db in
            try db.execute(sql: """
                UPDATE pending_actions
                SET status = 'pending', attempt_count = 0, last_error = NULL
                WHERE status = 'failed'
                """)
        }
        await refreshCounts()
        LogService.log(.info, .sync, "Reset failed actions to pending")
    }

    /// Permanently delete all `.failed` rows from the queue.
    func discardFailed() async {
        let removed = (try? await pool.write { db -> Int in
            try db.execute(sql: "DELETE FROM pending_actions WHERE status = 'failed'")
            return db.changesCount
        }) ?? 0
        await refreshCounts()
        LogService.log(.info, .sync, "Discarded \(removed) failed actions")
    }

    // MARK: - Counts

    private func refreshCounts() async {
        let counts = try? await pool.read { db -> (Int, Int) in
            let pending = try PendingAction
                .filter(Column("status") == PendingActionStatus.pending.rawValue)
                .fetchCount(db)
            let failed = try PendingAction
                .filter(Column("status") == PendingActionStatus.failed.rawValue)
                .fetchCount(db)
            return (pending, failed)
        }
        pendingCount = counts?.0 ?? 0
        failedCount = counts?.1 ?? 0
    }
}
