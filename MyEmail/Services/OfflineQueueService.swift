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

        // Recover orphaned `running` rows from a prior interrupted drain.
        // Replay is idempotent per-UID, so re-attempting is safe.
        try? await pool.write { db in
            try db.execute(sql: "UPDATE pending_actions SET status = 'pending' WHERE status = 'running'")
        }

        // Accounts in needsReauth — freeze their actions (exclude in SQL).
        let frozenAccountIDs: [UUID] = (try? await pool.read { db in
            try Account
                .filter(Column("auth_state") == AuthState.needsReauth.rawValue)
                .select(Column("id"))
                .asRequest(of: UUID.self)
                .fetchAll(db)
        }) ?? []

        // Forward-only cursor by created_at. Each action — success or failure —
        // advances past it, so the loop always terminates and a failed action is
        // skipped until the next drain (no instant retry burn, no infinite
        // re-read of a frozen-account row). `seenAtCursor` dedups rows sharing
        // the same timestamp (bulk-enqueue makes near-identical Date()s); it is
        // reset whenever the cursor moves to a strictly larger timestamp, so it
        // stays small even with 10k queued actions.
        var cursorCreatedAt: Double = -1
        var seenAtCursor: Set<UUID> = []

        while true {
            // Fetch next pending action at-or-after the cursor, excluding frozen
            // accounts and already-seen rows directly in SQL.
            let next: PendingAction? = try? await pool.read { db in
                var sql = """
                    SELECT * FROM pending_actions
                    WHERE status = 'pending' AND created_at >= ?
                    """
                var args: [DatabaseValueConvertible] = [cursorCreatedAt]
                if !frozenAccountIDs.isEmpty {
                    let ph = frozenAccountIDs.map { _ in "?" }.joined(separator: ", ")
                    sql += " AND account_id NOT IN (\(ph))"
                    args.append(contentsOf: frozenAccountIDs.map { $0 as DatabaseValueConvertible })
                }
                if !seenAtCursor.isEmpty {
                    let ph = seenAtCursor.map { _ in "?" }.joined(separator: ", ")
                    sql += " AND id NOT IN (\(ph))"
                    args.append(contentsOf: seenAtCursor.map { $0 as DatabaseValueConvertible })
                }
                sql += " ORDER BY created_at ASC, id ASC LIMIT 1"
                return try PendingAction.fetchOne(db, sql: sql, arguments: StatementArguments(args))
            }

            guard var action = next else { break }

            // Advance cursor; reset the dedup set when the timestamp grows.
            let at = action.createdAt.timeIntervalSince1970
            if at > cursorCreatedAt {
                cursorCreatedAt = at
                seenAtCursor.removeAll(keepingCapacity: true)
            }
            seenAtCursor.insert(action.id)

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
                // Failure — increment retry, mark failed if exhausted, otherwise
                // back to pending. Cursor already advanced, so this row is not
                // re-read in the current drain (backoff = next drain).
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
