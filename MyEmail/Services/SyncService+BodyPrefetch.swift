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

        LogService.log(.info, .sync, "Prefetch start",
                       detail: "folder=\(folderID) count=\(candidateIDs.count)")

        var fetched = 0
        var skipped = 0
        var consecutiveFailures = 0
        for messageID in candidateIDs {
            if Task.isCancelled {
                LogService.log(.debug, .sync, "Prefetch cancelled",
                               detail: "fetched=\(fetched) remaining=\(candidateIDs.count - fetched - skipped)")
                return
            }

            // Yield once between iterations so a click for another message can
            // claim the command-socket tail before we enqueue the next UID.
            await Task.yield()

            // `loadFullMessage` may swallow auth/transport errors and return
            // the unchanged message (downloadState != .full). Detect that via
            // post-condition rather than relying on a thrown error.
            let result: Message?
            do {
                result = try await loadFullMessage(id: messageID)
            } catch {
                if SyncService.isAuthError(error) {
                    LogService.log(.warning, .sync, "Prefetch aborted (auth error)",
                                   detail: "fetched=\(fetched) folder=\(folderID)")
                    return
                }
                skipped += 1
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    LogService.log(.warning, .sync, "Prefetch aborted (3 consecutive failures)",
                                   detail: "fetched=\(fetched) folder=\(folderID)")
                    return
                }
                LogService.log(.debug, .sync, "Prefetch skip",
                               detail: "id=\(messageID) error=\(error)")
                continue
            }
            if result?.downloadState == .full {
                fetched += 1
                consecutiveFailures = 0
            } else {
                skipped += 1
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    LogService.log(.warning, .sync,
                                   "Prefetch aborted (3 consecutive non-full results)",
                                   detail: "fetched=\(fetched) folder=\(folderID)")
                    return
                }
            }
        }

        LogService.log(.info, .sync, "Prefetch done",
                       detail: "folder=\(folderID) fetched=\(fetched) skipped=\(skipped)")
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
