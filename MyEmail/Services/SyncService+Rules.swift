//
//  SyncService+Rules.swift
//  MyEmail
//
//  Apply mail rules to newly synced messages (§6.7.1).
//  Rules evaluated after persistHeaders, not after reconcile.
//
//  Execution flow: planActions (SyncService+RulesPlan.swift) merges all actions
//  of one rule into an ExecutionPlan — then we do flags → rewriteSubject (APPEND
//  directly into the final target) → final disposition (move/delete). This
//  avoids bouncing messages through INBOX when a rule combines rewriteSubject
//  with moveToFolder/markJunk.
//

import Foundation
import GRDB
import SwiftMail

extension SyncService {

    // Tombstones older than this are ignored (and opportunistically pruned).
    // 1h covers any realistic target-folder sync latency while preventing
    // perpetual rule-suppression.
    static let ruleMoveTombstoneTTL: TimeInterval = 3600

    // MARK: - Apply rules to new messages (§6.7.1)

    /// Fetch newly inserted MessageListItems by UIDs, evaluate rules, execute actions.
    /// Takes a full `Folder` so RuleEngine can filter by scope — callers that
    /// only have `folderID` should `Folder.fetchOne` first, so we avoid an
    /// extra DB roundtrip per call.
    func applyRulesToNewMessages(
        _ infos: [MessageInfo], folder: Folder, accountID: UUID
    ) async {
        guard let engine = ruleEngine else { return }

        let anyEnabled: Bool = (try? await pool.read { db in
            try MailRule.filter(Column("is_enabled") == true).fetchCount(db) > 0
        }) ?? false
        guard anyEnabled else { return }

        let newUIDs: [UInt32] = infos.compactMap { $0.uid?.value }
        guard !newUIDs.isEmpty else { return }

        let folderID = folder.id

        // Fetch new items and filter out moved messages:
        //   (a) User-moved copies — detected by existence of another row with
        //       the same Message-ID in this account (user-move preserves UID
        //       and folder change, so both copies coexist briefly).
        //   (b) Rule-moved copies — detected via recently_moved_by_rule
        //       tombstones (rule-move deletes the local row, so dupe check
        //       in (a) wouldn't see anything).
        let ttlCutoff = Date().timeIntervalSince1970 - Self.ruleMoveTombstoneTTL
        let items: [MessageListItem] = (try? await pool.read { db in
            let placeholders = databaseQuestionMarks(count: newUIDs.count)
            let sql = MessageListItem.listSQL +
                " WHERE m.folder_id = ? AND m.uid IN (\(placeholders))"
            var args: [DatabaseValueConvertible] = [folderID]
            args.append(contentsOf: newUIDs.map { $0 as DatabaseValueConvertible })
            let all = try MessageListItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))

            return all.filter { item in
                guard let mid = item.messageID, !mid.isEmpty else { return true }

                // (a) user-moved: another local copy exists
                let dupeCount = (try? Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM messages
                    WHERE message_id = ? AND account_id = ? AND id != ?
                    """, arguments: [mid, accountID, item.id])) ?? 0
                if dupeCount > 0 { return false }

                // (b) rule-moved: tombstone within TTL
                let tombstoned = (try? Bool.fetchOne(db, sql: """
                    SELECT 1 FROM recently_moved_by_rule
                    WHERE account_id = ? AND message_id = ? AND moved_at > ?
                    """, arguments: [accountID, mid, ttlCutoff])) ?? false
                return !tombstoned
            }
        }) ?? []

        // Process oldest UID first so that rewriteSubject's APPEND+DELETE
        // preserves on-server ordering: the oldest message gets the lowest
        // new UID, the newest gets the highest — matching how webmail UIs
        // sort the folder (by UID, ascending = chronological).
        var actionsCount = 0
        for item in items.sorted(by: { $0.uid < $1.uid }) {
            let matched = engine.matchingRules(
                for: item, bodyText: nil, folder: folder,
                accountID: accountID, trigger: .incoming
            )
            for rule in matched {
                await executeRuleActions(rule.actions, for: item, accountID: accountID)
                actionsCount += 1
            }
        }

        if !items.isEmpty {
            LogService.log(.debug, .rules,
                "Evaluated rules for \(items.count) new messages (\(actionsCount) actions)",
                detail: folder.path)
        }
    }

    // MARK: - Manual run (Thunderbird "Run Filters on Folder"/"...on Selection")

    /// Apply all rules with `runOnManual=true` to the messages of `folderID`.
    /// `messageIDs = nil` → whole folder. Otherwise only the given IDs.
    /// Unlike incoming, tombstones are NOT used to suppress matches — manual
    /// run by definition repeats actions. We still WRITE tombstones (inside
    /// executeRuleActions' move/delete paths) so the follow-up IDLE/reconcile
    /// doesn't re-trigger incoming rules on the same Message-ID.
    func runRulesManually(
        in folderID: UUID,
        accountID: UUID,
        messageIDs: [UUID]? = nil
    ) async {
        guard let engine = ruleEngine else { return }

        let anyEnabled: Bool = (try? await pool.read { db in
            try MailRule
                .filter(Column("is_enabled") == true)
                .filter(Column("run_on_manual") == true)
                .fetchCount(db) > 0
        }) ?? false
        guard anyEnabled else {
            LogService.log(.info, .rules, "Manual rule run: no enabled rules")
            return
        }

        let ctx: (folder: Folder, items: [MessageListItem])? = try? await pool.read { db in
            guard let folder = try Folder.fetchOne(db, key: folderID) else { return nil }

            let items: [MessageListItem]
            if let ids = messageIDs, !ids.isEmpty {
                let placeholders = databaseQuestionMarks(count: ids.count)
                let sql = MessageListItem.listSQL +
                    " WHERE m.folder_id = ? AND m.id IN (\(placeholders))"
                var args: [DatabaseValueConvertible] = [folderID]
                args.append(contentsOf: ids.map { $0 as DatabaseValueConvertible })
                items = try MessageListItem.fetchAll(
                    db, sql: sql, arguments: StatementArguments(args)
                )
            } else {
                let sql = MessageListItem.listSQL + " WHERE m.folder_id = ?"
                items = try MessageListItem.fetchAll(
                    db, sql: sql, arguments: [folderID]
                )
            }
            return (folder, items)
        }
        guard let ctx, !ctx.items.isEmpty else {
            LogService.log(.info, .rules, "Manual rule run: no candidate messages")
            return
        }

        // Oldest UID first — see applyRulesToNewMessages for rationale.
        var matchedCount = 0
        var actionsCount = 0
        for item in ctx.items.sorted(by: { $0.uid < $1.uid }) {
            let matched = engine.matchingRules(
                for: item, bodyText: nil, folder: ctx.folder,
                accountID: accountID, trigger: .manual
            )
            if !matched.isEmpty { matchedCount += 1 }
            for rule in matched {
                await executeRuleActions(rule.actions, for: item, accountID: accountID)
                actionsCount += 1
            }
        }

        LogService.log(.info, .rules,
            "Manual rule run: \(matchedCount) matched, \(actionsCount) actions",
            detail: ctx.folder.path)
    }

    // MARK: - Execute rule actions

    func executeRuleActions(
        _ actions: [RuleAction], for item: MessageListItem, accountID: UUID
    ) async {
        // Prefetch account + folder once to avoid N+1 per action
        let ctx: (account: Account, folder: Folder)? = try? await pool.read { db in
            guard let account = try Account.fetchOne(db, key: accountID),
                  let folder = try Folder.fetchOne(db, key: item.folderID) else { return nil }
            return (account, folder)
        }
        guard let ctx else { return }

        let imap = getOrCreateIMAPService(for: ctx.account)
        let plan = planActions(actions, account: ctx.account, folder: ctx.folder)

        // IDLE gate (rule #14): source folder is under a bulk op for the
        // duration of this rule so EXISTS/EXPUNGE from our APPEND+DELETE are
        // queued, not processed. Drain after completion.
        let sourceFolderID = ctx.folder.id
        bulkOpFolderIDs.insert(sourceFolderID)
        defer {
            bulkOpFolderIDs.remove(sourceFolderID)
            Task { [weak self] in
                await self?.drainPendingIdleEvents(for: sourceFolderID)
            }
        }

        // Step 1: flag-only pre-commits that don't depend on a rewrite.
        // When rewriteSubject is present, seen/flagged are baked into APPEND
        // flags and this block is skipped to avoid a wasted STORE on the
        // soon-to-be-deleted old UID.
        if plan.subjectRewrite == nil {
            if plan.seen == true {
                try? await pool.write { db in
                    try db.execute(sql: "UPDATE messages SET is_read = 1 WHERE id = ?",
                                   arguments: [item.id])
                }
                try? await imap.markRead(uids: [item.uid])
            }
            if plan.flagged == true {
                try? await pool.write { db in
                    try db.execute(sql: "UPDATE messages SET is_flagged = 1 WHERE id = ?",
                                   arguments: [item.id])
                }
                try? await imap.setFlagged(true, uids: [item.uid])
            }
        }

        // Step 2: rewriteSubject. Handles APPEND to plan.subjectRewrite.target
        // with merged flags, DELETE of old UID, DB update + override flag.
        // If this succeeds AND finalDisposition is .moveTo(target), we skip
        // the subsequent move because the APPEND already landed in target.
        var moveAlreadyDone = false
        if let rewrite = plan.subjectRewrite {
            let didRewrite = await rewriteSubjectByRule(
                item: item, folder: ctx.folder,
                account: ctx.account, imap: imap,
                rewrite: rewrite, plan: plan
            )
            if didRewrite,
               case .moveTo(let movePath) = plan.finalDisposition,
               movePath == rewrite.target {
                moveAlreadyDone = true
            }
        }

        // Step 3: final disposition (unless already merged into rewrite).
        switch plan.finalDisposition {
        case .keep:
            break
        case .delete:
            await deleteMessageByRule(
                messageID: item.id, folder: ctx.folder, account: ctx.account, imap: imap
            )
        case .moveTo(let path):
            guard !moveAlreadyDone else { break }
            await moveMessageByRule(
                messageID: item.id, folder: ctx.folder,
                toPath: path, account: ctx.account, imap: imap
            )
        }
    }

    // MARK: - Rule helpers

    private func ensureConnected(imap: IMAPService, account: Account) async throws {
        if await !imap.isConnected {
            await wireTokenProvider(for: account, imap: imap)
            try await imap.connect()
        }
    }

    private func moveMessageByRule(
        messageID: UUID, folder: Folder, toPath: String,
        account: Account, imap: IMAPService
    ) async {
        // Re-read UID + Message-ID in one read. Message-ID is needed for the
        // tombstone that suppresses re-firing when the message re-appears on
        // the target folder via reconcile.
        let snapshot: (uid: UInt32, messageID: String?)? = try? await pool.read { db in
            let row = try Row.fetchOne(db, sql:
                "SELECT uid, message_id FROM messages WHERE id = ?",
                arguments: [messageID])
            guard let row else { return nil }
            return (row["uid"] as UInt32, row["message_id"] as String?)
        }
        guard let snapshot else { return }
        let currentUID = snapshot.uid
        let rfcMessageID = snapshot.messageID

        do {
            try await ensureConnected(imap: imap, account: account)
            try await imap.selectFolder(folder.path)
            try await imap.moveMessages(uids: [currentUID], to: toPath)

            // Delete the local row immediately. The copy in target folder is
            // brought in by the explicit follow-up sync below (or, if that
            // fails, the next IDLE push / STATUS poll / user navigation).
            // No uid=0 zombie, no UNIQUE(folder_id, uid) risk.
            try? await pool.write { db in
                try db.execute(sql: "DELETE FROM messages WHERE id = ?",
                               arguments: [messageID])
                if let mid = rfcMessageID, !mid.isEmpty {
                    writeTombstone(db: db, accountID: account.id, messageID: mid)
                }
            }
            LogService.log(.info, .rules, "Rule moved UID \(currentUID) → \(toPath)")

            // Kick a sync of the target folder so the moved message lands
            // locally — and its unread badge appears — within seconds, not
            // up to a minute (60s STATUS timer). Scheduled, not awaited:
            // the per-account serial lock is held by our caller and is NOT
            // reentrant. The detached Task chains onto the same serial tail
            // and runs after the current frame releases.
            scheduleTargetFolderSyncAfterRule(account: account, toPath: toPath)
        } catch {
            LogService.log(.warning, .rules, "Rule move failed", detail: "\(error)")
        }
    }

    /// Schedules an `incrementalSync` of the target folder to run after the
    /// current rule pipeline releases the per-account serial lock. Used by
    /// move + rewriteSubject to surface the moved/rewritten copy in the
    /// destination folder without waiting for STATUS polling.
    func scheduleTargetFolderSyncAfterRule(account: Account, toPath: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let targetFolderID: UUID? = try? await self.pool.read { db in
                try UUID.fetchOne(db, sql: """
                    SELECT id FROM folders WHERE account_id = ? AND path = ?
                    """, arguments: [account.id, toPath])
            }
            guard let targetFolderID else { return }
            try? await self.runSerializedPerAccount(account.id) { [weak self] in
                guard let self else { return }
                let imap = self.getOrCreateIMAPService(for: account)
                do {
                    try await self.incrementalSync(
                        account: account, folderID: targetFolderID,
                        folderPath: toPath, imap: imap
                    )
                } catch {
                    LogService.log(.warning, .rules,
                        "Target folder sync after rule failed",
                        detail: "\(toPath): \(error)")
                }
            }
        }
    }

    /// Rewrite subject on IMAP server: FETCH raw → patch Subject header →
    /// APPEND into `rewrite.target` with merged flags → locate new UID (UIDPLUS
    /// preferred, falls back to `UID SEARCH HEADER Message-ID`) → DELETE old
    /// UID → UPDATE DB (subject+uid+folder) + insert `message_subject_overrides`
    /// row + tombstone on original Message-ID.
    ///
    /// Returns `true` when DB was updated with the new subject, `false` on
    /// any transport/parse error BEFORE the server state was committed.
    /// A `true` result with `uid` unchanged = APPEND succeeded but UID
    /// resolution failed; we did NOT DELETE the original (no data loss),
    /// but the override flag IS set so resync won't undo the local subject.
    @discardableResult
    private func rewriteSubjectByRule(
        item: MessageListItem, folder: Folder,
        account: Account, imap: IMAPService,
        rewrite: ExecutionPlan.SubjectRewrite, plan: ExecutionPlan
    ) async -> Bool {
        guard let regex = try? NSRegularExpression(pattern: rewrite.pattern) else {
            LogService.log(.warning, .rules, "Invalid rewrite regex", detail: rewrite.pattern)
            return false
        }

        let range = NSRange(item.subject.startIndex..., in: item.subject)
        let cleaned = regex
            .stringByReplacingMatches(in: item.subject, range: range,
                                      withTemplate: rewrite.replacement)
            .trimmingCharacters(in: .whitespaces)
        guard cleaned != item.subject else { return false }

        do {
            try await ensureConnected(imap: imap, account: account)
            try await imap.selectFolder(folder.path)

            // 1. FETCH raw RFC822
            let rawData = try await imap.fetchRawMessage(uid: item.uid)
            guard let raw = String(data: rawData, encoding: .utf8)
                    ?? String(data: rawData, encoding: .ascii) else {
                LogService.log(.warning, .rules, "Cannot decode raw message", detail: "UID \(item.uid)")
                return false
            }

            // 2. Split headers and body — find separator before any normalization
            //    to avoid corrupting binary attachments in the body.
            let separators = ["\r\n\r\n", "\n\n"]
            guard let sep = separators.first(where: { raw.contains($0) }),
                  let headerEnd = raw.range(of: sep) else {
                LogService.log(.warning, .rules, "No header/body separator", detail: "UID \(item.uid)")
                return false
            }
            // Normalize only headers to CRLF; body stays as-is
            var headerPart = String(raw[..<headerEnd.lowerBound])
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
            let bodyPart = String(raw[headerEnd.lowerBound...])

            // 3. Unfold multiline Subject header (RFC 2822 §2.2.3, case-insensitive).
            //    `(?im)^` anchors at line start so we don't accidentally match
            //    `Subject:` occurring inside another header's value (e.g. the
            //    `h=... Subject: ...` list inside DKIM-Signature).
            while headerPart.range(of: "(?im)^Subject:.*\r\n[ \t]+",
                                   options: .regularExpression) != nil {
                headerPart = headerPart.replacingOccurrences(
                    of: "(?im)(^Subject:.*?)(\r\n[ \t]+)",
                    with: "$1 ",
                    options: .regularExpression
                )
            }

            // 4. Replace Subject value with cleaned version (RFC 2047 base64-encoded).
            //    Line-anchored to skip DKIM's `h=...: Subject: ...` substring.
            let encodedSubject = "Subject: =?utf-8?b?\(Data(cleaned.utf8).base64EncodedString())?="
            if let subjectRange = headerPart.range(of: "(?im)^Subject:.*",
                                                    options: .regularExpression) {
                headerPart.replaceSubrange(subjectRange, with: encodedSubject)
            }

            let newRaw = headerPart + bodyPart

            // 5. Merge flags: DB (prior actions) + plan (seen/flagged).
            //    APPEND creates the new message with these flags directly —
            //    no follow-up STORE needed on the new UID.
            let dbFlags: (read: Bool, flagged: Bool, answered: Bool) = (try? await pool.read { db in
                let row = try Row.fetchOne(db, sql:
                    "SELECT is_read, is_flagged, is_answered FROM messages WHERE id = ?",
                    arguments: [item.id])
                return (row?["is_read"] ?? item.isRead,
                        row?["is_flagged"] ?? item.isFlagged,
                        row?["is_answered"] ?? item.isAnswered)
            }) ?? (item.isRead, item.isFlagged, item.isAnswered)

            let finalRead = plan.seen ?? dbFlags.read
            let finalFlagged = plan.flagged ?? dbFlags.flagged
            var flags: [Flag] = []
            if finalRead { flags.append(.seen) }
            if finalFlagged { flags.append(.flagged) }
            if dbFlags.answered { flags.append(.answered) }

            // 6. APPEND modified message → get new UID (if UIDPLUS)
            var newUID = try await imap.appendRawMessage(
                newRaw, to: rewrite.target, flags: flags, date: item.date
            )

            // 7. Fallback: resolve new UID via SEARCH when UIDPLUS is absent
            //    (Mail.ru, older IMAP servers). We search the target folder
            //    for the Message-ID header — at this point two copies with
            //    the same Message-ID coexist on the server; we pick the
            //    highest UID in the target folder because:
            //      - target == source: the new UID is strictly greater than
            //        `item.uid` (monotonic UID_NEXT).
            //      - target != source: source UID is in a different folder,
            //        so any hit in target is the new copy.
            let rfcMessageID: String? = try? await pool.read { db in
                try String.fetchOne(db,
                    sql: "SELECT message_id FROM messages WHERE id = ?",
                    arguments: [item.id])
            } ?? nil
            if newUID == nil, let mid = rfcMessageID, !mid.isEmpty {
                try await imap.selectFolder(rewrite.target)
                let candidates = try await imap.searchByMessageID(mid)
                if rewrite.target == folder.path {
                    // Pick any candidate strictly greater than source UID.
                    newUID = candidates.filter { $0 > item.uid }.max()
                } else {
                    newUID = candidates.max()
                }
                // Re-select source folder for the upcoming DELETE.
                try await imap.selectFolder(folder.path)
            }

            // 8. If still no UID: APPEND likely succeeded on server but we
            //    cannot confirm. Refuse to DELETE the original (bug #1:
            //    deleting without a confirmed new UID risks total data loss).
            //    Still persist the subject locally + override flag so the
            //    user sees the rewritten subject; duplicate on server can be
            //    cleaned up later by the user.
            guard let newUID else {
                LogService.log(.warning, .rules,
                    "Rewrite: could not resolve new UID after APPEND (UIDPLUS absent, SEARCH empty). Leaving duplicate on server.",
                    detail: "UID \(item.uid), mid=\(rfcMessageID ?? "nil")")
                try? await pool.write { db in
                    try db.execute(
                        sql: "UPDATE messages SET subject = ? WHERE id = ?",
                        arguments: [cleaned, item.id]
                    )
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO message_subject_overrides
                        (message_id, edited_at) VALUES (?, ?)
                        """, arguments: [item.id, Date().timeIntervalSince1970])
                    if let mid = rfcMessageID, !mid.isEmpty {
                        writeTombstone(db: db, accountID: account.id, messageID: mid)
                    }
                }
                return true
            }

            // 9. DELETE original — UID + mailbox confirmed, safe to remove.
            try await imap.deleteMessages(uids: [item.uid])

            // 10. Resolve target folder row (may differ from source when rewrite
            //     merged with moveToFolder). If unknown, fall back to source
            //     folder_id — reconcile of target will fix it up later.
            let targetFolderID: UUID = (try? await pool.read { db in
                try UUID.fetchOne(db, sql: """
                    SELECT id FROM folders WHERE account_id = ? AND path = ?
                    """, arguments: [account.id, rewrite.target])
            }) ?? folder.id

            // 11. Single transaction: subject + uid + folder_id + override +
            //     tombstone on Message-ID to suppress IDLE-triggered re-fire
            //     in the source folder.
            try? await pool.write { db in
                try db.execute(sql: """
                    UPDATE messages
                    SET subject = ?, uid = ?, folder_id = ?
                    WHERE id = ?
                    """, arguments: [cleaned, newUID, targetFolderID, item.id])
                try db.execute(sql: """
                    INSERT OR REPLACE INTO message_subject_overrides
                    (message_id, edited_at) VALUES (?, ?)
                    """, arguments: [item.id, Date().timeIntervalSince1970])
                if let mid = rfcMessageID, !mid.isEmpty {
                    writeTombstone(db: db, accountID: account.id, messageID: mid)
                }
            }

            LogService.log(.info, .rules, "Rewrote subject on server",
                           detail: "\"\(item.subject)\" → \"\(cleaned)\" (UID \(item.uid)→\(newUID), \(rewrite.target))")
            return true
        } catch {
            LogService.log(.warning, .rules, "Subject rewrite failed", detail: "\(error)")
            return false
        }
    }

    private func deleteMessageByRule(
        messageID: UUID, folder: Folder, account: Account, imap: IMAPService
    ) async {
        guard let currentUID: UInt32 = try? await pool.read({ db in
            try UInt32.fetchOne(db, sql: "SELECT uid FROM messages WHERE id = ?",
                                arguments: [messageID])
        }) else { return }

        do {
            try await ensureConnected(imap: imap, account: account)
            if let trashPath = account.trashFolderPath {
                try await imap.selectFolder(folder.path)
                try await imap.moveMessages(uids: [currentUID], to: trashPath)
            } else {
                try await imap.selectFolder(folder.path)
                try await imap.deleteMessages(uids: [currentUID])
            }
            try? await pool.write { db in
                try db.execute(sql: "DELETE FROM messages WHERE id = ?",
                               arguments: [messageID])
            }
            LogService.log(.info, .rules, "Rule deleted UID \(currentUID)")
        } catch {
            LogService.log(.warning, .rules, "Rule delete failed", detail: "\(error)")
        }
    }

}

// MARK: - Tombstone helper (shared by move + rewrite)

/// INSERT OR REPLACE into `recently_moved_by_rule`, plus opportunistic
/// prune of stale tombstones. File-scope + `@Sendable` so it can be called
/// from inside `pool.write { db in ... }` closures that run off the main
/// actor.
@Sendable
fileprivate func writeTombstone(db: Database, accountID: UUID, messageID: String) {
    let now = Date().timeIntervalSince1970
    try? db.execute(sql: """
        INSERT OR REPLACE INTO recently_moved_by_rule
        (account_id, message_id, moved_at) VALUES (?, ?, ?)
        """, arguments: [accountID, messageID, now])
    try? db.execute(sql:
        "DELETE FROM recently_moved_by_rule WHERE moved_at < ?",
        arguments: [now - SyncService.ruleMoveTombstoneTTL])
}
