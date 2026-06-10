//
//  SyncService+Private.swift
//  MyEmail
//
//  Thunderbird-aligned sync internals: unified incrementalSync flow,
//  window-based UID comparison, single-command flag sync.
//

import Foundation
import GRDB
import SwiftEmailParser
import SwiftMail

extension SyncService {

    // MARK: - Ensure INBOX folder row exists

    /// Returns (folderID, Mailbox.Selection) — selection is reused by
    /// incrementalSync to avoid a redundant IMAP SELECT.
    func ensureInboxFolder(
        for account: Account,
        imap: IMAPService
    ) async throws -> (UUID, Mailbox.Selection) {
        let accountID = account.id
        let sel = try await imap.selectFolder("INBOX")

        if let existing: Folder = try await pool.read({ db in
            try Folder
                .filter(Column("account_id") == accountID)
                .filter(Column("special_use") == SpecialUse.inbox.rawValue)
                .fetchOne(db)
        }) {
            return (existing.id, sel)
        }

        let folder = Folder(
            id: UUID(), accountID: account.id,
            path: "INBOX", name: "INBOX", displayName: "Inbox",
            separator: "/", specialUse: .inbox, subscribed: true,
            uidValidity: sel.uidValidity.value, uidNext: 0,
            highestModSequence: nil,
            visibleLimit: 200, moreMessages: .unknown, highestKnownUid: nil,
            totalCount: 0, unreadCount: 0
        )

        try await pool.write { db in
            var mutable = folder
            try mutable.insert(db)
        }

        LogService.log(.info, .sync, "Created INBOX folder", detail: account.email)
        return (folder.id, sel)
    }

    // MARK: - Local sync state read (§9.2)

    /// Reads local UIDs plus pending-action UIDs in both directions for a folder.
    /// - pendingSourceUIDs: actions LEAVING this folder — their source-UID
    ///   legitimately disappears from the server, so must NOT be ghosted.
    /// - pendingTargetUIDs: actions ARRIVING in this folder — an optimistic move
    ///   writes the source-UID under the target folder_id before the server
    ///   assigns a new one; reconcile of the target would otherwise ghost it
    ///   → rollback + duplicate. Both are subtracted in every ghost/phantom branch.
    private func readLocalSyncState(
        folderID: UUID, folderPath: String, accountID: UUID
    ) async throws -> (Set<UInt32>, Set<UInt32>, Set<UInt32>) {
        try await pool.read { db -> (Set<UInt32>, Set<UInt32>, Set<UInt32>) in
            let rows = try UInt32.fetchAll(db, sql:
                "SELECT uid FROM messages WHERE folder_id = ? AND uid > 0",
                arguments: [folderID])
            let source = try UInt32.fetchAll(db, sql: """
                SELECT message_uid FROM pending_actions
                WHERE source_folder_path = ? AND account_id = ?
                  AND status != 'failed' AND message_uid IS NOT NULL
                """, arguments: [folderPath, accountID])
            let target = try UInt32.fetchAll(db, sql: """
                SELECT message_uid FROM pending_actions
                WHERE target_folder_path = ? AND account_id = ?
                  AND status != 'failed' AND message_uid IS NOT NULL
                """, arguments: [folderPath, accountID])
            return (Set(rows), Set(source), Set(target))
        }
    }

    // MARK: - Unified incremental sync (Thunderbird §5.2)

    func incrementalSync(
        account: Account, folderID: UUID, folderPath: String,
        imap: IMAPService, cachedSelection: Mailbox.Selection? = nil
    ) async throws {
        // Thunderbird parity (§3a): drain offline queue before any remote read.
        // Otherwise IDLE-push / periodic poll would overwrite stale-offline
        // local mutations before they replay to the server.
        await drainOfflineQueueIfNeeded()

        let saved: Folder? = try await pool.read { db in
            try Folder.fetchOne(db, key: folderID)
        }
        guard let saved else {
            LogService.log(.error, .sync, "Folder not found in DB", detail: "\(folderID)")
            return
        }
        let savedUidValidity = saved.uidValidity ?? 0
        let savedHighestModSeq = UInt64(max(saved.highestModSequence ?? 0, 0))

        // Step 1: SELECT. Prefer QRESYNC (RFC 7162 §3.2.5) when:
        //   - server advertises QRESYNC,
        //   - we have a saved UIDVALIDITY + HIGHESTMODSEQ watermark,
        //   - the caller didn't already pass a cached selection.
        // QRESYNC SELECT returns `* VANISHED (EARLIER) <uid-set>` inline — the
        // ghost set arrives in the same round trip as the SELECT OK, which
        // eliminates the separate chunked SEARCH pass from Phase A.
        let sel: Mailbox.Selection
        if let cached = cachedSelection {
            sel = cached
        } else if await imap.supportsQResync,
                  savedUidValidity > 0, savedHighestModSeq > 0 {
            do {
                sel = try await imap.selectFolderWithQResync(
                    folderPath,
                    uidValidity: savedUidValidity,
                    modSeq: savedHighestModSeq,
                    knownUids: nil
                )
            } catch {
                LogService.log(.warning, .sync,
                    "QRESYNC SELECT failed, falling back to plain SELECT",
                    detail: "\(folderPath): \(error)")
                sel = try await imap.selectFolder(folderPath)
            }
        } else {
            sel = try await imap.selectFolder(folderPath)
        }
        let serverUidValidity = sel.uidValidity.value
        let serverUidNext = sel.uidNext.value
        let serverCount = sel.messageCount

        LogService.log(.info, .sync, "SELECT \(folderPath)",
                       detail: "exists=\(serverCount) uidValidity=\(serverUidValidity) uidNext=\(serverUidNext)")

        // Step 2: UIDVALIDITY check — full reset if changed
        if savedUidValidity != 0, savedUidValidity != serverUidValidity {
            LogService.log(.warning, .sync, "UIDVALIDITY changed, full resync",
                           detail: "\(folderPath): \(savedUidValidity) → \(serverUidValidity)")
            try await fullResync(account: account, folderID: folderID,
                                 folderPath: folderPath, imap: imap, selection: sel)
            return
        }

        // Step 2b: MODSEQ regression check (RFC 7162 §6). Server-side repair /
        // restore drops the HIGHESTMODSEQ below our last known watermark;
        // treat this as a UIDVALIDITY-style reset to avoid missing changes.
        if let serverModSeq = sel.highestModSequence,
           let savedModSeq = saved.highestModSequence,
           savedModSeq > 0,
           UInt64(savedModSeq) > serverModSeq {
            LogService.log(.warning, .sync, "MODSEQ regression — full resync",
                           detail: "\(folderPath): \(savedModSeq) → \(serverModSeq)")
            try await fullResync(account: account, folderID: folderID,
                                 folderPath: folderPath, imap: imap, selection: sel)
            return
        }

        // Step 3: Remember highestKnownUid for notification decisions
        let highestKnownUid = saved.highestKnownUid ?? 0

        // Read local state: UIDs + pending action UIDs (both directions, §9.2).
        let accountID = account.id
        let (localUIDs, pendingSourceUIDs, pendingTargetUIDs) =
            try await readLocalSyncState(folderID: folderID, folderPath: folderPath, accountID: accountID)

        // Step 4: Branch on sync strategy.
        if localUIDs.isEmpty {
            // Initial fetch: Thunderbird-style eager enumeration, batched
            // newest-first with prefetch pipelining (see `batchedInitialFetch`).
            // Mirrors `FolderMsgDumpLoop` in `nsImapProtocol.cpp:4539` which
            // issues `FETCH` per UID-range chunk instead of one giant command.
            //
            // Batching is required because a single FETCH 1:<EXISTS> on a
            // 134k-message folder saturates the IMAP command timeout — SwiftMail
            // waits for the tagged OK and the whole sync aborts with nothing
            // persisted. Per-chunk persist means a timeout mid-run keeps
            // progress: the next `incrementalSync` picks up via `backfillOlderHeaders`.
            let infos = try await batchedInitialFetch(
                account: account, folderID: folderID, folderPath: folderPath,
                imap: imap, total: UInt32(serverCount), folder: saved
            )

            await fetchPreviews(folderID: folderID, imap: imap)

            // Eager model: once initial fetch is done, every message is local.
            let hasMore: MoreMessages = .false
            let newHighest = infos.compactMap(\.uid).map(\.value).max() ?? 0

            try await updateFolderState(
                folderID: folderID, uidValidity: serverUidValidity,
                uidNext: serverUidNext, totalCount: serverCount,
                highestKnownUid: newHighest, moreMessages: hasMore
            )
            // Persist HIGHESTMODSEQ for subsequent CONDSTORE deltas.
            if let newModSeq = sel.highestModSequence {
                try? await pool.write { db in
                    try db.execute(
                        sql: "UPDATE folders SET highest_mod_sequence = ? WHERE id = ?",
                        arguments: [Int(exactly: newModSeq) ?? Int.max, folderID]
                    )
                }
            }
            LogService.log(.info, .sync, "Initial fetch: \(infos.count) headers", detail: folderPath)
            return
        }

        // QRESYNC primary path (RFC 7162 §3.2) — VANISHED (EARLIER) arrived
        // inline with the SELECT above. `sel.vanishedUIDs` carries the ghost
        // set with no extra round trip. We still need a CHANGEDSINCE FETCH
        // for *new + mutated* messages, since SELECT (QRESYNC ...) only
        // backfills FETCH lines when the server chooses to — coverage of
        // novel UIDs (those created after our modSeq) is not guaranteed
        // across providers. Issue the delta FETCH explicitly.
        if await imap.supportsQResync,
           let savedModSeq = saved.highestModSequence, savedModSeq > 0,
           sel.uidValidity.value == savedUidValidity {
            try await qresyncIncrementalSync(
                account: account, folderID: folderID, folderPath: folderPath,
                imap: imap, saved: saved, sel: sel,
                localUIDs: localUIDs, pendingSourceUIDs: pendingSourceUIDs,
                pendingTargetUIDs: pendingTargetUIDs,
                highestKnownUid: highestKnownUid
            )
            return
        }

        // CONDSTORE primary path (RFC 7162) — single FETCH ... (CHANGEDSINCE).
        // Per-message response lines, so the 8 KB line-length limit in
        // swift-nio-imap's UID SEARCH `<min>:*` cannot trip here.
        if await imap.supportsCondStore,
           let savedModSeq = saved.highestModSequence, savedModSeq > 0 {
            try await condstoreIncrementalSync(
                account: account, folderID: folderID, folderPath: folderPath,
                imap: imap, saved: saved, sel: sel,
                localUIDs: localUIDs, pendingSourceUIDs: pendingSourceUIDs,
                pendingTargetUIDs: pendingTargetUIDs,
                highestKnownUid: highestKnownUid
            )
            return
        }

        // Legacy path: chunked UID SEARCH from window bottom.
        try await legacyIncrementalSync(
            account: account, folderID: folderID, folderPath: folderPath,
            imap: imap, saved: saved, sel: sel,
            localUIDs: localUIDs,
            pendingSourceUIDs: pendingSourceUIDs,
            pendingTargetUIDs: pendingTargetUIDs,
            highestKnownUid: highestKnownUid
        )
    }

    // MARK: - QRESYNC primary sync (RFC 7162 §3.2)

    /// QRESYNC-based incremental sync. Pre-requisites enforced by the caller:
    /// server advertises QRESYNC, saved UIDVALIDITY matches, saved MODSEQ > 0.
    ///
    /// Flow:
    /// 1. `sel.vanishedUIDs` already carries the ghost set from the SELECT
    ///    (QRESYNC ...) untagged `* VANISHED (EARLIER)` response — no separate
    ///    SEARCH needed. Subtract pending source UIDs so in-flight move/delete
    ///    actions don't double-ghost.
    /// 2. `fetchChangedInfos(changedSince:)` brings down new + mutated messages
    ///    (same CONDSTORE delta used by `condstoreIncrementalSync`).
    /// 3. Partition into new vs existing, persist headers, apply flag updates.
    /// 4. Delete ghosts from GRDB.
    /// 5. Advance HIGHESTMODSEQ watermark.
    private func qresyncIncrementalSync(
        account: Account, folderID: UUID, folderPath: String,
        imap: IMAPService, saved: Folder, sel: Mailbox.Selection,
        localUIDs: Set<UInt32>, pendingSourceUIDs: Set<UInt32>,
        pendingTargetUIDs: Set<UInt32>,
        highestKnownUid: UInt32
    ) async throws {
        LogService.log(.info, .sync, "sync path: qresync", detail: folderPath)

        let accountID = account.id
        let serverUidValidity = sel.uidValidity.value
        let serverUidNext = sel.uidNext.value
        let serverCount = sel.messageCount
        let savedModSeq = UInt64(max(saved.highestModSequence ?? 0, 0))

        // 1) Ghosts — VANISHED (EARLIER) already delivered. Subtract both
        //    pending directions (§9.2): source-UIDs leaving and target-UIDs
        //    arriving via an in-flight optimistic move.
        let ghostUIDs = sel.vanishedUIDs
            .intersection(localUIDs)
            .subtracting(pendingSourceUIDs)
            .subtracting(pendingTargetUIDs)

        // 2) Delta FETCH for new + mutated messages.
        let changedInfos: [MessageInfo]
        do {
            changedInfos = try await imap.fetchChangedInfos(changedSince: savedModSeq)
        } catch {
            LogService.log(.warning, .sync,
                "QRESYNC delta fetch failed, falling back to CONDSTORE",
                detail: "\(folderPath): \(error)")
            try await condstoreIncrementalSync(
                account: account, folderID: folderID, folderPath: folderPath,
                imap: imap, saved: saved, sel: sel,
                localUIDs: localUIDs, pendingSourceUIDs: pendingSourceUIDs,
                pendingTargetUIDs: pendingTargetUIDs,
                highestKnownUid: highestKnownUid
            )
            return
        }

        // 3) Partition delta into NEW vs EXISTING. VANISHED UIDs should not
        //    appear here, but if they do (server race), skip them.
        var newInfos: [MessageInfo] = []
        var existingFlags: [(uid: UInt32, flags: [Flag])] = []
        for info in changedInfos {
            guard let uid = info.uid?.value else { continue }
            if sel.vanishedUIDs.contains(uid) { continue }
            if localUIDs.contains(uid) {
                existingFlags.append((uid: uid, flags: info.flags))
            } else {
                newInfos.append(info)
            }
        }

        if !newInfos.isEmpty {
            try await persistHeaders(newInfos, folderID: folderID, accountID: accountID)
            // Rule scope / trigger gating happens inside RuleEngine: rules with
            // empty folder_paths still only match inbox-like folders (legacy),
            // rules with non-empty scope match the listed paths exactly.
            await applyRulesToNewMessages(newInfos, folder: saved, accountID: accountID)
        }
        if !existingFlags.isEmpty {
            await applyFlagUpdates(existingFlags, folderID: folderID)
        }

        // 4) Apply ghosts.
        if !ghostUIDs.isEmpty {
            let ghosts = ghostUIDs
            try await pool.write { db in
                try Message
                    .filter(Column("folder_id") == folderID)
                    .filter(ghosts.contains(Column("uid")))
                    .deleteAll(db)
            }
            LogService.log(.info, .sync, "Removed \(ghostUIDs.count) ghost messages via VANISHED",
                detail: folderPath)
        }

        // 4b) Phantom safety-net — VANISHED (EARLIER) only reports UIDs that
        //     were actually expunged from this mailbox on the server. UIDs
        //     that were never live here (e.g. source-folder UIDs written
        //     under this folder_id by an optimistic MOVE before the rewrite
        //     landed) are invisible to it. Mirror the CONDSTORE ghost-recheck
        //     pattern (`nsImapProtocol::ProcessMailboxUpdate`) and fall back
        //     to UID FETCH 1:* when EXISTS doesn't match the expected local
        //     count.
        let deltaNewUIDs: Set<UInt32> = Set(newInfos.compactMap { $0.uid?.value })
        let pendingDeleteCount = pendingSourceUIDs.intersection(localUIDs).count
        let expectedCount = localUIDs.count
            - ghostUIDs.count
            + deltaNewUIDs.subtracting(localUIDs).count
            - pendingDeleteCount
        let phantomUIDs = try await qresyncPhantomRecheck(
            folderID: folderID, folderPath: folderPath, imap: imap,
            input: PhantomRecheckInput(
                serverCount: serverCount, expectedCount: expectedCount,
                localUIDs: localUIDs, deltaNewUIDs: deltaNewUIDs, ghostUIDs: ghostUIDs,
                pendingSourceUIDs: pendingSourceUIDs, pendingTargetUIDs: pendingTargetUIDs,
                pendingDeleteCount: pendingDeleteCount
            )
        )

        // Backfill every untouched message below the current UID floor —
        // CHANGEDSINCE only covers mutated MODSEQs, so historical headers
        // need a separate full UID-range FETCH (Thunderbird eager model).
        let knownAfterDelta = localUIDs
            .union(deltaNewUIDs)
            .subtracting(ghostUIDs)
            .subtracting(phantomUIDs)
        let backfilledUIDs = try await backfillOlderHeaders(
            account: account, folderID: folderID, folderPath: folderPath,
            imap: imap, saved: saved,
            localUIDs: knownAfterDelta, minLocalUID: knownAfterDelta.min(),
            serverCount: serverCount,
            vanishedUIDs: sel.vanishedUIDs
        )

        if !newInfos.isEmpty || !backfilledUIDs.isEmpty {
            await fetchPreviews(folderID: folderID, imap: imap)
        }

        // 5) Advance HIGHESTMODSEQ watermark — never regress.
        let fetchedMax = changedInfos.compactMap(\.modSequence).max() ?? 0
        let selectMax = sel.highestModSequence ?? 0
        let newMax = max(fetchedMax, selectMax, savedModSeq)
        if fetchedMax > 0, fetchedMax < savedModSeq {
            LogService.log(.warning, .sync,
                "Gmail MODSEQ quirk: returned < requested",
                detail: "\(folderPath): fetched=\(fetchedMax) saved=\(savedModSeq)")
        }
        try? await pool.write { db in
            try db.execute(
                sql: "UPDATE folders SET highest_mod_sequence = ? WHERE id = ?",
                arguments: [Int(exactly: newMax) ?? Int.max, folderID]
            )
        }

        // Update folder state.
        let allKnownUIDs = localUIDs.union(deltaNewUIDs).union(backfilledUIDs)
            .subtracting(ghostUIDs).subtracting(phantomUIDs)
        let newHighestKnownUid = allKnownUIDs.max() ?? highestKnownUid
        let localTotal = allKnownUIDs.count
        let hasMore: MoreMessages = serverCount > localTotal ? .true : .false

        try await updateFolderState(
            folderID: folderID, uidValidity: serverUidValidity,
            uidNext: serverUidNext, totalCount: serverCount,
            highestKnownUid: newHighestKnownUid, moreMessages: hasMore
        )

        LogService.log(.info, .sync, "QRESYNC delta",
            detail: "\(folderPath) newUIDs=\(deltaNewUIDs.count) changedFlags=\(existingFlags.count) vanished=\(ghostUIDs.count) phantom=\(phantomUIDs.count) backfilled=\(backfilledUIDs.count) modseq=\(savedModSeq)→\(newMax)")
    }

    /// Bounded phantom-recheck for the QRESYNC path. QRESYNC's VANISHED set only
    /// covers server-side expunges, so source-folder UIDs written under this
    /// folder_id by an optimistic MOVE (and never live here) stay invisible.
    /// §13: EXISTS counts \Deleted-but-not-expunged, so force the recheck when we
    /// have pending deletes here even if EXISTS shows no drop. Deletes phantoms
    /// in place and returns them for logging.
    /// Inputs for `qresyncPhantomRecheck`, bundled to keep the parameter list
    /// small. All UID sets/counts are computed by the caller from the delta.
    struct PhantomRecheckInput: Sendable {
        let serverCount: Int
        let expectedCount: Int
        let localUIDs: Set<UInt32>
        let deltaNewUIDs: Set<UInt32>
        let ghostUIDs: Set<UInt32>
        let pendingSourceUIDs: Set<UInt32>
        let pendingTargetUIDs: Set<UInt32>
        let pendingDeleteCount: Int
    }

    private func qresyncPhantomRecheck(
        folderID: UUID, folderPath: String, imap: IMAPService,
        input: PhantomRecheckInput
    ) async throws -> Set<UInt32> {
        let serverCount = input.serverCount
        let expectedCount = input.expectedCount
        let pendingSourceUIDs = input.pendingSourceUIDs
        let pendingTargetUIDs = input.pendingTargetUIDs
        let forceGhostRecheck = input.pendingDeleteCount > 0
        let liveLocalCandidates = input.localUIDs.union(input.deltaNewUIDs)
            .subtracting(input.ghostUIDs)
        guard (serverCount < expectedCount || forceGhostRecheck),
              let minLocal = liveLocalCandidates.min(),
              let maxLocal = liveLocalCandidates.max() else { return [] }

        LogService.log(.info, .sync, "sync path: qresync phantom-recheck",
            detail: "\(folderPath): expected=\(expectedCount) server=\(serverCount) range=\(minLocal)…\(maxLocal)")
        let entries: [(uid: UInt32, flags: [Flag], modSeq: UInt64?)]
        do {
            entries = try await imap.fetchAllFlags(uidRange: minLocal...maxLocal)
        } catch {
            Self.dumpParserErrorBuffer(error, context: "qresync phantom-recheck")
            throw error
        }
        var serverUIDs: Set<UInt32> = []
        serverUIDs.reserveCapacity(entries.count)
        for entry in entries where !entry.flags.contains(.deleted) {
            serverUIDs.insert(entry.uid)
        }
        let phantomUIDs = liveLocalCandidates.subtracting(serverUIDs)
            .subtracting(pendingSourceUIDs).subtracting(pendingTargetUIDs)
        if !phantomUIDs.isEmpty {
            let phantoms = phantomUIDs
            try await pool.write { db in
                try Message
                    .filter(Column("folder_id") == folderID)
                    .filter(phantoms.contains(Column("uid")))
                    .deleteAll(db)
            }
            LogService.log(.info, .sync,
                "Removed \(phantomUIDs.count) phantom UIDs via SEARCH reconcile",
                detail: folderPath)
        }
        return phantomUIDs
    }

    // MARK: - CONDSTORE primary sync (RFC 7162)

    /// CONDSTORE-based incremental sync. Single `UID FETCH 1:* (CHANGEDSINCE <modseq>)`
    /// returns every UID whose MODSEQ advanced since our watermark — new
    /// messages, flag updates, and envelope repairs all in one round-trip.
    /// Ghost detection falls back to chunked SEARCH only when EXISTS doesn't
    /// match our expected count.
    private func condstoreIncrementalSync(
        account: Account, folderID: UUID, folderPath: String,
        imap: IMAPService, saved: Folder, sel: Mailbox.Selection,
        localUIDs: Set<UInt32>, pendingSourceUIDs: Set<UInt32>,
        pendingTargetUIDs: Set<UInt32>,
        highestKnownUid: UInt32
    ) async throws {
        LogService.log(.info, .sync, "sync path: condstore", detail: folderPath)

        let accountID = account.id
        let serverUidValidity = sel.uidValidity.value
        let serverUidNext = sel.uidNext.value
        let serverCount = sel.messageCount
        let savedModSeq = UInt64(max(saved.highestModSequence ?? 0, 0))

        // Fetch CONDSTORE delta.
        let changedInfos: [MessageInfo]
        do {
            changedInfos = try await imap.fetchChangedInfos(changedSince: savedModSeq)
        } catch {
            LogService.log(.warning, .sync,
                "CONDSTORE delta fetch failed, falling back to legacy",
                detail: "\(folderPath): \(error)")
            await recycleConnectionIfDesynced(error, imap: imap)
            // Fall back to legacy — keep current watermark; don't regress.
            try await legacyIncrementalSync(
                account: account, folderID: folderID, folderPath: folderPath,
                imap: imap, saved: saved, sel: sel,
                localUIDs: localUIDs,
                pendingSourceUIDs: pendingSourceUIDs,
                pendingTargetUIDs: pendingTargetUIDs,
                highestKnownUid: highestKnownUid
            )
            return
        }

        // Partition delta into NEW vs EXISTING.
        var newInfos: [MessageInfo] = []
        var existingFlags: [(uid: UInt32, flags: [Flag])] = []
        for info in changedInfos {
            guard let uid = info.uid?.value else { continue }
            if localUIDs.contains(uid) {
                existingFlags.append((uid: uid, flags: info.flags))
            } else {
                newInfos.append(info)
            }
        }

        // Persist NEW headers and fetch previews.
        if !newInfos.isEmpty {
            try await persistHeaders(newInfos, folderID: folderID, accountID: accountID)
            await applyRulesToNewMessages(newInfos, folder: saved, accountID: accountID)
        }

        // Apply flag updates (respects recentMutationStore cooldown, bug 9.10).
        if !existingFlags.isEmpty {
            await applyFlagUpdates(existingFlags, folderID: folderID)
        }

        // Ghost detection via EXISTS delta (Thunderbird fast path).
        // Expected local count after this sync = existing localUIDs + new UIDs
        // we just learned about, minus pending deletes. If server EXISTS
        // matches, no ghosts. Otherwise fall back to a bounded UID SEARCH.
        let newUIDs: Set<UInt32> = Set(newInfos.compactMap { $0.uid?.value })
        let pendingDeleteCount = pendingSourceUIDs.intersection(localUIDs).count
        let expectedCount = localUIDs.count + newUIDs.count - pendingDeleteCount

        var ghostUIDs: Set<UInt32> = []
        // Ghost-recheck makes sense when the server has FEWER live messages than
        // we expect locally — the signal that some of our UIDs were expunged.
        // `serverCount > expectedCount` is just an incomplete backfill (Gmail All
        // Mail 135k server vs 29k local): the backfill loop below closes that gap.
        //
        // §13: EXISTS (`serverCount`) counts \Deleted-but-not-expunged messages,
        // so on mark-deleted servers it stays inflated and hides a real shrink —
        // `serverCount < expectedCount` falsely reads false and the recheck is
        // skipped. When we have pending deletes in THIS folder (the mark-deleted
        // scenario we can detect cheaply), force the recheck even if EXISTS
        // doesn't show a drop. The FETCH is bounded to the local UID window, so
        // this only costs bandwidth on user-initiated deletes, never on Gmail's
        // huge incomplete-backfill folders.
        let forceGhostRecheck = pendingDeleteCount > 0
        if (serverCount < expectedCount || forceGhostRecheck),
           let minLocalUID = localUIDs.min(),
           let maxLocalUID = localUIDs.max() {
            LogService.log(.info, .sync, "sync path: ghost-recheck",
                detail: "\(folderPath): expected=\(expectedCount) server=\(serverCount) range=\(minLocalUID)…\(maxLocalUID)")
            let entries: [(uid: UInt32, flags: [Flag], modSeq: UInt64?)]
            do {
                entries = try await imap.fetchAllFlags(uidRange: minLocalUID...maxLocalUID)
            } catch {
                Self.dumpParserErrorBuffer(error, context: "ghost-recheck")
                throw error
            }
            var serverUIDs: Set<UInt32> = []
            serverUIDs.reserveCapacity(entries.count)
            for entry in entries where !entry.flags.contains(.deleted) {
                serverUIDs.insert(entry.uid)
            }
            ghostUIDs = localUIDs.subtracting(serverUIDs)
                .subtracting(pendingSourceUIDs).subtracting(pendingTargetUIDs)
        }

        if !ghostUIDs.isEmpty {
            let ghosts = ghostUIDs
            try await pool.write { db in
                try Message
                    .filter(Column("folder_id") == folderID)
                    .filter(ghosts.contains(Column("uid")))
                    .deleteAll(db)
            }
            LogService.log(.info, .sync, "Removed \(ghostUIDs.count) ghost messages",
                detail: folderPath)
        }

        // Backfill every untouched message below the current UID floor.
        let knownAfterDelta = localUIDs.union(newUIDs).subtracting(ghostUIDs)
        let backfilledUIDs = try await backfillOlderHeaders(
            account: account, folderID: folderID, folderPath: folderPath,
            imap: imap, saved: saved,
            localUIDs: knownAfterDelta, minLocalUID: knownAfterDelta.min(),
            serverCount: serverCount
        )

        if !newInfos.isEmpty || !backfilledUIDs.isEmpty {
            await fetchPreviews(folderID: folderID, imap: imap)
        }

        // Advance HIGHESTMODSEQ watermark. Gmail is known to sometimes return
        // MODSEQs below the requested CHANGEDSINCE — never regress. Prefer
        // the SELECT-reported HIGHESTMODSEQ when it's larger.
        let fetchedMax = changedInfos.compactMap(\.modSequence).max() ?? 0
        let selectMax = sel.highestModSequence ?? 0
        let newMax = max(fetchedMax, selectMax, savedModSeq)
        if fetchedMax > 0, fetchedMax < savedModSeq {
            LogService.log(.warning, .sync,
                "Gmail MODSEQ quirk: returned < requested",
                detail: "\(folderPath): fetched=\(fetchedMax) saved=\(savedModSeq)")
        }
        try? await pool.write { db in
            try db.execute(
                sql: "UPDATE folders SET highest_mod_sequence = ? WHERE id = ?",
                arguments: [Int(exactly: newMax) ?? Int.max, folderID]
            )
        }

        // Update folder state.
        let allKnownUIDs = localUIDs.union(newUIDs).union(backfilledUIDs).subtracting(ghostUIDs)
        let newHighestKnownUid = allKnownUIDs.max() ?? highestKnownUid
        let localTotal = allKnownUIDs.count
        let hasMore: MoreMessages = serverCount > localTotal ? .true : .false

        try await updateFolderState(
            folderID: folderID, uidValidity: serverUidValidity,
            uidNext: serverUidNext, totalCount: serverCount,
            highestKnownUid: newHighestKnownUid, moreMessages: hasMore
        )

        LogService.log(.info, .sync, "CONDSTORE delta",
            detail: "\(folderPath) newUIDs=\(newUIDs.count) changedFlags=\(existingFlags.count) ghosts=\(ghostUIDs.count) backfilled=\(backfilledUIDs.count) modseq=\(savedModSeq)→\(newMax)")
    }

    // MARK: - Legacy incremental sync (chunked UID SEARCH)

    /// Pre-CONDSTORE sync path — chunked `UID SEARCH <min>:<upper> NOT DELETED`
    /// followed by flag re-fetch. Kept as fallback when the server doesn't
    /// advertise CONDSTORE or we haven't yet captured a HIGHESTMODSEQ watermark.
    private func legacyIncrementalSync(
        account: Account, folderID: UUID, folderPath: String,
        imap: IMAPService, saved: Folder, sel: Mailbox.Selection,
        localUIDs: Set<UInt32>,
        pendingSourceUIDs: Set<UInt32>,
        pendingTargetUIDs: Set<UInt32>,
        highestKnownUid: UInt32
    ) async throws {
        LogService.log(.info, .sync, "sync path: legacy-search", detail: folderPath)

        let accountID = account.id
        let serverUidValidity = sel.uidValidity.value
        let serverUidNext = sel.uidNext.value
        let serverCount = sel.messageCount

        // Thunderbird-parity reconcile (nsImapProtocol.cpp:4259 —
        // `UID FETCH 1:* (FLAGS)`): each message produces its own response
        // line, so the full UID universe streams without the 8 KB line
        // limit that trips UID SEARCH on 100k+ folders.
        let entries = try await imap.fetchAllFlags()
        var serverUIDs: Set<UInt32> = []
        serverUIDs.reserveCapacity(entries.count)
        for entry in entries where !entry.flags.contains(.deleted) {
            serverUIDs.insert(entry.uid)
        }

        // 5a: New UIDs → fetch headers.
        let newUIDs = serverUIDs.subtracting(localUIDs)
        if !newUIDs.isEmpty {
            let sorted = newUIDs.sorted()
            let infos = try await resilientFetchHeaders(
                imap: imap, folderPath: folderPath, account: account,
                scopeUIDs: sorted
            ) {
                try await imap.fetchHeadersBySet(sorted)
            }
            try await persistHeaders(infos, folderID: folderID, accountID: accountID)
            await applyRulesToNewMessages(infos, folder: saved, accountID: accountID)
            LogService.log(.info, .sync, "Fetched \(infos.count) new headers", detail: folderPath)
        }

        // 5b: Existing UIDs → sync flags (CONDSTORE delta preferred).
        let existingUIDs = serverUIDs.intersection(localUIDs)
        if !existingUIDs.isEmpty {
            let handled = await deltaFlagSyncIfCondStore(
                folderID: folderID, folderPath: folderPath,
                savedModSeq: saved.highestModSequence, imap: imap
            )
            if !handled {
                await syncFlagsForUIDs(Array(existingUIDs), folderID: folderID, imap: imap)
            }
        }

        // Advance HIGHESTMODSEQ watermark from SELECT if advertised.
        if let newModSeq = sel.highestModSequence {
            try? await pool.write { db in
                try db.execute(
                    sql: "UPDATE folders SET highest_mod_sequence = ? WHERE id = ?",
                    arguments: [Int(exactly: newModSeq) ?? Int.max, folderID]
                )
            }
        }

        // 5c: Ghost UIDs — local UIDs absent on server within the window.
        // Exclude UIDs with pending move/delete actions (expected to be missing).
        let ghostUIDs = localUIDs.subtracting(serverUIDs)
            .subtracting(pendingSourceUIDs).subtracting(pendingTargetUIDs)
        if !ghostUIDs.isEmpty {
            let ghosts = ghostUIDs
            try await pool.write { db in
                try Message
                    .filter(Column("folder_id") == folderID)
                    .filter(ghosts.contains(Column("uid")))
                    .deleteAll(db)
            }
            LogService.log(.info, .sync, "Removed \(ghostUIDs.count) ghost messages", detail: folderPath)
        }

        if !newUIDs.isEmpty {
            await fetchPreviews(folderID: folderID, imap: imap)
        }

        let allKnownUIDs = serverUIDs.union(localUIDs)
        let newHighestKnownUid = allKnownUIDs.max() ?? highestKnownUid
        let localTotal = localUIDs.count + newUIDs.count - ghostUIDs.count
        let hasMore: MoreMessages = serverCount > localTotal ? .true : .false

        try await updateFolderState(
            folderID: folderID, uidValidity: serverUidValidity,
            uidNext: serverUidNext, totalCount: serverCount,
            highestKnownUid: newHighestKnownUid, moreMessages: hasMore
        )
    }

    // MARK: - Batched initial fetch (Thunderbird FolderMsgDumpLoop)

    /// Fetch every envelope in the currently selected folder in chunks of
    /// ~500 sequence numbers, newest-first, persisting each chunk before
    /// moving to the next. Returns the full set of fetched MessageInfos.
    ///
    /// Newest-first order ensures the user sees recent mail populate the list
    /// immediately while the older tail streams in. Per-chunk persist is a
    /// checkpoint: a timeout mid-run leaves the completed chunks intact, and
    /// the next `incrementalSync` resumes via `backfillOlderHeaders`.
    ///
    /// Prefetch pipelining: while chunk N is being persisted into GRDB, chunk
    /// N+1 is already being fetched from IMAP. On 134k-message folders this
    /// hides ~100ms/chunk of GRDB commit latency behind the ~1-2s FETCH.
    /// IMAPServer is an actor so the prefetch serialises behind any in-flight
    /// request on the same connection (e.g. a reset after parser error), but
    /// persist is independent and runs freely in parallel.
    func batchedInitialFetch(
        account: Account, folderID: UUID, folderPath: String,
        imap: IMAPService, total: UInt32, folder: Folder?,
        chunkSize: UInt32 = 500
    ) async throws -> [MessageInfo] {
        guard total > 0 else { return [] }
        LogService.log(.info, .sync,
            "sync path: initial (eager, batched \(chunkSize), pipelined)",
            detail: folderPath)

        var collected: [MessageInfo] = []
        var hi = total
        var prefetch: Task<[MessageInfo], Never>?

        // Cancel any in-flight prefetch if we exit via throw (persist error).
        defer { prefetch?.cancel() }

        while hi > 0 {
            let lo = hi > chunkSize ? hi - chunkSize + 1 : 1
            let range = SequenceNumber(lo)...SequenceNumber(hi)

            // Current chunk: either the one we pre-fetched on the previous
            // iteration, or (first iteration) fetch right now.
            let infos: [MessageInfo]
            if let task = prefetch {
                infos = await task.value
            } else {
                infos = await fetchChunkWithBisect(
                    imap: imap, folderPath: folderPath, range: range
                )
            }

            // Advance hi and kick off prefetch of the NEXT chunk before we
            // touch GRDB, so the IMAP FETCH overlaps with persist.
            let nextHi: UInt32 = lo > 1 ? lo - 1 : 0
            if nextHi > 0 {
                let nextLo: UInt32 = nextHi > chunkSize ? nextHi - chunkSize + 1 : 1
                let nextRange = SequenceNumber(nextLo)...SequenceNumber(nextHi)
                prefetch = Task {
                    await fetchChunkWithBisect(
                        imap: imap, folderPath: folderPath, range: nextRange
                    )
                }
            } else {
                prefetch = nil
            }

            if !infos.isEmpty {
                try await persistHeaders(infos, folderID: folderID, accountID: account.id)
                if let folder {
                    await applyRulesToNewMessages(
                        infos, folder: folder, accountID: account.id
                    )
                }
                collected.append(contentsOf: infos)

                LogService.log(.info, .sync,
                    "Initial chunk persisted: \(collected.count)/\(total)",
                    detail: folderPath)
            }

            hi = nextHi
        }
        return collected
    }

    /// Fetch a sequence range; on parser error, bisect and retry halves.
    /// Thunderbird parity (`nsImapServerResponseParser::skip_to_CRLF`): one
    /// malformed FETCH line shouldn't lose the whole batch. We narrow to
    /// the offending message via binary search; anything that still fails
    /// at size 1 is dropped and `backfillOlderHeaders` picks it up via UID
    /// on the next sync tick (raw fallback path).
    ///
    /// Non-parser errors propagate nothing (empty return) — the outer loop
    /// skips the range, same as before. Parser errors get the bisect.
    private func fetchChunkWithBisect(
        imap: IMAPService, folderPath: String,
        range: ClosedRange<SequenceNumber>
    ) async -> [MessageInfo] {
        let lo = range.lowerBound.value
        let hi = range.upperBound.value
        let size = hi >= lo ? hi - lo + 1 : 0
        let started = Date()

        LogService.log(.debug, .sync,
            "Chunk \(lo)...\(hi) start (size=\(size))", detail: folderPath)

        do {
            let infos = try await imap.fetchHeaders(sequenceRange: range)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            LogService.log(.debug, .sync,
                "Chunk \(lo)...\(hi) OK in \(ms)ms — \(infos.count) msgs",
                detail: folderPath)
            return infos
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let desc = "\(error)"
            let typeName = String(describing: type(of: error))

            LogService.log(.warning, .sync,
                "Chunk \(lo)...\(hi) FAILED after \(ms)ms (size=\(size), type=\(typeName))",
                detail: "\(folderPath): \(desc)")

            // Any FETCH error on SwiftMail poisons the channel — the parser
            // does not drain the rest of the untagged response to re-align,
            // so the server keeps feeding us bytes from the failed command
            // while interpreting our next FETCH as continuation, yielding
            // `[CLIENTBUG] Unrecognised command`. Always reset, then bisect
            // on the fresh socket to narrow down the offending message.
            await resetPoisonedConnection(imap: imap, folderPath: folderPath)

            if size <= 1 {
                LogService.log(.warning, .sync,
                    "Chunk \(lo) irrecoverable at size=1, skipping",
                    detail: "\(folderPath): \(typeName)")
                return []
            }

            LogService.log(.debug, .sync,
                "Bisecting chunk \(lo)...\(hi) after reset",
                detail: folderPath)

            let mid = lo + (size / 2) - 1
            let left = range.lowerBound...SequenceNumber(mid)
            let right = SequenceNumber(mid + 1)...range.upperBound
            let leftInfos = await fetchChunkWithBisect(
                imap: imap, folderPath: folderPath, range: left
            )
            let rightInfos = await fetchChunkWithBisect(
                imap: imap, folderPath: folderPath, range: right
            )
            return leftInfos + rightInfos
        }
    }

    // MARK: - Backfill older headers (Thunderbird eager model)

    /// Reconcile local DB against the **entire** server UID space [1...uidNext-1].
    /// Thunderbird `FindKeysToAdd` (`nsImapMailFolder.cpp:3956-4004`) does a
    /// sorted-merge of local UIDs vs server-live UIDs and appends every UID
    /// missing locally to `m_keysToFetch` — regardless of where it sits in the
    /// range. Floor-only backfill misses gaps in the **middle** (e.g. Gmail
    /// All Mail with 29k expunged-old + 77k interleaved-gap live UIDs).
    ///
    /// Required by QRESYNC/CONDSTORE delta paths because CHANGEDSINCE only
    /// returns messages whose MODSEQ advanced — old untouched messages and
    /// server-side gaps never appear there.
    ///
    /// Chunked FETCH FLAGS keeps each command under Gmail's 60s timeout;
    /// chunked header FETCH persists each batch immediately so a mid-loop
    /// failure preserves prior progress.
    @discardableResult
    private func backfillOlderHeaders(
        account: Account, folderID: UUID, folderPath: String,
        imap: IMAPService, saved: Folder,
        localUIDs: Set<UInt32>, minLocalUID: UInt32?,
        serverCount: Int,
        vanishedUIDs: Set<UInt32> = []
    ) async throws -> Set<UInt32> {
        // EXISTS caps the total: if we already have every live UID, skip.
        // (TB's `needFullFolderSync = !mFolderHighestUID || flagStateEmpty`
        // gates a full 1:* fetch on missing state; our equivalent is the
        // local-vs-server count mismatch.)
        guard serverCount > localUIDs.count else {
            LogService.log(.debug, .sync,
                "Backfill skipped: local=\(localUIDs.count) == server=\(serverCount)",
                detail: folderPath)
            return []
        }

        // Upper bound = uidNext - 1 (last UID the server has ever assigned).
        // Fall back to the highest local UID if uidNext isn't persisted yet —
        // first sync of a brand-new folder.
        let uidNext = saved.uidNext.map { UInt32($0) } ?? 0
        let maxLocal = localUIDs.max() ?? 0
        let upper = max(uidNext > 0 ? uidNext - 1 : 0, maxLocal)
        guard upper >= 1 else { return [] }

        // Step 1: enumerate server-live UIDs over the full range [1...upper],
        // chunked. Single `UID FETCH 1:<upper> (FLAGS)` over 135k UIDs times
        // out on Gmail All Mail (60s default). TB's nsImapProtocol does emit
        // a single 1:* FLAGS command, but the inbound parsing is incremental;
        // we don't have that streaming pipeline, so we mirror the intent by
        // splitting into bounded windows. Each chunk gets recycle treatment
        // so a poisoned socket reconnects mid-loop instead of failing all.
        var serverUIDs: Set<UInt32> = []
        let flagChunks = Self.chunkedUIDRange(lower: 1, upper: upper,
                                              size: Self.backfillFlagChunkSize)
        for chunk in flagChunks {
            do {
                let entries = try await imap.fetchAllFlags(uidRange: chunk)
                for entry in entries where !entry.flags.contains(.deleted) {
                    serverUIDs.insert(entry.uid)
                }
            } catch {
                LogService.log(.warning, .sync,
                    "Backfill FETCH \(chunk.lowerBound):\(chunk.upperBound) failed",
                    detail: "\(folderPath): \(error)")
                await recycleConnectionIfDesynced(error, imap: imap)
                // Partial progress on flags is fine — next reconcile pass will
                // re-enumerate the gap; bail to avoid hammering a dead socket.
                return []
            }
        }

        // Step 2: TB-style `FindKeysToAdd` — sorted-merge diff. Anything on
        // the server we don't have locally (and didn't just expunge) needs
        // its envelope pulled.
        let missing = serverUIDs
            .subtracting(localUIDs)
            .subtracting(vanishedUIDs)
            .sorted()
        guard !missing.isEmpty else {
            LogService.log(.debug, .sync,
                "Backfill: no missing UIDs in 1:\(upper) (\(serverUIDs.count) server-live)",
                detail: folderPath)
            return []
        }

        LogService.log(.info, .sync,
            "Backfill: \(missing.count) missing UIDs in 1:\(upper)",
            detail: folderPath)

        // Step 3: FETCH headers for missing UIDs, chunked. Persist each chunk
        // immediately so a mid-loop failure preserves what we got rather than
        // discarding everything on a single timeout.
        var persistedUIDs: Set<UInt32> = []
        let headerStride = Self.backfillHeaderChunkSize
        for chunkStart in stride(from: 0, to: missing.count, by: headerStride) {
            let chunkEnd = min(chunkStart + headerStride, missing.count)
            let headerChunk = Array(missing[chunkStart..<chunkEnd])
            let infos: [MessageInfo]
            do {
                infos = try await imap.fetchHeadersBySet(headerChunk)
            } catch {
                LogService.log(.warning, .sync,
                    "Backfill fetch failed",
                    detail: "\(folderPath) chunk=\(headerChunk.count): \(error)")
                await recycleConnectionIfDesynced(error, imap: imap)
                break
            }
            let fresh = infos.filter { info in
                guard let uid = info.uid?.value else { return false }
                if localUIDs.contains(uid) { return false }
                if vanishedUIDs.contains(uid) { return false }
                return true
            }
            guard !fresh.isEmpty else { continue }
            try await persistHeaders(fresh, folderID: folderID, accountID: account.id)
            for info in fresh {
                if let uid = info.uid?.value { persistedUIDs.insert(uid) }
            }
        }
        if !persistedUIDs.isEmpty {
            LogService.log(.info, .sync,
                "Backfill: persisted \(persistedUIDs.count) older headers",
                detail: folderPath)
        }
        return persistedUIDs
    }

    /// Backfill chunk sizing — TB-style bounded UID windows.
    /// 5000 keeps each FETCH well under Gmail's 60s timeout even on dense
    /// folders, while still amortizing setup cost across many UIDs.
    private static let backfillFlagChunkSize: UInt32 = 5_000
    /// Header fetch is heavier per UID (envelopes + previews) — keep smaller.
    private static let backfillHeaderChunkSize: Int = 500

    /// Split [lower...upper] into closed ranges no larger than `size`.
    nonisolated private static func chunkedUIDRange(
        lower: UInt32, upper: UInt32, size: UInt32
    ) -> [ClosedRange<UInt32>] {
        guard lower <= upper, size > 0 else { return [] }
        var out: [ClosedRange<UInt32>] = []
        var cursor = lower
        while cursor <= upper {
            let end = min(upper, cursor &+ size - 1)
            out.append(cursor...end)
            if end == UInt32.max { break }
            cursor = end + 1
        }
        return out
    }

    // MARK: - Flag sync via CONDSTORE CHANGEDSINCE (RFC 7162)

    /// Delta flag sync using CONDSTORE. Returns `true` when CONDSTORE was
    /// available and the delta fetch handled flag updates — caller must skip
    /// the legacy full-window path. Returns `false` to signal fallback.
    private func deltaFlagSyncIfCondStore(
        folderID: UUID,
        folderPath: String,
        savedModSeq: Int?,
        imap: IMAPService
    ) async -> Bool {
        // Require both: server CONDSTORE capability + a known prior watermark
        guard await imap.supportsCondStore else {
            LogService.log(.debug, .sync,
                "CONDSTORE unavailable, full window flag re-fetch",
                detail: folderPath)
            return false
        }
        guard let savedModSeq, savedModSeq > 0 else {
            LogService.log(.debug, .sync,
                "CONDSTORE: no saved HIGHESTMODSEQ yet, full window flag re-fetch",
                detail: folderPath)
            return false
        }

        let changedSince = UInt64(savedModSeq)
        let changes: [(uid: UInt32, flags: [Flag], modSequence: UInt64?)]
        do {
            changes = try await imap.fetchChangedFlags(changedSince: changedSince)
        } catch {
            LogService.log(.warning, .sync,
                "CONDSTORE delta fetch failed, falling back",
                detail: "\(folderPath): \(error)")
            return false
        }

        // Nothing changed server-side since our watermark — fast path.
        if changes.isEmpty {
            LogService.log(.info, .sync, "CONDSTORE delta sync: no changes",
                detail: "folder=\(folderPath) from=\(savedModSeq)")
            return true
        }

        let newMax = changes.compactMap(\.modSequence).max() ?? changedSince
        await applyFlagUpdates(changes.map { (uid: $0.uid, flags: $0.flags) },
                               folderID: folderID)

        LogService.log(.info, .sync, "CONDSTORE delta sync",
            detail: "folder=\(folderPath) from=\(savedModSeq) to=\(newMax) updated=\(changes.count)")
        return true
    }

    // MARK: - Flag sync via FETCH FLAGS (Thunderbird §5.2 step 8)

    /// Sync flags for specific UIDs using a single UID FETCH (FLAGS) command.
    /// Replaces the old 5-SEARCH approach (UNSEEN, FLAGGED, ANSWERED, DRAFT, KEYWORD).
    private func syncFlagsForUIDs(
        _ uids: [UInt32], folderID: UUID, imap: IMAPService
    ) async {
        do {
            // Batch into chunks of 100 to avoid oversized FETCH commands
            let batchSize = 100
            var allFlags: [(uid: UInt32, flags: [Flag])] = []
            for start in stride(from: 0, to: uids.count, by: batchSize) {
                let end = min(start + batchSize, uids.count)
                let batch = Array(uids[start..<end])
                let result = try await imap.fetchFlagsForUIDs(batch)
                allFlags.append(contentsOf: result)
            }

            await applyFlagUpdates(allFlags, folderID: folderID)
        } catch {
            LogService.log(.warning, .sync, "Flag sync failed", detail: "\(error)")
        }
    }

    /// Shared flag-diff applier used by both legacy full-window sync and
    /// CONDSTORE delta sync. Honors the optimistic-mutation cooldown so
    /// fresh local writes aren't overwritten by stale server state (bug 9.10).
    private func applyFlagUpdates(
        _ allFlags: [(uid: UInt32, flags: [Flag])],
        folderID: UUID
    ) async {
        var serverFlagMap: [UInt32: Set<String>] = [:]
        for (uid, flags) in allFlags {
            // RFC 3501: flag atoms are case-insensitive. `.description` lowercases
            // system flags but keeps custom keyword case ($Forwarded vs
            // $forwarded) — lowercase the whole set so keyword comparisons below
            // are case-insensitive (§10).
            serverFlagMap[uid] = Set(flags.map { $0.description.lowercased() })
        }

        // §12 (bug 9.10): snapshot the mutation timestamps as the LAST thing
        // before the write (no await between this and pool.write) and evaluate
        // the cooldown window inside the transaction against `Date()` at write
        // time. A pre-computed Set captured earlier could be stale by the time
        // the write lands, letting stale server flags overwrite a fresh local
        // mutation right at the 2s boundary.
        let mutationSnapshot = recentMutationStore
        do {
            try await pool.write { db in
                let writeNow = Date()
                let rows = try Row.fetchAll(db, sql: """
                    SELECT uid, id, is_read, is_flagged, is_answered, is_forwarded, is_draft
                    FROM messages WHERE folder_id = ?
                    """, arguments: [folderID])

                for row in rows {
                    let uid: UInt32 = row["uid"]
                    let msgID: UUID = row["id"]

                    if let mutatedAt = mutationSnapshot[msgID],
                       writeNow.timeIntervalSince(mutatedAt) < 2.0 { continue }
                    guard let flagStrs = serverFlagMap[uid] else { continue }

                    let localRead: Bool = row["is_read"]
                    let localFlagged: Bool = row["is_flagged"]
                    let localAnswered: Bool = row["is_answered"]
                    let localForwarded: Bool = row["is_forwarded"]
                    let localDraft: Bool = row["is_draft"]

                    let serverRead = flagStrs.contains("seen")
                    let serverFlag = flagStrs.contains("flagged")
                    let serverAns = flagStrs.contains("answered")
                    let serverFwd = flagStrs.contains("$forwarded")
                    let serverDft = flagStrs.contains("draft")

                    if localRead != serverRead || localFlagged != serverFlag
                        || localAnswered != serverAns || localForwarded != serverFwd
                        || localDraft != serverDft {
                        try db.execute(sql: """
                            UPDATE messages
                            SET is_read = ?, is_flagged = ?, is_answered = ?, is_forwarded = ?, is_draft = ?
                            WHERE id = ?
                            """, arguments: [serverRead, serverFlag, serverAns, serverFwd, serverDft, msgID])
                    }
                }
            }
        } catch {
            LogService.log(.warning, .sync, "Flag-update write failed", detail: "\(error)")
        }
    }

    // MARK: - Full resync (UIDVALIDITY changed)

    func fullResync(
        account: Account, folderID: UUID, folderPath: String,
        imap: IMAPService, selection: Mailbox.Selection
    ) async throws {

        let messageIDs: [UUID] = try await pool.read { db in
            try UUID.fetchAll(db, sql:
                "SELECT id FROM messages WHERE folder_id = ?",
                arguments: [folderID])
        }

        try await pool.write { db in
            try Message.filter(Column("folder_id") == folderID).deleteAll(db)
        }

        if !messageIDs.isEmpty {
            for msgID in messageIDs {
                let dir = attachmentsDirectory(accountID: account.id, messageID: msgID)
                try? FileManager.default.removeItem(at: dir)
            }
            LogService.log(.debug, .sync, "Purged attachments for \(messageIDs.count) messages")
        }

        // Thunderbird eager model: full rebuild fetches every envelope,
        // batched newest-first with per-chunk persist (see batchedInitialFetch).
        let saved = try await pool.read { db in
            try Folder.fetchOne(db, key: folderID)
        }
        let infos = try await batchedInitialFetch(
            account: account, folderID: folderID, folderPath: folderPath,
            imap: imap, total: UInt32(selection.messageCount),
            folder: saved
        )

        let hasMore: MoreMessages = .false
        let newHighest = infos.compactMap(\.uid).map(\.value).max() ?? 0

        try await updateFolderState(
            folderID: folderID, uidValidity: selection.uidValidity.value,
            uidNext: selection.uidNext.value, totalCount: selection.messageCount,
            highestKnownUid: newHighest, moreMessages: hasMore
        )
    }

    // MARK: - Persist headers from MessageInfo → GRDB

    func persistHeaders(
        _ infos: [MessageInfo], folderID: UUID, accountID: UUID
    ) async throws {
        guard !infos.isEmpty else { return }

        // Read existing rows with both UID and Message-ID keys. The Message-ID
        // map is used for pseudo-key reconciliation (Thunderbird parity):
        // `sameAccountMove` optimistically sets `folder_id = target` while
        // keeping the source UID, so the row is a placeholder. When the
        // server-assigned UID arrives here via delta FETCH, we rewrite the
        // placeholder in-place (UPDATE uid=<server>) instead of INSERTing a
        // duplicate — mirrors `GetMsgHdrForMessageID` path in
        // nsImapUndoTxn.cpp:380-410 for servers without UIDPLUS.
        struct ExistingRow { let id: UUID; let uid: UInt32 }
        let (existingByUID, existingByMessageID): ([UInt32: UUID], [String: ExistingRow]) =
            try await pool.read { db in
                let rows = try Row.fetchAll(db, sql:
                    "SELECT id, uid, message_id FROM messages WHERE folder_id = ?",
                    arguments: [folderID])
                var byUID: [UInt32: UUID] = [:]
                var byMID: [String: ExistingRow] = [:]
                for row in rows {
                    let id: UUID = row["id"]
                    let uid: UInt32 = row["uid"]
                    if uid > 0 { byUID[uid] = id }
                    if let mid: String = row["message_id"], !mid.isEmpty {
                        byMID[mid] = ExistingRow(id: id, uid: uid)
                    }
                }
                return (byUID, byMID)
            }

        // §12 (bug 9.10): snapshot mutation timestamps right before the write
        // and evaluate the cooldown inside the transaction against write-time
        // `Date()` — a Set captured earlier can go stale before the write lands.
        let mutationSnapshot = recentMutationStore

        // §11: dedup incoming infos by UID (keep last — most recent flags). A
        // server that emits two FETCH lines for the same UID in one batch would
        // otherwise trigger two INSERTs and a UNIQUE(folder_id,uid) violation
        // that rolls back the entire chunk transaction.
        var dedupedInfos: [MessageInfo] = []
        var seenUIDs: Set<UInt32> = []
        for info in infos.reversed() {
            guard let uid = info.uid?.value else { dedupedInfos.append(info); continue }
            if seenUIDs.insert(uid).inserted { dedupedInfos.append(info) }
        }
        dedupedInfos.reverse()

        try await pool.write { db in
            let writeNow = Date()
            func inCooldown(_ id: UUID) -> Bool {
                guard let at = mutationSnapshot[id] else { return false }
                return writeNow.timeIntervalSince(at) < 2.0
            }
            for info in dedupedInfos {
                guard let uid = info.uid else { continue }
                // RFC 3501 case-insensitive flags (§10) — lowercase the set.
                let flagStrs = Set(info.flags.map { $0.description.lowercased() })
                let isRead = flagStrs.contains("seen")
                let isFlagged = flagStrs.contains("flagged")
                let isAnswered = flagStrs.contains("answered")
                let isForwarded = flagStrs.contains("$forwarded")
                let isDraft = flagStrs.contains("draft")

                if let msgID = existingByUID[uid.value] {
                    if !inCooldown(msgID) {
                        try db.execute(sql: """
                            UPDATE messages
                            SET is_read = ?, is_flagged = ?, is_answered = ?, is_forwarded = ?, is_draft = ?
                            WHERE id = ?
                            """, arguments: [isRead, isFlagged, isAnswered, isForwarded, isDraft, msgID])
                    }
                    continue
                }

                // Pseudo-key reconciliation — same Message-ID already exists
                // in this folder under a different UID (optimistic MOVE
                // placeholder). Swap UID in place, no INSERT.
                if let incomingMID: String = info.messageId?.description,
                   !incomingMID.isEmpty,
                   let placeholder = existingByMessageID[incomingMID],
                   placeholder.uid != uid.value {
                    try db.execute(sql: """
                        UPDATE messages
                        SET uid = ?, is_read = ?, is_flagged = ?, is_answered = ?,
                            is_forwarded = ?, is_draft = ?
                        WHERE id = ?
                        """, arguments: [uid.value, isRead, isFlagged, isAnswered,
                                         isForwarded, isDraft, placeholder.id])
                    continue
                }

                let refs: [String] = info.references?.map(\.description) ?? []
                let msgDate: Date = info.internalDate ?? info.date ?? Date()
                let (parsedName, parsedAddr) = Self.parseFromAddress(info.from ?? "")
                let subj: String = Self.sanitizeSubject(info.subject)
                let msgID: String? = info.messageId?.description
                let replyTo: String? = info.inReplyTo?.description

                // Thunderbird parity: BODYSTRUCTURE is not fetched during
                // enumeration, so info.parts is always empty. We approximate
                // the paperclip flag from Content-Type in the fetched headers
                // (matches Thunderbird's best-effort behavior for unopened
                // messages). `loadFullMessage` later corrects this with the
                // accurate post-parse value when the user opens the message.
                let detectedAttachments = Self.hasAttachmentParts(info.parts)
                    || Self.hasAttachmentByContentType(info.additionalFields)

                // Thunderbird §7.5 persistent thread_id inheritance (P2-T2).
                let tid = try Self.computeThreadID(
                    db: db, accountID: accountID,
                    messageID: msgID, inReplyTo: replyTo, references: refs
                )

                // List-ID header for `list:` search operator (best-effort —
                // depends on server returning it in BODY[HEADER.FIELDS]).
                let listID = Self.extractListID(info.additionalFields)

                var msg = Message(
                    id: UUID(), uid: uid.value,
                    messageID: msgID, inReplyTo: replyTo,
                    references: refs, subject: subj,
                    fromName: parsedName, fromAddress: parsedAddr,
                    toAddresses: info.to, ccAddresses: info.cc,
                    bccAddresses: info.bcc, replyToAddresses: [],
                    date: msgDate, preview: "",
                    isRead: isRead, isFlagged: isFlagged,
                    isAnswered: isAnswered, isForwarded: isForwarded,
                    isDraft: isDraft,
                    size: info.size ?? 0, threadID: tid,
                    bodyText: nil, bodyHTML: nil, downloadState: .envelope,
                    hasAttachments: detectedAttachments,
                    listID: listID,
                    folderID: folderID, accountID: accountID
                )
                // §11: upsert on UNIQUE(folder_id, uid). A row may have appeared
                // since the pre-write snapshot (concurrent sync/IDLE path); a
                // plain INSERT would throw and roll back the whole chunk. Re-check
                // liveness inside the transaction and UPDATE flags in place when
                // the row already exists instead of inserting a duplicate.
                let liveID: UUID? = try UUID.fetchOne(db, sql:
                    "SELECT id FROM messages WHERE folder_id = ? AND uid = ?",
                    arguments: [folderID, uid.value])
                if liveID != nil {
                    try db.execute(sql: """
                        UPDATE messages
                        SET is_read = ?, is_flagged = ?, is_answered = ?,
                            is_forwarded = ?, is_draft = ?
                        WHERE folder_id = ? AND uid = ?
                        """, arguments: [isRead, isFlagged, isAnswered,
                                         isForwarded, isDraft, folderID, uid.value])
                } else {
                    try msg.insert(db)
                }
            }
        }
    }

    /// Detect attachments from BODYSTRUCTURE parts.
    nonisolated private static func hasAttachmentParts(_ parts: [SwiftMail.MessagePart]) -> Bool {
        parts.contains { part in
            if part.disposition?.lowercased() == "attachment" { return true }
            let mime = baseMimeType(part.contentType)
            if part.filename != nil && !mime.hasPrefix("text/") { return true }
            return false
        }
    }

    /// Heuristic attachment detection from Content-Type header when
    /// BODYSTRUCTURE is not fetched (Thunderbird-parity enumeration).
    /// `multipart/mixed` virtually always carries attachments; other
    /// multipart/* types (alternative, related, signed) typically do not.
    nonisolated private static func hasAttachmentByContentType(
        _ additionalFields: [String: String]?
    ) -> Bool {
        guard let fields = additionalFields else { return false }
        let value = fields.first(where: { $0.key.lowercased() == "content-type" })?.value
        guard let ct = value?.lowercased() else { return false }
        return ct.hasPrefix("multipart/mixed")
    }

    /// Extract List-ID from optional header dictionary, case-insensitive.
    /// Strips angle brackets and surrounding whitespace per RFC 2919.
    nonisolated static func extractListID(_ fields: [String: String]?) -> String? {
        guard let fields else { return nil }
        let keys = ["List-ID", "List-Id", "list-id", "LIST-ID", "List-Post", "list-post"]
        for key in keys {
            if let raw = fields[key] {
                return normalizeListID(raw)
            }
        }
        // Fallback: iterate case-insensitively.
        for (k, v) in fields where k.caseInsensitiveCompare("List-ID") == .orderedSame
            || k.caseInsensitiveCompare("List-Post") == .orderedSame {
            return normalizeListID(v)
        }
        return nil
    }

    nonisolated private static func normalizeListID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // "Foo List <foo.list.example.com>" → "foo.list.example.com"
        if let lt = trimmed.firstIndex(of: "<"), let gt = trimmed.firstIndex(of: ">"), lt < gt {
            let inner = trimmed[trimmed.index(after: lt)..<gt]
            let s = inner.trimmingCharacters(in: .whitespaces).lowercased()
            return s.isEmpty ? nil : s
        }
        return trimmed.lowercased()
    }

    /// Strip charset/parameters from Content-Type.
    nonisolated private static func baseMimeType(_ raw: String) -> String {
        raw.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? raw.lowercased()
    }

    nonisolated private static func parseFromAddress(_ raw: String) -> (name: String?, address: String) {
        guard let parsed = EmailAddress(raw) else { return (nil, raw) }
        return (parsed.name, parsed.address)
    }

    /// Strip leading/trailing whitespace and CR/LF that some MIME decoders
    /// leave at the end of Subject. A trailing `\n` breaks NSTextField
    /// vertical centering even with `maximumNumberOfLines = 1` because the
    /// intrinsic content height is computed for two lines.
    nonisolated static func sanitizeSubject(_ raw: String?) -> String {
        // §22: drop ALL control characters (CR, LF, and anything < 0x20), not
        // just leading/trailing whitespace. Inner CRLF smuggled via encoded-word
        // would otherwise reach the header verbatim (hidden Bcc / header split).
        let stripped = (raw ?? "").unicodeScalars.filter { $0.value >= 0x20 }
        return String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Thread-ID inheritance (Thunderbird §7.5, P2-T2)

    /// Compute persistent `thread_id` for a new message using 4-step lookup:
    /// 1) parent by In-Reply-To → inherit parent.thread_id (or parent.message_id if null)
    /// 2) ancestor by References chain (right→left) → same inheritance
    /// 3) self Message-ID → act as thread root
    /// 4) nil — malformed/legacy message without Message-ID
    /// Runs inside the caller's write transaction to avoid races.
    nonisolated static func computeThreadID(
        db: GRDB.Database,
        accountID: UUID,
        messageID: String?,
        inReplyTo: String?,
        references: [String]
    ) throws -> String? {
        // Step 1: parent by In-Reply-To
        if let parent = inReplyTo, !parent.isEmpty {
            if let tid = try lookupThreadID(db: db, accountID: accountID, messageID: parent) {
                return tid
            }
        }
        // Step 2: ancestors via References, closest-first (end → start)
        for ref in references.reversed() where !ref.isEmpty {
            if ref == inReplyTo { continue } // already tried
            if let tid = try lookupThreadID(db: db, accountID: accountID, messageID: ref) {
                return tid
            }
        }
        // Step 3: self as root
        if let mid = messageID, !mid.isEmpty {
            return mid
        }
        // Step 4: unknown
        return nil
    }

    /// Look up an ancestor by Message-ID within the account; return its
    /// `thread_id` (or its own `message_id` if thread_id is null — heals
    /// pre-existing roots). Returns nil if ancestor isn't stored yet.
    nonisolated private static func lookupThreadID(
        db: GRDB.Database,
        accountID: UUID,
        messageID: String
    ) throws -> String? {
        let row = try Row.fetchOne(db, sql: """
            SELECT thread_id, message_id FROM messages
            WHERE message_id = ? AND account_id = ?
            LIMIT 1
            """, arguments: [messageID, accountID])
        guard let row else { return nil }
        if let tid: String = row["thread_id"], !tid.isEmpty { return tid }
        if let mid: String = row["message_id"], !mid.isEmpty { return mid }
        return nil
    }

    // MARK: - Update folder state (expanded for Thunderbird fields)

    func updateFolderState(
        folderID: UUID, uidValidity: UInt32, uidNext: UInt32, totalCount: Int,
        highestKnownUid: UInt32? = nil, moreMessages: MoreMessages? = nil
    ) async throws {
        try await pool.write { db in
            var sql = """
                UPDATE folders SET uid_validity = ?, uid_next = ?, total_count = ?
                """
            var args: [DatabaseValueConvertible?] = [
                Int64(uidValidity), Int64(uidNext), totalCount
            ]

            if let hku = highestKnownUid {
                sql += ", highest_known_uid = ?"
                args.append(Int64(hku))
            }
            if let mm = moreMessages {
                sql += ", more_messages = ?"
                args.append(mm.rawValue)
            }
            sql += " WHERE id = ?"
            args.append(folderID)

            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
    }
}
