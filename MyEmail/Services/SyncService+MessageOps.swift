//
//  SyncService+MessageOps.swift
//  MyEmail
//
//  Optimistic UI message operations: mark read, flag, move, delete.
//  Pattern: mutate local DB → try IMAP → on failure → enqueue.
//  Cooldown 2 sec for flag mutations to prevent reconcile overwrite (§9.10).
//

import Foundation
import GRDB
import SwiftMail

extension SyncService {

    // MARK: - Move context

    struct MoveContext: Sendable {
        let targetFolder: Folder
        let targetAccount: Account
        let sourceFolder: Folder
        let sourceAccount: Account
        let messages: [Message]
        var isCrossAccount: Bool { sourceAccount.id != targetAccount.id }
    }

    // MARK: - Optimistic cooldown (§9.10)

    /// Recent flag mutations — reconcile skips FETCH FLAGS for these messages.
    var recentMutations: [UUID: Date] {
        get { recentMutationStore }
        set { recentMutationStore = newValue }
    }

    func isInCooldown(_ messageID: UUID) -> Bool {
        guard let date = recentMutationStore[messageID] else { return false }
        if Date().timeIntervalSince(date) < 2.0 { return true }
        recentMutationStore.removeValue(forKey: messageID)
        return false
    }

    /// §27: drop expired cooldown entries. `isInCooldown` only prunes the keys it
    /// happens to be asked about, so a bulk op (10k UUIDs) leaves 10k stale
    /// entries until restart. Called periodically from the sync timer.
    func pruneExpiredMutations() {
        let now = Date()
        recentMutationStore = recentMutationStore.filter { now.timeIntervalSince($0.value) < 2.0 }
    }

    // MARK: - Interaction score (notability for search ranking)

    /// Atomically bump interaction_score for one or more messages. Used by
    /// FTS5 bm25 ranking — frequently-touched conversations float up in search.
    func incrementInteractionScore(_ messageIDs: [UUID], delta: Int) async {
        guard !messageIDs.isEmpty, delta != 0 else { return }
        do {
            try await pool.write { db in
                let placeholders = messageIDs.map { _ in "?" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = [delta]
                args.append(contentsOf: messageIDs as [DatabaseValueConvertible])
                try db.execute(
                    sql: "UPDATE messages SET interaction_score = interaction_score + ? WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(args)
                )
            }
        } catch {
            LogService.log(.warning, .db, "Failed to bump interaction_score", detail: "\(error)")
        }
    }

    // MARK: - Mark Read / Unread

    func markAsRead(_ messageIDs: [UUID]) async {
        guard !messageIDs.isEmpty else { return }
        await executeOrQueue(messageIDs: messageIDs, flag: "is_read", value: true,
                             imapOp: { imap, uids in try await imap.markRead(uids: uids) },
                             actionType: .markRead)
        // Opening / marking read is a notability signal.
        await incrementInteractionScore(messageIDs, delta: 1)
    }

    func markAsUnread(_ messageIDs: [UUID]) async {
        guard !messageIDs.isEmpty else { return }
        await executeOrQueue(messageIDs: messageIDs, flag: "is_read", value: false,
                             imapOp: { imap, uids in try await imap.markUnread(uids: uids) },
                             actionType: .markUnread)
    }

    // MARK: - Flag / Unflag

    func setFlagged(_ messageIDs: [UUID], flagged: Bool) async {
        guard !messageIDs.isEmpty else { return }
        await executeOrQueue(messageIDs: messageIDs, flag: "is_flagged", value: flagged,
                             imapOp: { imap, uids in try await imap.setFlagged(flagged, uids: uids) },
                             actionType: flagged ? .flag : .unflag)
        // Flagging is a strong notability signal (higher than read).
        if flagged { await incrementInteractionScore(messageIDs, delta: 2) }
    }

    // MARK: - Move (batched, §9.1)

    func moveMessages(_ messageIDs: [UUID], to targetFolderID: UUID) async {
        guard !messageIDs.isEmpty else { return }

        let ctx: MoveContext? = try? await pool.read { db in
            guard let targetFolder = try Folder.fetchOne(db, key: targetFolderID),
                  let targetAccount = try Account.fetchOne(db, key: targetFolder.accountID) else { return nil }
            let messages = try Message
                .filter(messageIDs.contains(Column("id")))
                .fetchAll(db)
            guard let first = messages.first,
                  let sourceFolder = try Folder.fetchOne(db, key: first.folderID),
                  let sourceAccount = try Account.fetchOne(db, key: first.accountID) else { return nil }
            return MoveContext(
                targetFolder: targetFolder, targetAccount: targetAccount,
                sourceFolder: sourceFolder, sourceAccount: sourceAccount,
                messages: messages
            )
        }
        guard let ctx else { return }

        if ctx.isCrossAccount {
            await crossAccountMove(ctx: ctx, targetFolderID: targetFolderID)
        } else {
            await sameAccountMove(ctx: ctx, targetFolderID: targetFolderID)
        }
        // User-initiated move (drag/menu) is a notability signal.
        await incrementInteractionScore(messageIDs, delta: 1)
    }

    // MARK: - Same-account IMAP MOVE

    /// One source-folder's worth of messages moving to the same target.
    private struct MoveSourceGroup: Sendable {
        let sourceFolderID: UUID
        let sourceFolderPath: String
        let sourceUidValidity: UInt32?
        let messageIDs: [UUID]
        let uids: [UInt32]
    }

    private func sameAccountMove(ctx: MoveContext, targetFolderID: UUID) async {
        // §9.1: messages in a single move may originate from different source
        // folders (multi-select across a search result or the Unified Inbox).
        // Group by source folder so each MOVE SELECTs the right mailbox and
        // applies only that folder's UIDs — never the first folder's UIDs to
        // everyone (which would MOVE/lose foreign UIDs on the server).
        let groups: [MoveSourceGroup] = (try? await pool.read { db -> [MoveSourceGroup] in
            let bySource = Dictionary(grouping: ctx.messages, by: \.folderID)
            return try bySource.compactMap { folderID, msgs -> MoveSourceGroup? in
                guard let folder = try Folder.fetchOne(db, key: folderID) else { return nil }
                return MoveSourceGroup(
                    sourceFolderID: folderID,
                    sourceFolderPath: folder.path,
                    sourceUidValidity: folder.uidValidity,
                    messageIDs: msgs.map(\.id),
                    uids: msgs.map(\.uid)
                )
            }
        }) ?? []
        guard !groups.isEmpty else { return }

        // IDLE gate (§9.14): cover every source folder + target during bulk move
        let gatedFolderIDs = Set(groups.map(\.sourceFolderID)).union([targetFolderID])
        for fid in gatedFolderIDs { bulkOpFolderIDs.insert(fid) }
        defer {
            for fid in gatedFolderIDs { bulkOpFolderIDs.remove(fid) }
            Task { [weak self] in
                for fid in gatedFolderIDs { await self?.drainPendingIdleEvents(for: fid) }
            }
        }

        // Optimistic local update — all selected rows point at the target now.
        let allIDs = groups.flatMap(\.messageIDs)
        try? await pool.write { db in
            let placeholders = allIDs.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "UPDATE messages SET folder_id = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([targetFolderID] + allIDs)
            )
        }

        let account = ctx.sourceAccount
        let targetPath = ctx.targetFolder.path
        // §9.5: serialize the whole IMAP section on the per-account socket so a
        // concurrent sync/IDLE flow can't interleave SELECT A → SELECT B →
        // MOVE-in-B. NOT reentrant — only top-level entry points wrap.
        try? await runSerializedPerAccount(account.id) { [weak self] in
            guard let self else { return }
            let imap = self.getOrCreateIMAPService(for: account)
            for group in groups {
                do {
                    if await !imap.isConnected { try await imap.connect() }
                    _ = try await imap.selectFolder(group.sourceFolderPath)
                    try await imap.moveMessages(uids: group.uids, to: targetPath)
                } catch {
                    for uid in group.uids {
                        let action = PendingAction(
                            id: UUID(), type: .move, accountID: account.id,
                            sourceFolderPath: group.sourceFolderPath,
                            targetFolderPath: targetPath,
                            messageUID: uid, sourceUidValidity: group.sourceUidValidity,
                            payload: nil, status: .pending,
                            attemptCount: 0, lastError: nil, createdAt: Date()
                        )
                        try? await self.offlineQueue?.enqueue(action)
                    }
                    LogService.log(.warning, .sync, "Move queued for retry", detail: "\(error)")
                }
            }
        }

        // Thunderbird parity (nsImapUndoTxn.cpp:349-410): optimistic rows still
        // carry source UIDs under the target folder_id; resync target so server-
        // assigned UIDs arrive via QRESYNC/CONDSTORE and persistHeaders matches
        // them in place by Message-ID.
        Task { [weak self] in
            await self?.syncFolderIfNeeded(folderID: targetFolderID)
        }
    }

    // MARK: - Cross-account move (FETCH raw → APPEND → DELETE)

    private func crossAccountMove(ctx: MoveContext, targetFolderID: UUID) async {
        let sourceAccount = ctx.sourceAccount
        let targetAccount = ctx.targetAccount
        let sourcePath = ctx.sourceFolder.path
        let targetPath = ctx.targetFolder.path
        let sourceUidValidity = ctx.sourceFolder.uidValidity
        let messages = ctx.messages

        // §9.5: serialize source-account IMAP work on its socket so a concurrent
        // sync/IDLE flow can't interleave SELECT/DELETE on the source.
        try? await runSerializedPerAccount(sourceAccount.id) { [weak self] in
            guard let self else { return }
            let srcImap = self.getOrCreateIMAPService(for: sourceAccount)
            let dstImap = self.getOrCreateIMAPService(for: targetAccount)
            do {
                if await !srcImap.isConnected {
                    await self.wireTokenProvider(for: sourceAccount, imap: srcImap)
                    try await srcImap.connect()
                }
                if await !dstImap.isConnected {
                    await self.wireTokenProvider(for: targetAccount, imap: dstImap)
                    try await dstImap.connect()
                }
                _ = try await srcImap.selectFolder(sourcePath)

                for msg in messages {
                    // Phase 1 — copy to target (FETCH + APPEND). On failure
                    // nothing reached the target: leave the source untouched and
                    // skip (queuing `.move` would replay as a same-account MOVE
                    // on the source into a foreign path).
                    do {
                        let rawData = try await srcImap.fetchRawMessage(uid: msg.uid)
                        var flags: [Flag] = []  // preserve all RFC 3501 + keyword flags
                        if msg.isRead { flags.append(.seen) }
                        if msg.isFlagged { flags.append(.flagged) }
                        if msg.isAnswered { flags.append(.answered) }
                        if msg.isDraft { flags.append(.draft) }
                        if msg.isForwarded { flags.append(.custom("$Forwarded")) }

                        // APPEND to destination as exact bytes (8-bit safe).
                        try await dstImap.appendRawData(
                            rawData, to: targetPath, flags: flags, date: msg.date
                        )
                    } catch {
                        LogService.log(.warning, .sync,
                            "Cross-account move: copy failed, left in place",
                            detail: "uid=\(msg.uid) \(error)")
                        continue
                    }

                    // Phase 2 — APPEND confirmed; only the source delete remains.
                    // Queue `.delete` (NOT `.move`: re-APPEND would duplicate the
                    // target). Idempotent on the source; local row dropped
                    // optimistically, reconcile missing-recovery covers a
                    // permanent delete failure.
                    do {
                        try await srcImap.deleteMessages(uids: [msg.uid])
                    } catch {
                        let action = PendingAction(
                            id: UUID(), type: .delete, accountID: sourceAccount.id,
                            sourceFolderPath: sourcePath, targetFolderPath: nil,
                            messageUID: msg.uid, sourceUidValidity: sourceUidValidity,
                            payload: nil, status: .pending,
                            attemptCount: 0, lastError: nil, createdAt: Date()
                        )
                        try? await self.offlineQueue?.enqueue(action)
                        LogService.log(.warning, .sync,
                            "Cross-account move: source delete queued",
                            detail: "uid=\(msg.uid) \(error)")
                    }

                    // Local cleanup (optimistic — the copy is in target).
                    try? await self.pool.write { db in
                        try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [msg.id])
                    }
                }

                LogService.log(.info, .sync, "Cross-account move: \(messages.count) messages",
                               detail: "\(sourceAccount.email) → \(targetAccount.email)")
            } catch {
                LogService.log(.error, .sync, "Cross-account move failed", detail: "\(error)")
            }
        }
    }

    // MARK: - Delete (MOVE → Trash; permanent only via expungeMessages)

    /// Move messages to their account's Trash folder. Reversible via the
    /// Undo stack and recoverable by user from the Trash folder itself.
    /// Messages already located in Trash are expunged (permanent) instead;
    /// accounts without a Trash special-use folder also fall back to expunge.
    func deleteMessages(_ messageIDs: [UUID]) async {
        guard !messageIDs.isEmpty else { return }

        struct Plan: Sendable {
            let toMove: [UUID: UUID]   // messageID → trash folder UUID
            let toExpunge: [UUID]
        }

        let plan: Plan? = try? await pool.read { db in
            let messages = try Message
                .filter(messageIDs.contains(Column("id")))
                .fetchAll(db)

            var toMove: [UUID: UUID] = [:]
            var toExpunge: [UUID] = []
            // Cache Trash lookup per account.
            var trashByAccount: [UUID: Folder?] = [:]
            for msg in messages {
                let trash = try trashByAccount[msg.accountID]
                    ?? Folder
                        .filter(Column("account_id") == msg.accountID)
                        .filter(Column("special_use") == SpecialUse.trash)
                        .fetchOne(db)
                trashByAccount[msg.accountID] = trash
                if let trash, trash.id != msg.folderID {
                    toMove[msg.id] = trash.id
                } else {
                    // Already in Trash, or account has no Trash folder.
                    toExpunge.append(msg.id)
                }
            }
            return Plan(toMove: toMove, toExpunge: toExpunge)
        }

        guard let plan else { return }

        // Group MOVE candidates by target Trash folder to batch per folder.
        let byTrash = Dictionary(grouping: plan.toMove.keys, by: { plan.toMove[$0]! })
        for (trashID, ids) in byTrash {
            await moveMessages(ids, to: trashID)
        }
        if !plan.toExpunge.isEmpty {
            await expungeMessages(plan.toExpunge)
        }
    }

    /// Permanent server-side delete: `STORE +FLAGS \Deleted` + `EXPUNGE`.
    /// Cannot be undone. Reserved for messages already in Trash or accounts
    /// with no Trash folder; the higher-level Delete flow goes through
    /// `deleteMessages` which prefers MOVE → Trash.
    func expungeMessages(_ messageIDs: [UUID]) async {
        guard !messageIDs.isEmpty else { return }

        // §9.1: a selection can span folders/accounts — group so each EXPUNGE
        // SELECTs the right mailbox and only deletes that folder's UIDs.
        struct ExpungeGroup: Sendable {
            let accountID: UUID
            let folderID: UUID
            let folderPath: String
            let uidValidity: UInt32?
            let messageIDs: [UUID]
            let uids: [UInt32]
        }

        let groups: [ExpungeGroup] = (try? await pool.read { db -> [ExpungeGroup] in
            let messages = try Message
                .filter(messageIDs.contains(Column("id")))
                .fetchAll(db)
            let byFolder = Dictionary(grouping: messages, by: \.folderID)
            return try byFolder.compactMap { folderID, msgs -> ExpungeGroup? in
                guard let folder = try Folder.fetchOne(db, key: folderID),
                      let first = msgs.first else { return nil }
                return ExpungeGroup(
                    accountID: first.accountID, folderID: folderID,
                    folderPath: folder.path, uidValidity: folder.uidValidity,
                    messageIDs: msgs.map(\.id), uids: msgs.map(\.uid)
                )
            }
        }) ?? []
        guard !groups.isEmpty else { return }

        // IDLE gate (§9.14): cover every affected folder.
        let gatedFolderIDs = Set(groups.map(\.folderID))
        for fid in gatedFolderIDs { bulkOpFolderIDs.insert(fid) }
        defer {
            for fid in gatedFolderIDs { bulkOpFolderIDs.remove(fid) }
            Task { [weak self] in
                for fid in gatedFolderIDs { await self?.drainPendingIdleEvents(for: fid) }
            }
        }

        // Optimistic: drop locally (all groups at once).
        try? await pool.write { db in
            try Message.filter(messageIDs.contains(Column("id"))).deleteAll(db)
        }

        // Group by account so the IMAP section is serialized per-account socket.
        let byAccount = Dictionary(grouping: groups, by: \.accountID)
        for (accountID, accountGroups) in byAccount {
            guard let account = try? await pool.read({ db in
                try Account.fetchOne(db, key: accountID)
            }) else { continue }
            try? await runSerializedPerAccount(accountID) { [weak self] in
                guard let self else { return }
                let imap = self.getOrCreateIMAPService(for: account)
                for group in accountGroups {
                    do {
                        if await !imap.isConnected { try await imap.connect() }
                        _ = try await imap.selectFolder(group.folderPath)
                        try await imap.deleteMessages(uids: group.uids)
                    } catch {
                        for uid in group.uids {
                            let action = PendingAction(
                                id: UUID(), type: .delete, accountID: accountID,
                                sourceFolderPath: group.folderPath, targetFolderPath: nil,
                                messageUID: uid, sourceUidValidity: group.uidValidity,
                                payload: nil, status: .pending,
                                attemptCount: 0, lastError: nil, createdAt: Date()
                            )
                            try? await self.offlineQueue?.enqueue(action)
                        }
                        LogService.log(.warning, .sync, "Expunge queued for retry", detail: "\(error)")
                    }
                }
            }
        }
    }

    // MARK: - Archive (M11, batched move with auto-create)

    struct ArchiveEntry: Sendable {
        let accountID: UUID
        let sourceFolderPath: String
        let uid: UInt32
        let date: Date
        let messageID: UUID
    }

    struct ArchiveAccountContext: Sendable {
        let account: Account
        let separator: String
        let existingPaths: Set<String>
        let entries: [ArchiveEntry]
    }

    func archiveMessages(_ messageIDs: [UUID]) async {
        guard !messageIDs.isEmpty else { return }
        LogService.log(.info, .sync, "Archive requested", detail: "\(messageIDs.count) message(s)")

        let accountContexts: [ArchiveAccountContext] = (try? await pool.read { db in
            let messages = try Message
                .filter(messageIDs.contains(Column("id")))
                .fetchAll(db)
            let folderIDs = Set(messages.map(\.folderID))
            let folders = try Folder.filter(folderIDs.contains(Column("id"))).fetchAll(db)
            let folderByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })

            // Group entries by accountID
            var byAccount: [UUID: [ArchiveEntry]] = [:]
            for msg in messages {
                guard let folder = folderByID[msg.folderID] else { continue }
                byAccount[msg.accountID, default: []].append(ArchiveEntry(
                    accountID: msg.accountID,
                    sourceFolderPath: folder.path,
                    uid: msg.uid,
                    date: msg.date,
                    messageID: msg.id
                ))
            }

            // Build per-account context with account, separator, existing paths
            return try byAccount.compactMap { accountID, entries -> ArchiveAccountContext? in
                guard let account = try Account.fetchOne(db, key: accountID) else { return nil }
                let sep = try String.fetchOne(db, sql:
                    "SELECT separator FROM folders WHERE account_id = ? LIMIT 1",
                    arguments: [accountID]) ?? "/"
                let paths = try String.fetchSet(db, sql:
                    "SELECT path FROM folders WHERE account_id = ?",
                    arguments: [accountID])
                return ArchiveAccountContext(
                    account: account, separator: sep,
                    existingPaths: paths, entries: entries
                )
            }
        }) ?? []

        guard !accountContexts.isEmpty else {
            LogService.log(.warning, .sync, "Archive: no resolvable accounts for selection",
                           detail: "\(messageIDs.count) id(s)")
            return
        }

        // Collect all source folder IDs for IDLE gate (§9.14)
        let allSourceFolderIDs: Set<UUID> = Set(
            (try? await pool.read { db in
                let messages = try Message
                    .filter(messageIDs.contains(Column("id")))
                    .fetchAll(db)
                return Array(Set(messages.map(\.folderID)))
            }) ?? []
        )
        for fid in allSourceFolderIDs { bulkOpFolderIDs.insert(fid) }
        defer {
            for fid in allSourceFolderIDs { bulkOpFolderIDs.remove(fid) }
            Task { [weak self] in
                for fid in allSourceFolderIDs {
                    await self?.drainPendingIdleEvents(for: fid)
                }
            }
        }

        for ctx in accountContexts {
            await archiveAccount(ctx: ctx)
        }
    }

    /// Archive one account's entries. Optimistic local delete already done by
    /// the IDLE-gate setup in `archiveMessages`. §9.5: IMAP section runs under
    /// the per-account serial lock.
    private func archiveAccount(ctx: ArchiveAccountContext) async {
        let account = ctx.account
        await wireTokenProvider(for: account, imap: getOrCreateIMAPService(for: account))

        // Optimistic local delete BEFORE network — UI reflects archive instantly.
        let allMsgIDs = ctx.entries.map(\.messageID)
        _ = try? await pool.write { db in
            try Message.filter(allMsgIDs.contains(Column("id"))).deleteAll(db)
        }

        // §7: pre-resolve the DB archive special-use path for the SwiftMail
        // auto-resolve case so a failed archive never queues a MOVE to "".
        var archiveSpecialPath: String?
        if account.archiveRootPath == nil {
            archiveSpecialPath = try? await pool.read { db in
                try String.fetchOne(db, sql:
                    "SELECT path FROM folders WHERE account_id = ? AND special_use = ? LIMIT 1",
                    arguments: [account.id, SpecialUse.archive.rawValue])
            }
        }

        try? await runSerializedPerAccount(account.id) { [weak self] in
            guard let self else { return }
            let imap = self.getOrCreateIMAPService(for: account)
            do {
                if await !imap.isConnected { try await imap.connect() }
                if let archiveRoot = account.archiveRootPath {
                    try await self.archiveWithSubdivision(
                        ctx: ctx, archiveRoot: archiveRoot, imap: imap
                    )
                } else {
                    // No explicit path — SwiftMail resolves via SPECIAL-USE
                    // \Archive or name fallback (e.g. [Gmail]/All Mail).
                    try await self.archiveViaSwiftMail(ctx: ctx, imap: imap)
                }
                try await self.syncFolders(account: account, imap: imap)
                LogService.log(.info, .sync, "Archive complete",
                               detail: "\(account.email): \(allMsgIDs.count) message(s)")
            } catch {
                await self.enqueueArchiveRetry(
                    ctx: ctx, archiveSpecialPath: archiveSpecialPath, error: error
                )
            }
        }
    }

    /// Enqueue per-entry archive retries with a concrete, non-empty target path
    /// resolved at enqueue time (§7). Entries with no resolvable target are
    /// dropped with an error log rather than queuing a destructive MOVE to "".
    private func enqueueArchiveRetry(
        ctx: ArchiveAccountContext, archiveSpecialPath: String?, error: Error
    ) async {
        let account = ctx.account
        let uidValidityByPath: [String: UInt32] = (try? await pool.read { db in
            let paths = Set(ctx.entries.map(\.sourceFolderPath))
            var map: [String: UInt32] = [:]
            for path in paths {
                if let uv = try UInt32.fetchOne(db, sql:
                    "SELECT uid_validity FROM folders WHERE account_id = ? AND path = ?",
                    arguments: [account.id, path]) {
                    map[path] = uv
                }
            }
            return map
        }) ?? [:]

        for entry in ctx.entries {
            let target: String?
            if let root = account.archiveRootPath {
                let subdivision: ArchiveSubdivision = root.hasPrefix("[Gmail]")
                    ? .flat : account.archiveSubdivision
                target = subdivision.targetPath(
                    for: entry.date, root: root, separator: ctx.separator
                )
            } else {
                target = archiveSpecialPath
            }
            guard let target, !target.isEmpty else {
                LogService.log(.error, .sync,
                    "Archive retry not queued — no resolvable target",
                    detail: "\(account.email) uid=\(entry.uid)")
                continue
            }
            let action = PendingAction(
                id: UUID(), type: .archive, accountID: account.id,
                sourceFolderPath: entry.sourceFolderPath,
                targetFolderPath: target,
                messageUID: entry.uid,
                sourceUidValidity: uidValidityByPath[entry.sourceFolderPath],
                payload: nil, status: .pending, attemptCount: 0,
                lastError: nil, createdAt: Date()
            )
            try? await offlineQueue?.enqueue(action)
        }
        LogService.log(.warning, .sync, "Archive queued for retry", detail: "\(error)")
    }

    /// Archive using SwiftMail's built-in archive() — resolves folder automatically.
    /// Local DB rows are already deleted by the caller (`archiveMessages`) for
    /// instant UI feedback, so this only performs server-side IMAP work.
    private func archiveViaSwiftMail(
        ctx: ArchiveAccountContext, imap: IMAPService
    ) async throws {
        let bySource = Dictionary(grouping: ctx.entries, by: \.sourceFolderPath)
        for (sourcePath, entries) in bySource {
            _ = try await imap.selectFolder(sourcePath)
            let uids = entries.map(\.uid)
            try await imap.archiveMessages(uids: uids)
        }
    }

    /// Archive with year/month subdivision folders and auto-create.
    private func archiveWithSubdivision(
        ctx: ArchiveAccountContext, archiveRoot: String, imap: IMAPService
    ) async throws {
        let isGmailAllMail = archiveRoot.hasPrefix("[Gmail]")
        let subdivision: ArchiveSubdivision = isGmailAllMail
            ? .flat : ctx.account.archiveSubdivision

        struct MoveItem { let uid: UInt32; let messageID: UUID; let targetPath: String }
        var bySource: [String: [MoveItem]] = [:]
        var allTargetPaths: Set<String> = []

        for entry in ctx.entries {
            let target = subdivision.targetPath(
                for: entry.date, root: archiveRoot, separator: ctx.separator
            )
            allTargetPaths.insert(target)
            bySource[entry.sourceFolderPath, default: []].append(
                MoveItem(uid: entry.uid, messageID: entry.messageID, targetPath: target)
            )
        }

        // Auto-create missing archive subfolders
        for targetPath in allTargetPaths where !ctx.existingPaths.contains(targetPath) {
            do {
                try await imap.createFolder(path: targetPath)
                LogService.log(.info, .imap, "Created archive folder: \(targetPath)")
            } catch {
                LogService.log(.debug, .imap, "CREATE \(targetPath): \(error)")
            }
        }

        // Move grouped by source (one SELECT per source folder).
        // Local DB rows are already deleted by the caller.
        for (sourcePath, moveItems) in bySource {
            _ = try await imap.selectFolder(sourcePath)
            let byTarget = Dictionary(grouping: moveItems, by: \.targetPath)
            for (targetPath, items) in byTarget {
                let uids = items.map(\.uid)
                try await imap.moveMessages(uids: uids, to: targetPath)
            }
        }
    }

    // MARK: - Core: executeOrQueue for flag operations

    private struct FlagGroup: Sendable {
        let accountID: UUID
        let folderPath: String
        let uidValidity: UInt32?
        let uids: [UInt32]
    }

    private func executeOrQueue(
        messageIDs: [UUID],
        flag: String,
        value: Bool,
        imapOp: @escaping @Sendable (IMAPService, [UInt32]) async throws -> Void,
        actionType: PendingActionType
    ) async {
        // Optimistic local mutation + cooldown (per-message, all folders).
        for id in messageIDs { recentMutationStore[id] = Date() }

        try? await pool.write { db in
            try db.execute(sql: """
                UPDATE messages SET \(flag) = ?
                WHERE id IN (\(messageIDs.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments([value] + messageIDs))
        }

        // §9.1: group UIDs by (account, folder) so STORE targets the right
        // mailbox — never the first message's folder for the whole selection.
        let groups: [FlagGroup] = (try? await pool.read { db -> [FlagGroup] in
            let messages = try Message
                .filter(messageIDs.contains(Column("id")))
                .fetchAll(db)
            let byFolder = Dictionary(grouping: messages, by: \.folderID)
            return try byFolder.compactMap { folderID, msgs -> FlagGroup? in
                guard let folder = try Folder.fetchOne(db, key: folderID),
                      let first = msgs.first else { return nil }
                return FlagGroup(
                    accountID: first.accountID, folderPath: folder.path,
                    uidValidity: folder.uidValidity, uids: msgs.map(\.uid)
                )
            }
        }) ?? []
        guard !groups.isEmpty else { return }

        let byAccount = Dictionary(grouping: groups, by: \.accountID)
        for (accountID, accountGroups) in byAccount {
            guard let account = try? await pool.read({ db in
                try Account.fetchOne(db, key: accountID)
            }) else { continue }
            // §9.5: serialize STORE on the per-account socket.
            try? await runSerializedPerAccount(accountID) { [weak self] in
                guard let self else { return }
                let imap = self.getOrCreateIMAPService(for: account)
                for group in accountGroups {
                    do {
                        if await !imap.isConnected { try await imap.connect() }
                        _ = try await imap.selectFolder(group.folderPath)
                        try await imapOp(imap, group.uids)
                    } catch {
                        for uid in group.uids {
                            let action = PendingAction(
                                id: UUID(), type: actionType, accountID: accountID,
                                sourceFolderPath: group.folderPath, targetFolderPath: nil,
                                messageUID: uid, sourceUidValidity: group.uidValidity,
                                payload: nil, status: .pending,
                                attemptCount: 0, lastError: nil, createdAt: Date()
                            )
                            try? await self.offlineQueue?.enqueue(action)
                        }
                        LogService.log(.warning, .sync, "\(actionType.rawValue) queued", detail: "\(error)")
                    }
                }
            }
        }
    }

    // MARK: - Mark as Junk (move to Junk folder, multi-account safe)

    func markAsJunk(_ messageIDs: [UUID]) async {
        guard !messageIDs.isEmpty else { return }

        // Group messages by account → junk folder
        let groups: [(junkFolderID: UUID, messageIDs: [UUID])]? = try? await pool.read { db in
            let messages = try Message
                .filter(messageIDs.contains(Column("id")))
                .fetchAll(db)

            var byAccount: [UUID: [UUID]] = [:]
            for msg in messages {
                byAccount[msg.accountID, default: []].append(msg.id)
            }

            return try byAccount.compactMap { accountID, msgIDs -> (UUID, [UUID])? in
                guard let junk = try Folder
                    .filter(Column("account_id") == accountID)
                    .filter(Column("special_use") == SpecialUse.junk)
                    .fetchOne(db)
                else { return nil }
                return (junk.id, msgIDs)
            }
        }

        guard let groups, !groups.isEmpty else {
            LogService.log(.warning, .sync, "No Junk folder found for messages")
            return
        }

        for group in groups {
            await moveMessages(group.messageIDs, to: group.junkFolderID)
        }
    }
}
