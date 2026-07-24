//
//  SyncService+BodyPrefetch.swift
//  MyEmail
//
//  Background message body prefetch (Thunderbird AutoSync parity).
//  After folder selection / sync / IDLE EXISTS, asynchronously download
//  bodies for the top N recent uncached messages so user clicks hit the
//  GRDB cache instead of an IMAP round-trip.
//
//  Scope: only the currently-selected folder OR any INBOX.
//
//  Coordination with foreground clicks: prefetch acquires the command-socket
//  lock (`runCommandSerializedPerAccount`) one batch at a time and releases it
//  between batches. A foreground click (loadFullMessage) queues right behind
//  the in-flight batch — not the whole run — so worst-case click latency is one
//  batch (≤10 messages), not the full ≤30-message prefetch set.
//

import Foundation
import GRDB

extension SyncService {

    // MARK: - Settings (read directly from UserDefaults; UI uses @AppStorage with same keys)

    private var prefetchEnabled: Bool {
        // Default true — UserDefaults returns false when key absent, so use
        // `object(forKey:)` to distinguish "unset" from "explicitly false".
        if let v = UserDefaults.standard.object(forKey: "bodyPrefetchEnabled") as? Bool {
            return v
        }
        return true
    }

    private var prefetchMaxCount: Int {
        let v = UserDefaults.standard.integer(forKey: "bodyPrefetchMaxCount")
        return v > 0 ? v : 30
    }

    /// Max message size in bytes. 0 = unlimited.
    private var prefetchMaxSizeBytes: Int {
        let kb = UserDefaults.standard.object(forKey: "bodyPrefetchMaxSizeKB") as? Int ?? 1024
        return kb <= 0 ? 0 : kb * 1024
    }

    // MARK: - Entry points

    /// Schedule prefetch for a folder.
    ///
    /// - `replace = true` (folder selection): cancel any in-flight prefetch
    ///   for this folder and start fresh. User just opened the folder — they
    ///   want immediate warming.
    /// - `replace = false` (IDLE / post-sync top-up): if a task is already
    ///   running and not cancelled, leave it alone. Avoids cancel-restart
    ///   churn on noisy mailboxes that fire EXISTS frequently.
    func schedulePrefetch(folderID: UUID, replace: Bool = true) {
        guard prefetchEnabled else {
            LogService.log(.debug, .sync, "Prefetch disabled in settings", detail: "\(folderID)")
            return
        }
        guard isOnline else {
            LogService.log(.debug, .sync, "Prefetch skipped (offline)", detail: "\(folderID)")
            return
        }

        if !replace, let existing = prefetchTasks[folderID], !existing.isCancelled {
            LogService.log(.debug, .sync, "Prefetch already in flight", detail: "\(folderID)")
            return
        }

        // Cancel previous task for this folder (folder-switch path)
        prefetchTasks[folderID]?.cancel()
        prefetchTasks[folderID] = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPrefetchLoop(folderID: folderID)
            // Self-cleanup: only clear if we still own this slot. A subsequent
            // schedulePrefetch may have replaced us already.
            if self.prefetchTasks[folderID]?.isCancelled ?? true {
                self.prefetchTasks[folderID] = nil
            }
        }
        prefetchTasks[folderID] = task
    }

    func cancelPrefetch(folderID: UUID) {
        prefetchTasks[folderID]?.cancel()
        prefetchTasks[folderID] = nil
    }

    func cancelAllPrefetch() {
        for (_, task) in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
    }

    // MARK: - Loop

    /// Batch size for pipelined raw-body fetches. Kept small (5) so the command
    /// socket is held only ~0.5-1s per batch and a foreground click preempts
    /// within one short batch instead of waiting a 10-message one (2-4s). The
    /// fetch itself is one pipelined round-trip regardless of size.
    private static let prefetchBatchSize = 5

    private func runPrefetchLoop(folderID: UUID) async {
        // Combined scope + auth gate: read folder.special_use AND account.auth_state
        // in a single query to avoid prefetch hammering on needsReauth accounts.
        let gate: PrefetchGate
        do {
            gate = try await loadPrefetchGate(folderID: folderID)
        } catch {
            LogService.log(.warning, .sync, "Prefetch gate query failed",
                           detail: "\(error)")
            return
        }

        if gate.authState == AuthState.needsReauth.rawValue {
            LogService.log(.debug, .sync, "Prefetch skipped (account needs re-auth)",
                           detail: "\(folderID)")
            return
        }

        let inScope = currentlySelectedFolderID == folderID || gate.specialUse == "inbox"
        guard inScope else {
            LogService.log(.debug, .sync, "Prefetch skipped (out of scope)",
                           detail: "\(folderID)")
            return
        }

        let candidateIDs: [UUID]
        do {
            candidateIDs = try await fetchPrefetchCandidates(folderID: folderID)
        } catch {
            LogService.log(.warning, .sync, "Prefetch candidate query failed",
                           detail: "\(error)")
            return
        }

        guard !candidateIDs.isEmpty else {
            LogService.log(.debug, .sync, "Prefetch: nothing to fetch (cache warm)",
                           detail: "\(folderID)")
            return
        }

        // One DB read pulls every (message, folder, account) tuple — avoids
        // N round-trips through `fetchMessageContext` in the inner loop.
        let candidates: [(msg: Message, folder: Folder, account: Account)]
        do {
            candidates = try await loadPrefetchContexts(messageIDs: candidateIDs)
        } catch {
            LogService.log(.warning, .sync, "Prefetch context query failed",
                           detail: "\(error)")
            return
        }
        guard let firstCandidate = candidates.first else { return }
        let folder = firstCandidate.folder
        let account = firstCandidate.account

        LogService.log(.info, .sync, "Prefetch start",
                       detail: "folder=\(folderID) count=\(candidates.count)")

        var fetched = 0
        var skipped = 0
        var consecutiveFailedBatches = 0
        let batchSize = Self.prefetchBatchSize

        batches: for batchStart in stride(from: 0, to: candidates.count, by: batchSize) {
            if Task.isCancelled {
                LogService.log(.debug, .sync, "Prefetch cancelled",
                               detail: "fetched=\(fetched) remaining=\(candidates.count - fetched - skipped)")
                break
            }
            let batchEnd = min(batchStart + batchSize, candidates.count)
            let batch = Array(candidates[batchStart..<batchEnd])

            // One batch = one command-lock acquisition. Releasing between
            // batches lets a foreground click (loadFullMessage) jump the FIFO
            // tail ahead of the next batch instead of waiting the whole run.
            let outcome: PrefetchBatchOutcome = (try? await runCommandSerializedPerAccount(account.id) { [weak self] in
                guard let self else { return .abort(skipped: batch.count) }
                return await self._prefetchOneBatchLocked(batch: batch, folder: folder, account: account)
            }) ?? .abort(skipped: batch.count)

            switch outcome {
            case .done(let f, let s):
                fetched += f
                skipped += s
                consecutiveFailedBatches = 0
            case .transientFailure(let s):
                skipped += s
                consecutiveFailedBatches += 1
                LogService.log(.debug, .sync, "Prefetch batch failed",
                               detail: "size=\(batch.count)")
                if consecutiveFailedBatches >= 3 {
                    LogService.log(.warning, .sync,
                                   "Prefetch aborted (3 consecutive batch failures)",
                                   detail: "fetched=\(fetched)")
                    break batches
                }
            case .abort(let s):
                skipped += s
                break batches
            }

            // Yield so a click queued during this batch runs before the next.
            await Task.yield()
        }

        LogService.log(.info, .sync, "Prefetch done",
                       detail: "folder=\(folderID) fetched=\(fetched) skipped=\(skipped)")
    }

    private enum PrefetchBatchOutcome {
        case done(fetched: Int, skipped: Int)
        case transientFailure(skipped: Int)  // recycle + retry-eligible (counts toward 3-strike abort)
        case abort(skipped: Int)             // auth / connect failure — stop the whole prefetch
    }

    /// Fetch + persist one batch under the per-account command lock. Connect /
    /// select run here (not once per prefetch) so the lock is held only for the
    /// batch; both are cheap no-ops when the command socket is already warm.
    private func _prefetchOneBatchLocked(
        batch: [(msg: Message, folder: Folder, account: Account)],
        folder: Folder, account: Account
    ) async -> PrefetchBatchOutcome {
        let imap = getOrCreateCommandIMAPService(for: account)
        await wireTokenProvider(for: account, imap: imap)

        do {
            if await !imap.isConnected { try await imap.connect() }
            try await imap.ensureFolderSelected(folder.path)
        } catch {
            if SyncService.isAuthError(error), account.authType == .oauth2 {
                markNeedsReauth(accountID: account.id, reason: "prefetch auth failure")
            }
            LogService.log(.warning, .sync, "Prefetch connect/select failed",
                           detail: "\(error)")
            return .abort(skipped: batch.count)
        }

        // A click is already waiting — hand the socket over before the
        // (non-preemptible) pipelined fetch. Leftovers warm on the next trigger.
        if foregroundOpenPending > 0 {
            return .done(fetched: 0, skipped: batch.count)
        }

        let uids = batch.map(\.msg.uid)
        let rawByUID: [UInt32: Data]
        do {
            rawByUID = try await imap.fetchRawMessages(uids: uids)
        } catch {
            if SyncService.isAuthError(error) {
                LogService.log(.warning, .sync, "Prefetch aborted (auth error)", detail: "")
                return .abort(skipped: batch.count)
            }
            await recycleConnectionIfDesynced(error, imap: imap)
            return .transientFailure(skipped: batch.count)
        }

        var fetched = 0
        var skipped = 0
        for (i, candidate) in batch.enumerated() {
            // Yield the socket the moment a click queues up — the remaining
            // bodies warm on the next prefetch trigger. This bounds click
            // latency to the in-flight message, not the whole batch.
            if foregroundOpenPending > 0 {
                skipped += batch.count - i
                LogService.log(.debug, .sync, "Prefetch yielded to foreground open",
                               detail: "persisted=\(fetched) yielded=\(batch.count - i)")
                break
            }
            guard let raw = rawByUID[candidate.msg.uid] else {
                skipped += 1
                continue
            }
            do {
                let persisted = try await persistFullMessageBody(
                    rawData: raw, msg: candidate.msg, account: account
                )
                if persisted.downloadState == .full {
                    fetched += 1
                } else {
                    skipped += 1
                }
            } catch {
                skipped += 1
                LogService.log(.debug, .sync, "Prefetch persist failed",
                               detail: "id=\(candidate.msg.id) error=\(error)")
            }
        }
        return .done(fetched: fetched, skipped: skipped)
    }

    /// Single GRDB read pulling msg + folder + account for every candidate.
    /// All candidates are guaranteed to share the same folder (caller filters
    /// by folder_id), so we look up folder/account once and zip against msgs.
    private func loadPrefetchContexts(
        messageIDs: [UUID]
    ) async throws -> [(msg: Message, folder: Folder, account: Account)] {
        guard !messageIDs.isEmpty else { return [] }
        return try await pool.read { db -> [(Message, Folder, Account)] in
            let messages = try Message
                .filter(messageIDs.contains(Column("id")))
                .fetchAll(db)
            // Preserve caller's date-DESC ordering.
            let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
            let ordered = messageIDs.compactMap { byID[$0] }
            guard let head = ordered.first,
                  let folder = try Folder.fetchOne(db, key: head.folderID),
                  let account = try Account.fetchOne(db, key: head.accountID)
            else { return [] }
            return ordered.map { ($0, folder, account) }
        }
    }

    // MARK: - Scope + auth gate

    private struct PrefetchGate {
        let specialUse: String?
        let authState: String
    }

    /// Read folder.special_use + account.auth_state in one query.
    private func loadPrefetchGate(folderID: UUID) async throws -> PrefetchGate {
        try await pool.read { db -> PrefetchGate in
            let row = try Row.fetchOne(db, sql: """
                SELECT f.special_use AS special_use, a.auth_state AS auth_state
                FROM folders f
                JOIN accounts a ON a.id = f.account_id
                WHERE f.id = ?
                """, arguments: [folderID])
            return PrefetchGate(
                specialUse: row?["special_use"] as String?,
                authState: (row?["auth_state"] as String?) ?? AuthState.ok.rawValue
            )
        }
    }

    // MARK: - Candidates

    private func fetchPrefetchCandidates(folderID: UUID) async throws -> [UUID] {
        let limit = prefetchMaxCount
        let maxSize = prefetchMaxSizeBytes

        return try await pool.read { db -> [UUID] in
            var sql = """
            SELECT id FROM messages
            WHERE folder_id = ?
              AND uid > 0
              AND download_state != 'full'
            """
            var args: [DatabaseValueConvertible] = [folderID]

            if maxSize > 0 {
                sql += " AND size <= ?"
                args.append(maxSize)
            }

            sql += " ORDER BY date DESC LIMIT ?"
            args.append(limit)

            return try UUID.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }
}
