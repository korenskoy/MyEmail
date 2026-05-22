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
//  Coordination with foreground clicks: prefetch submits one UID at a time
//  to the existing command-socket tail (`runCommandSerializedPerAccount`).
//  A click queues right behind the in-flight prefetch UID. Worst-case click
//  latency = one prefetch fetch (~200-500 ms for ≤1 MB messages).
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

    /// Batch size for pipelined raw-body fetches. Tuned for Gmail (~150 ms RTT):
    /// 10 messages per round-trip empties most inbox prefetch sets in 1-2 RTTs
    /// total instead of 10-30. Thunderbird's `nsImapProtocol::FetchMessage`
    /// uses a comma-list UID set in one command — same end effect.
    private static let prefetchBatchSize = 10

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

        let (fetched, skipped): (Int, Int) = (try? await runCommandSerializedPerAccount(account.id) { [weak self] in
            guard let self else { return (0, 0) }
            return await self._prefetchBatchedLocked(
                candidates: candidates, folder: folder, account: account
            )
        }) ?? (0, 0)

        LogService.log(.info, .sync, "Prefetch done",
                       detail: "folder=\(folderID) fetched=\(fetched) skipped=\(skipped)")
    }

    /// The batched fetch+persist body. Runs under the per-account command lock.
    /// Returns (fetched, skipped) counts.
    private func _prefetchBatchedLocked(
        candidates: [(msg: Message, folder: Folder, account: Account)],
        folder: Folder, account: Account
    ) async -> (Int, Int) {
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
            return (0, candidates.count)
        }

        var fetched = 0
        var skipped = 0
        var consecutiveFailedBatches = 0
        let batchSize = Self.prefetchBatchSize

        for batchStart in stride(from: 0, to: candidates.count, by: batchSize) {
            if Task.isCancelled {
                LogService.log(.debug, .sync, "Prefetch cancelled",
                               detail: "fetched=\(fetched) remaining=\(candidates.count - fetched - skipped)")
                return (fetched, skipped)
            }
            await Task.yield()

            let batchEnd = min(batchStart + batchSize, candidates.count)
            let batch = Array(candidates[batchStart..<batchEnd])
            let uids = batch.map(\.msg.uid)

            let rawByUID: [UInt32: Data]
            do {
                rawByUID = try await imap.fetchRawMessages(uids: uids)
            } catch {
                if SyncService.isAuthError(error) {
                    LogService.log(.warning, .sync, "Prefetch aborted (auth error)",
                                   detail: "fetched=\(fetched)")
                    return (fetched, skipped + batch.count)
                }
                await recycleConnectionIfDesynced(error, imap: imap)
                skipped += batch.count
                consecutiveFailedBatches += 1
                if consecutiveFailedBatches >= 3 {
                    LogService.log(.warning, .sync,
                                   "Prefetch aborted (3 consecutive batch failures)",
                                   detail: "fetched=\(fetched)")
                    return (fetched, skipped)
                }
                LogService.log(.debug, .sync, "Prefetch batch failed",
                               detail: "size=\(batch.count) error=\(error)")
                continue
            }
            consecutiveFailedBatches = 0

            for candidate in batch {
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
        }
        return (fetched, skipped)
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
