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

    private func sameAccountMove(ctx: MoveContext, targetFolderID: UUID) async {
        let uids = ctx.messages.map(\.uid)

        // IDLE gate (§9.14): prevent IDLE reconcile during bulk move
        let sourceFolderID = ctx.sourceFolder.id
        bulkOpFolderIDs.insert(sourceFolderID)
        bulkOpFolderIDs.insert(targetFolderID)
        defer {
            bulkOpFolderIDs.remove(sourceFolderID)
            bulkOpFolderIDs.remove(targetFolderID)
            Task { [weak self] in
                await self?.drainPendingIdleEvents(for: sourceFolderID)
                await self?.drainPendingIdleEvents(for: targetFolderID)
            }
        }

        // Optimistic local update
        let ids = ctx.messages.map(\.id)
        try? await pool.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "UPDATE messages SET folder_id = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([targetFolderID] + ids)
            )
        }

        let imap = getOrCreateIMAPService(for: ctx.sourceAccount)
        do {
            if await !imap.isConnected { try await imap.connect() }
            _ = try await imap.selectFolder(ctx.sourceFolder.path)
            try await imap.moveMessages(uids: uids, to: ctx.targetFolder.path)

            // Thunderbird parity (nsImapUndoTxn.cpp:349-410): after a successful
            // MOVE the optimistic rows still carry source-folder UIDs under the
            // target folder_id. Kick a target-folder resync so the server-
            // assigned UIDs come in via QRESYNC/CONDSTORE delta; persistHeaders
            // reconciles them in place via Message-ID. Without this, the
            // placeholder UIDs survive until the next lazy select.
            Task { [weak self] in
                await self?.syncFolderIfNeeded(folderID: targetFolderID)
            }
        } catch {
            for uid in uids {
                let action = PendingAction(
                    id: UUID(), type: .move, accountID: ctx.sourceAccount.id,
                    sourceFolderPath: ctx.sourceFolder.path,
                    targetFolderPath: ctx.targetFolder.path,
                    messageUID: uid, sourceUidValidity: ctx.sourceFolder.uidValidity,
                    payload: nil, status: .pending,
                    attemptCount: 0, lastError: nil, createdAt: Date()
                )
                try? await offlineQueue?.enqueue(action)
            }
            LogService.log(.warning, .sync, "Move queued for retry", detail: "\(error)")
        }
    }

    // MARK: - Cross-account move (FETCH raw → APPEND → DELETE)

    private func crossAccountMove(ctx: MoveContext, targetFolderID: UUID) async {
        let srcImap = getOrCreateIMAPService(for: ctx.sourceAccount)
        let dstImap = getOrCreateIMAPService(for: ctx.targetAccount)

        do {
            if await !srcImap.isConnected {
                await wireTokenProvider(for: ctx.sourceAccount, imap: srcImap)
                try await srcImap.connect()
            }
            if await !dstImap.isConnected {
                await wireTokenProvider(for: ctx.targetAccount, imap: dstImap)
                try await dstImap.connect()
            }
            _ = try await srcImap.selectFolder(ctx.sourceFolder.path)

            for msg in ctx.messages {
                // 1. FETCH raw
                let rawData = try await srcImap.fetchRawMessage(uid: msg.uid)
                guard let raw = String(data: rawData, encoding: .utf8)
                        ?? String(data: rawData, encoding: .ascii) else { continue }

                // 2. Build flags (preserve all RFC 3501 + keyword flags)
                var flags: [Flag] = []
                if msg.isRead { flags.append(.seen) }
                if msg.isFlagged { flags.append(.flagged) }
                if msg.isAnswered { flags.append(.answered) }
                if msg.isDraft { flags.append(.draft) }
                if msg.isForwarded { flags.append(.custom("$Forwarded")) }

                // 3. APPEND to destination
                try await dstImap.appendRawMessage(
                    raw, to: ctx.targetFolder.path, flags: flags, date: msg.date
                )

                // 4. DELETE from source
                try await srcImap.deleteMessages(uids: [msg.uid])

                // 5. Local cleanup
                try? await pool.write { db in
                    try db.execute(
                        sql: "DELETE FROM messages WHERE id = ?",
                        arguments: [msg.id]
                    )
                }
            }

            LogService.log(.info, .sync, "Cross-account move: \(ctx.messages.count) messages",
                           detail: "\(ctx.sourceAccount.email) → \(ctx.targetAccount.email)")
        } catch {
            LogService.log(.error, .sync, "Cross-account move failed", detail: "\(error)")
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

        let context = try? await pool.read { db -> (UUID, String, UUID, [UInt32], UInt32?)? in
            let messages = try Message
                .filter(messageIDs.contains(Column("id")))
                .fetchAll(db)
            guard let first = messages.first,
                  let folder = try Folder.fetchOne(db, key: first.folderID) else { return nil }
            return (folder.id, folder.path, first.accountID, messages.map(\.uid), folder.uidValidity)
        }

        guard let (folderID, folderPath, accountID, uids, uidValidity) = context else { return }

        // IDLE gate (§9.14): prevent IDLE reconcile during bulk expunge
        bulkOpFolderIDs.insert(folderID)
        defer {
            bulkOpFolderIDs.remove(folderID)
            Task { [weak self] in
                await self?.drainPendingIdleEvents(for: folderID)
            }
        }

        // Optimistic: drop locally
        try? await pool.write { db in
            try Message.filter(messageIDs.contains(Column("id"))).deleteAll(db)
        }

        guard let account = try? await pool.read({ db in try Account.fetchOne(db, key: accountID) }) else { return }
        let imap = getOrCreateIMAPService(for: account)

        do {
            if await !imap.isConnected { try await imap.connect() }
            _ = try await imap.selectFolder(folderPath)
            try await imap.deleteMessages(uids: uids)
        } catch {
            for uid in uids {
                let action = PendingAction(
                    id: UUID(), type: .delete, accountID: accountID,
                    sourceFolderPath: folderPath, targetFolderPath: nil,
                    messageUID: uid, sourceUidValidity: uidValidity,
                    payload: nil, status: .pending,
                    attemptCount: 0, lastError: nil, createdAt: Date()
                )
                try? await offlineQueue?.enqueue(action)
            }
            LogService.log(.warning, .sync, "Expunge queued for retry", detail: "\(error)")
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
            return try byAccount.compactMap { (accountID, entries) -> ArchiveAccountContext? in
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
            let account = ctx.account
            let imap = getOrCreateIMAPService(for: account)
            await wireTokenProvider(for: account, imap: imap)

            // Optimistic local delete BEFORE network — UI reflects archive instantly.
            // IMAP operations below will either finish the server-side move, or
            // enqueue a retry in the offline queue if they fail.
            let allMsgIDs = ctx.entries.map(\.messageID)
            _ = try? await pool.write { db in
                try Message.filter(allMsgIDs.contains(Column("id"))).deleteAll(db)
            }

            do {
                if await !imap.isConnected { try await imap.connect() }

                if let archiveRoot = account.archiveRootPath {
                    // Explicit archive path configured — use subdivision logic
                    try await archiveWithSubdivision(
                        ctx: ctx, archiveRoot: archiveRoot, imap: imap
                    )
                } else {
                    // No explicit path — delegate to SwiftMail's built-in archive
                    // (resolves via SPECIAL-USE \Archive or name fallback e.g. [Gmail]/All Mail)
                    try await archiveViaSwiftMail(ctx: ctx, imap: imap)
                }

                try await syncFolders(account: account, imap: imap)
                LogService.log(.info, .sync, "Archive complete",
                               detail: "\(account.email): \(allMsgIDs.count) message(s)")
            } catch {
                // Look up uidValidity per source folder for offline queue
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
                    let target = account.archiveRootPath ?? ""
                    let action = PendingAction(
                        id: UUID(), type: .archive, accountID: account.id,
                        sourceFolderPath: entry.sourceFolderPath,
                        targetFolderPath: target,
                        messageUID: entry.uid,
                        sourceUidValidity: uidValidityByPath[entry.sourceFolderPath],
                        payload: nil,
                        status: .pending, attemptCount: 0,
                        lastError: nil, createdAt: Date()
                    )
                    try? await offlineQueue?.enqueue(action)
                }
                LogService.log(.warning, .sync,
                    "Archive queued for retry", detail: "\(error)")
            }
        }
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

    private func executeOrQueue(
        messageIDs: [UUID],
        flag: String,
        value: Bool,
        imapOp: (IMAPService, [UInt32]) async throws -> Void,
        actionType: PendingActionType
    ) async {
        // Optimistic local mutation + cooldown
        for id in messageIDs { recentMutationStore[id] = Date() }

        try? await pool.write { db in
            try db.execute(sql: """
                UPDATE messages SET \(flag) = ?
                WHERE id IN (\(messageIDs.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments([value] + messageIDs))
        }

        // Resolve UIDs + account + uidValidity
        let context = try? await pool.read { db -> ([UInt32], UUID, String, UInt32?)? in
            let messages = try Message
                .filter(messageIDs.contains(Column("id")))
                .fetchAll(db)
            guard let first = messages.first,
                  let folder = try Folder.fetchOne(db, key: first.folderID) else { return nil }
            return (messages.map(\.uid), first.accountID, folder.path, folder.uidValidity)
        }

        guard let (uids, accountID, folderPath, uidValidity) = context else { return }
        guard let account = try? await pool.read({ db in try Account.fetchOne(db, key: accountID) }) else { return }

        let imap = getOrCreateIMAPService(for: account)

        do {
            if await !imap.isConnected { try await imap.connect() }
            _ = try await imap.selectFolder(folderPath)
            try await imapOp(imap, uids)
        } catch {
            for uid in uids {
                let action = PendingAction(
                    id: UUID(), type: actionType, accountID: accountID,
                    sourceFolderPath: folderPath, targetFolderPath: nil,
                    messageUID: uid, sourceUidValidity: uidValidity,
                    payload: nil, status: .pending,
                    attemptCount: 0, lastError: nil, createdAt: Date()
                )
                try? await offlineQueue?.enqueue(action)
            }
            LogService.log(.warning, .sync, "\(actionType.rawValue) queued", detail: "\(error)")
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
