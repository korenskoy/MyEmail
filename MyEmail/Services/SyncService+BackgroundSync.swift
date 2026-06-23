//
//  SyncService+BackgroundSync.swift
//  MyEmail
//
//  Paterns implementing industry-standard IMAP sync strategies:
//    #2 Background prefetch — one-time lazy sync of all folders after INBOX
//    #4 STATUS polling     — periodic cheap poll of all folders via STATUS
//
//  Multi-folder IDLE (#3) lives in SyncService+Connection.swift.
//

import Foundation
import GRDB
import SwiftMail

extension SyncService {

    // MARK: - Pattern #3 bootstrap: IDLE on INBOX only (NEW-2)

    /// Sent/Drafts are low-traffic — 60s STATUS polling is sufficient.
    /// Persistent IDLE reserved for INBOX only to reduce connection count.
    func startSpecialUseIDLE(account: Account) async {
        // No-op: Sent/Drafts no longer get persistent IDLE (NEW-2).
        // They are covered by STATUS polling every 60s.
    }

    /// Called when the user selects a folder in the sidebar. Ensures that
    /// folder has an active IDLE session, so changes push immediately while
    /// the user is looking at it.
    func ensureIDLEForSelected(folderID: UUID) async {
        guard let folder = try? await pool.read({ db in
            try Folder.fetchOne(db, key: folderID)
        }) else { return }

        // INBOX already has persistent IDLE. Selecting it (or any inbox) means
        // we're no longer looking at the previously-selected non-INBOX folder —
        // tear its dedicated IDLE down so sessions don't pile up (rule 20).
        if let su = folder.specialUse, su == .inbox {
            stopSelectedIdleIfNeeded(newKey: nil)
            return
        }

        guard let account = try? await pool.read({ db in
            try Account.fetchOne(db, key: folder.accountID)
        }) else { return }

        // §14: only one selected-folder IDLE at a time. Stop the previous
        // selection's IDLE before starting this one so dedicated IDLE sessions
        // don't accumulate past the Gmail ~15-connection limit (rule 20).
        let newKey = "\(account.id):\(folder.path)"
        stopSelectedIdleIfNeeded(newKey: newKey)
        selectedIdleKey = newKey
        ensureIDLE(account: account, folderPath: folder.path)
    }

    /// Stop the IDLE session for the previously-selected non-INBOX folder when
    /// the selection changes. INBOX IDLE is persistent and never torn down here.
    private func stopSelectedIdleIfNeeded(newKey: String?) {
        guard let current = selectedIdleKey, current != newKey else { return }
        if !current.hasSuffix(":INBOX") {
            idleTasks[current]?.cancel()
            idleTasks.removeValue(forKey: current)
            LogService.log(.debug, .imap, "Stopped selected-folder IDLE", detail: current)
        }
        selectedIdleKey = nil
    }

    // MARK: - Pattern #2: Background prefetch

    /// Fetches all non-INBOX folders for an account in the background.
    /// Runs at low priority with throttling to avoid server overload.
    /// Called once per account after the initial INBOX sync completes.
    func prefetchAllFolders(account: Account) async {
        let imap = getOrCreateIMAPService(for: account)
        guard await imap.isConnected else { return }

        // Load all folders for this account, excluding INBOX and virtual \All Mail.
        // NULL-safe: ordinary folders carry special_use = NULL, and GRDB's `!=`
        // emits `<>` (not `IS NOT`), so `special_use != 'inbox'` drops every NULL
        // row — silently excluding all ordinary/nested folders from prefetch.
        let folders: [Folder] = (try? await pool.read { db in
            try Folder
                .filter(Column("account_id") == account.id)
                .filter(sql: "(special_use IS NULL OR special_use NOT IN ('inbox', 'all'))")
                .fetchAll(db)
        }) ?? []

        guard !folders.isEmpty else { return }

        LogService.log(.info, .sync, "Background prefetch", detail: "\(folders.count) folders for \(account.email)")

        for folder in folders {
            if Task.isCancelled { break }

            // Skip folders already synced (uidValidity set)
            if folder.uidValidity != nil && folder.uidValidity! > 0 {
                continue
            }

            // Serialize each folder sync through the per-account queue —
            // prevents interleaving with user-triggered folder selects
            // or IDLE-driven syncs on the same IMAP connection.
            try? await runSerializedPerAccount(account.id) { [weak self] in
                guard let self else { return }
                do {
                    try await self.incrementalSync(
                        account: account, folderID: folder.id,
                        folderPath: folder.path, imap: imap
                    )
                    LogService.log(.debug, .sync, "Prefetched", detail: folder.path)
                } catch {
                    LogService.log(.warning, .sync,
                        "Prefetch failed for \(folder.path)", detail: "\(error)")
                }
            }

            // Throttle: 200ms between folders to avoid hammering the server
            try? await Task.sleep(for: .milliseconds(200))
        }

        LogService.log(.info, .sync, "Background prefetch complete", detail: account.email)
    }

    // MARK: - Pattern #4: STATUS polling

    /// Polls all non-IDLE folders via IMAP STATUS (cheap, no SELECT).
    /// Detects new messages (uidNext changed) and updates unread counts.
    /// Runs every 60s via the periodic timer.
    func pollFolderStatuses() async {
        let accounts: [Account] = (try? await pool.read { db in
            try Account.filter(Column("is_enabled") == true).fetchAll(db)
        }) ?? []

        for account in accounts {
            if Task.isCancelled { break }
            // §18: skip needsReauth accounts — STATUS poll would connect and
            // trigger a lazy token refresh that floods the grant endpoint.
            if account.authState == .needsReauth { continue }
            await pollFolderStatuses(for: account)
        }
    }

    func pollFolderStatuses(for account: Account) async {
        // Don't poll while bootstrap sync is running — it serializes through
        // the same per-account lock and would just stack work behind it. The
        // bootstrap path syncs INBOX itself; non-INBOX folders are covered by
        // the prefetch sweep that follows in `_runSyncAccountLocked`.
        if runningSyncs[account.id] != nil {
            LogService.log(.debug, .sync, "STATUS poll skipped (account sync in flight)",
                           detail: account.email)
            return
        }

        let imap = getOrCreateIMAPService(for: account)

        // Make sure we're connected; skip silently if not
        do {
            if await !imap.isConnected { try await imap.connect() }
        } catch {
            LogService.log(.debug, .sync, "STATUS poll skipped (offline)", detail: account.email)
            return
        }

        // Collect folder paths with active IDLE sessions for this account
        let accountPrefix = "\(account.id):"
        let idlePaths: Set<String> = Set(
            idleTasks.keys
                .filter { $0.hasPrefix(accountPrefix) }
                .map { String($0.dropFirst(accountPrefix.count)) }
        )

        // Exclude:
        //   • INBOX (covered by IDLE)
        //   • \All / Archive (Gmail returns \Archive in SPECIAL-USE for All Mail,
        //     stored as 'archive'; polling a 135k-message folder costs more than
        //     it earns — incrementalSync there is a multi-minute backfill)
        //   • IDLE-active folders (already pushing changes live)
        //   • folders with a sync currently in flight (`syncingFolders` —
        //     prevents STATUS poll from stacking duplicate work behind a long
        //     user-initiated incrementalSync, e.g. on-select All Mail open)
        // NULL-safe: ordinary folders carry special_use = NULL. GRDB's `!=` emits
        // `<>`, and `NULL <> 'inbox'` is NULL (not TRUE), so the old chained `!=`
        // filters dropped every NULL row — excluding all ordinary/nested folders
        // (e.g. INBOX/Receipts from server-side rules) from STATUS polling.
        let folders: [Folder] = (try? await pool.read { db in
            try Folder
                .filter(Column("account_id") == account.id)
                .filter(sql: "(special_use IS NULL OR special_use NOT IN ('inbox', 'all', 'archive'))")
                .fetchAll(db)
        })?.filter { !idlePaths.contains($0.path) && !syncingFolders.contains($0.id) } ?? []

        for folder in folders {
            if Task.isCancelled { break }
            // Re-check inside the loop — a user-initiated sync may have started
            // for this folder while we were polling earlier folders.
            if syncingFolders.contains(folder.id) {
                LogService.log(.debug, .sync, "STATUS poll skipped (folder sync in flight)",
                               detail: folder.path)
                continue
            }
            await pollStatus(folder: folder, account: account, imap: imap)
            // Throttle: 100ms between STATUS calls
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func pollStatus(folder: Folder, account: Account, imap: IMAPService) async {
        let status: Mailbox.Status
        do {
            status = try await imap.mailboxStatus(folder.path)
        } catch {
            LogService.log(.debug, .sync,
                "STATUS failed for \(folder.path)", detail: "\(error)")
            await recycleConnectionIfDesynced(error, imap: imap)
            return
        }

        let serverUidNext = status.uidNext?.value ?? 0
        let serverUnseen = status.unseenCount ?? 0
        let serverModSeq = status.highestModSequence
        let savedUidNext = folder.uidNext ?? 0
        let savedModSeq = folder.highestModSequence

        // Reconcile unread/total from `messages.is_read`. Gmail STATUS UNSEEN is
        // unreliable for non-INBOX folders; local DB is source of truth
        // (Thunderbird SyncCounts parity).
        //
        // §8 (RFC 7162 §4): do NOT persist highest_mod_sequence here. STATUS
        // reports the server's current HIGHESTMODSEQ, but we haven't yet fetched
        // the delta between savedModSeq and serverModSeq. Advancing the watermark
        // now would make the next CHANGEDSINCE FETCH request changes *after*
        // serverModSeq — silently dropping every flag change in the gap. The
        // watermark is advanced only by the sync paths, after the delta is
        // applied. serverModSeq is used below solely for the early-return check.
        let localUnread: Int = (try? await pool.write { db -> Int in
            try db.execute(
                sql: """
                UPDATE folders SET
                    unread_count = (
                        SELECT COUNT(*) FROM messages
                        WHERE folder_id = folders.id AND is_read = 0
                    ),
                    total_count = (
                        SELECT COUNT(*) FROM messages
                        WHERE folder_id = folders.id
                    )
                WHERE id = ?
                """,
                arguments: [folder.id]
            )
            return try Int.fetchOne(
                db,
                sql: "SELECT unread_count FROM folders WHERE id = ?",
                arguments: [folder.id]
            ) ?? 0
        }) ?? -1

        // Diagnostic: warn when server and local disagree — typical for Gmail.
        if localUnread >= 0, localUnread != serverUnseen {
            LogService.log(.debug, .sync,
                "STATUS UNSEEN mismatch",
                detail: "\(folder.path): server=\(serverUnseen) local=\(localUnread)")
        }

        // CONDSTORE early-return: if server reports same HIGHESTMODSEQ and
        // same UIDNEXT as we last saw, nothing changed — skip sync entirely.
        if let savedModSeq, let serverModSeq,
           savedModSeq == serverModSeq, serverUidNext == savedUidNext {
            return
        }

        // Trigger incremental sync if new messages arrived. Serialize with
        // other ops on this account (Thunderbird URL queue parity).
        // savedUidNext == 0 = folder never bootstrapped (created via LIST,
        // never SELECTed). TB treats this as "first observation, fetch headers"
        // — same as any subsequent UIDNEXT bump. Without this, rule-target
        // folders the user has never opened never get their unread badge.
        if serverUidNext > savedUidNext {
            LogService.log(.info, .sync,
                "STATUS detected changes",
                detail: "\(folder.path): \(savedUidNext) → \(serverUidNext)")
            try? await runSerializedPerAccount(account.id) { [weak self] in
                guard let self else { return }
                do {
                    try await self.incrementalSync(
                        account: account, folderID: folder.id,
                        folderPath: folder.path, imap: imap
                    )
                } catch {
                    LogService.log(.warning, .sync,
                        "Incremental sync after STATUS failed", detail: "\(error)")
                    await self.recycleConnectionIfDesynced(error, imap: imap)
                }
            }
        }
    }
}
