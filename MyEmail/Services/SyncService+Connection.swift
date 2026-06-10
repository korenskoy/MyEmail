//
//  SyncService+Connection.swift
//  MyEmail
//
//  IDLE, NOOP probe, NWPathMonitor, App Nap mitigation.
//

import AppKit
import Foundation
import GRDB
import Network
import NIOIMAPCore
import SwiftMail

extension SyncService {

    // MARK: - Network monitoring

    func startNetworkMonitor() {
        // rule 3: hold the monitor in a stored MainActor property, not a local.
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = path.status == .satisfied

                if !wasOnline && self.isOnline {
                    LogService.log(.info, .sync, "Network recovered, draining queue")
                    let processed = await self.offlineQueue?.drain { action in
                        // §9.5: serialize replay on the per-account socket so a
                        // drained SELECT/STORE can't interleave with a concurrent
                        // sync/IDLE flow sharing the same IMAP connection.
                        try await self.runSerializedPerAccount(action.accountID) { [weak self] in
                            try await self?.executeQueuedAction(action)
                        }
                    } ?? 0
                    // Only refresh when drain actually replayed something —
                    // otherwise initial bootstrap sync already covered this and
                    // refreshAll would duplicate the folder LIST / SELECT.
                    if processed > 0 {
                        await self.refreshAll()
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
    }

    // MARK: - App Nap prevention (§9.8)

    func beginAppNapPrevention() -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "IMAP IDLE connection"
        )
    }

    // MARK: - Multi-folder IDLE (Pattern #3)

    /// Starts a dedicated IDLE session on the given folder.
    /// Safe to call multiple times with the same account+folder — replaces
    /// existing session for that key.
    func ensureIDLE(account: Account, folderPath: String) {
        let key = "\(account.id):\(folderPath)"
        // Already running?
        if idleTasks[key] != nil { return }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.runIDLESession(account: account, folderPath: folderPath)
        }
        idleTasks[key] = task
        // §15: clean up only OUR task on completion. An unconditional
        // removeValue would delete a newer task that replaced this key after a
        // restart, leaving an untracked duplicate IDLE (schedulePrefetch parity).
        Task { [weak self] in
            _ = await task.value
            await MainActor.run {
                guard let self else { return }
                if self.idleTasks[key] == task { self.idleTasks.removeValue(forKey: key) }
            }
        }
    }

    /// Cancels a specific IDLE session. No-op if not running.
    func stopIDLE(account: Account, folderPath: String) {
        let key = "\(account.id):\(folderPath)"
        idleTasks[key]?.cancel()
        idleTasks.removeValue(forKey: key)
    }

    /// Runs the main event loop for a per-folder IDLE session with retry.
    /// SwiftMail handles IDLE renewal internally at 285s (IMAPIdleConfiguration),
    /// so no client-side 29-min timer is needed.
    private func runIDLESession(account: Account, folderPath: String) async {
        let maxRetries = 10
        var retryCount = 0

        while retryCount < maxRetries, !Task.isCancelled {
            let imap = getOrCreateIMAPService(for: account)
            do {
                if await !imap.isConnected { try await imap.connect() }

                let session = try await imap.startIDLE(on: folderPath)
                retryCount = 0

                // SwiftMail renews IDLE at 285s internally — just iterate events
                for await event in session.events {
                    if Task.isCancelled { break }
                    await handleIDLEEvent(event, account: account, folderPath: folderPath)
                }

                try? await session.done()
                LogService.log(.debug, .imap, "IDLE session ended", detail: folderPath)
                // §16: even on a clean exit, back off before reconnecting. A
                // server that ends IDLE immediately (or a transient that looks
                // clean) would otherwise spin this loop, flooding the server with
                // reconnects. 5s is short enough to keep push latency low.
                if Task.isCancelled { return }
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                // Outer while loop restarts IDLE after the backoff.
            } catch is CancellationError {
                return
            } catch {
                retryCount += 1
                LogService.log(.warning, .imap,
                    "IDLE(\(folderPath)) ended (\(retryCount)/\(maxRetries))",
                    detail: "\(error)")
                if Self.isAuthError(error) { return }
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
            }
        }
    }

    /// Routes events from per-folder IDLE to appropriate handlers:
    ///   - .fetchUID → direct DB flag update (cheaper than full sync)
    ///   - .exists on inbox → syncInboxAndNotify (incremental sync + notifications)
    ///   - .exists on other folders / default → plain incrementalSync
    /// IDLE gate (§9.14): if folder is under bulk op, queue event for later.
    ///
    /// Any branch that issues IMAP commands runs inside the per-account
    /// serial lock (Thunderbird URL queue parity) so the sync doesn't
    /// stomp on a concurrent `syncFolderIfNeeded` / bootstrap flow that
    /// shares the same IMAPService connection.
    private func handleIDLEEvent(
        _ event: IMAPServerEvent, account: Account, folderPath: String
    ) async {
        LogService.log(.debug, .imap, "IDLE[\(folderPath)] event: \(event)")

        // Load folderID + special_use once per event
        guard let folderRow = try? await pool.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT id, special_use FROM folders WHERE account_id = ? AND path = ?
                """, arguments: [account.id, folderPath])
        }) else { return }
        let folderID: UUID = folderRow["id"]
        let isInbox = (folderRow["special_use"] as String?) == "inbox"

        // IDLE gate (§9.14): queue event if folder has a bulk op in progress
        if bulkOpFolderIDs.contains(folderID) {
            pendingIdleEvents[folderID, default: []].append(event)
            LogService.log(.debug, .imap, "IDLE event queued (bulk op active)", detail: folderPath)
            return
        }

        // .fetchUID is a pure DB write — no IMAP command, no lock needed.
        if case .fetchUID(let uid, let attrs) = event {
            await handleFlagUpdate(uid: uid.value, attrs: attrs,
                                   folderPath: folderPath, accountID: account.id)
            await updateDockBadge()
            return
        }

        // Coalesce redundant `exists(N)` pushes: if the mailbox count has not
        // changed since the last successful sync, nothing new to fetch.
        // EXPUNGE invalidates the cache below so legitimate follow-up EXISTS
        // (after server-side deletes) still triggers a sync.
        if case .exists(let count) = event, lastExistsCount[folderID] == count {
            LogService.log(.debug, .imap,
                "IDLE exists(\(count)) == last known count — skip SELECT/QRESYNC",
                detail: folderPath)
            return
        }

        // EXPUNGE shifts the mailbox count; drop the cache so the next EXISTS
        // re-triggers a sync even if the server reports the same N.
        if case .expunge = event {
            lastExistsCount[folderID] = nil
        }

        try? await runSerializedPerAccount(account.id) { [weak self] in
            guard let self else { return }
            let imap = self.getOrCreateIMAPService(for: account)
            switch event {
            case .exists(let count):
                if isInbox {
                    try? await self.syncInboxAndNotify(
                        account: account, folderID: folderID, imap: imap
                    )
                } else {
                    try? await self.incrementalSync(
                        account: account, folderID: folderID,
                        folderPath: folderPath, imap: imap
                    )
                }
                // Remember the count that drove this sync so the next
                // identical EXISTS is recognised as a no-op keep-alive.
                self.lastExistsCount[folderID] = count
            default:
                try? await self.incrementalSync(
                    account: account, folderID: folderID,
                    folderPath: folderPath, imap: imap
                )
            }
            await self.updateDockBadge()
        }

        // Body prefetch top-up after IDLE-driven sync.
        // `replace: false` — bursty IDLE pushes don't restart an in-flight prefetch.
        schedulePrefetch(folderID: folderID, replace: false)
    }

    // MARK: - IDLE gate drain (§9.14)

    /// Replay queued IDLE events after a bulk operation finishes.
    func drainPendingIdleEvents(for folderID: UUID) async {
        guard let events = pendingIdleEvents.removeValue(forKey: folderID) else { return }
        LogService.log(.debug, .imap, "Draining \(events.count) queued IDLE events", detail: "\(folderID)")

        // Resolve account+folderPath once for all events
        guard let ctx: (Account, String) = try? await pool.read({ db -> (Account, String)? in
            guard let folder = try Folder.fetchOne(db, key: folderID),
                  let account = try Account.fetchOne(db, key: folder.accountID)
            else { return nil }
            return (account, folder.path)
        }) else { return }
        let (account, folderPath) = ctx

        for event in events {
            await handleIDLEEvent(event, account: account, folderPath: folderPath)
        }
    }

    // MARK: - IDLE on INBOX (delegates to Pattern #3)

    func startIDLE(for account: Account, folderPath: String = "INBOX") async {
        ensureIDLE(account: account, folderPath: folderPath)
    }

    // MARK: - IDLE flag update

    private func handleFlagUpdate(
        uid: UInt32, attrs: [MessageAttribute],
        folderPath: String, accountID: UUID
    ) async {
        // Extract flags from NIOIMAPCore.MessageAttribute. RFC 3501: flag atoms
        // are case-insensitive — lowercase both sides so e.g. `$forwarded` from
        // non-canonical servers still matches (§10).
        var flagStrs: Set<String> = []
        for attr in attrs {
            if case .flags(let flags) = attr {
                flagStrs = Set(flags.map { String($0).lowercased() })
            }
        }
        guard !flagStrs.isEmpty else { return }

        // NIOIMAPCore Flag → String: "\Seen", "\Flagged", etc. (lowercased above)
        let isRead = flagStrs.contains("\\seen")
        let isFlagged = flagStrs.contains("\\flagged")
        let isAnswered = flagStrs.contains("\\answered")
        let isForwarded = flagStrs.contains("$forwarded")
        let isDraft = flagStrs.contains("\\draft")

        guard let msgID: UUID = try? await pool.read({ db in
            try UUID.fetchOne(db, sql: """
                SELECT m.id FROM messages m
                JOIN folders f ON f.id = m.folder_id
                WHERE f.path = ? AND f.account_id = ? AND m.uid = ?
                """, arguments: [folderPath, accountID, uid])
        }) else { return }

        guard !isInCooldown(msgID) else { return }

        try? await pool.write { db in
            try db.execute(sql: """
                UPDATE messages
                SET is_read = ?, is_flagged = ?, is_answered = ?, is_forwarded = ?, is_draft = ?
                WHERE id = ?
                """, arguments: [isRead, isFlagged, isAnswered, isForwarded, isDraft, msgID])
        }
        LogService.log(.debug, .sync, "IDLE flag update: UID \(uid) read=\(isRead) flagged=\(isFlagged)")
    }

    // MARK: - Notification helpers

    private func postNotificationsForNew(afterUID: UInt32, accountID: UUID) async {
        guard let rows = try? await pool.read({ db in
            try Row.fetchAll(db, sql: """
                SELECT m.uid, m.from_name, m.from_address, m.subject, m.folder_id
                FROM messages m
                JOIN folders f ON f.id = m.folder_id
                WHERE f.special_use = 'inbox' AND f.account_id = ?
                  AND m.uid > ? AND m.is_read = 0
                """, arguments: [accountID, afterUID])
        }) else {
            LogService.log(.error, .notifications,
                           "DB read failed for new-message notifications")
            return
        }

        LogService.log(.info, .notifications,
                       "Found \(rows.count) candidate message(s) for notification",
                       detail: "account=\(accountID) afterUID=\(afterUID)")

        for row in rows {
            let uid: UInt32 = row["uid"]
            let from: String = row["from_name"] ?? row["from_address"]
            let subject: String = row["subject"]
            let folderID: UUID = row["folder_id"]
            NotificationService.shared.postNewMessage(
                from: from, subject: subject,
                accountID: accountID, folderID: folderID, messageUID: uid
            )
        }
    }

    // MARK: - Inbox sync with notification hook

    /// Wraps `incrementalSync` on INBOX: captures max UID before, runs sync,
    /// then posts notifications for any new messages. Used by both the
    /// IDLE `.exists` path and bootstrap/refreshAll so notifications
    /// fire regardless of how new messages arrived.
    ///
    /// Guard `maxUIDBefore > 0` prevents a notification flood on first
    /// bootstrap when the local DB is empty.
    func syncInboxAndNotify(
        account: Account,
        folderID: UUID,
        imap: IMAPService,
        cachedSelection: Mailbox.Selection? = nil
    ) async throws {
        // Use persisted highestKnownUid — survives restarts, avoids re-notifications
        let prevHighest: UInt32 = (try? await pool.read { db in
            try Folder.fetchOne(db, key: folderID)?.highestKnownUid
        }) ?? 0

        try await incrementalSync(
            account: account,
            folderID: folderID,
            folderPath: "INBOX",
            imap: imap,
            cachedSelection: cachedSelection
        )

        if prevHighest > 0 {
            LogService.log(.info, .notifications,
                           "Post-sync check for new messages",
                           detail: "account=\(account.email) afterUID=\(prevHighest)")
            await postNotificationsForNew(
                afterUID: prevHighest, accountID: account.id
            )
        }
    }

    /// Update dock badge with total unread across all INBOX folders.
    func updateDockBadge() async {
        let count = (try? await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages m
                JOIN folders f ON f.id = m.folder_id
                JOIN accounts a ON a.id = m.account_id
                WHERE f.special_use = 'inbox' AND a.is_enabled = 1 AND m.is_read = 0
                """) ?? 0
        }) ?? 0
        NotificationService.shared.updateBadge(count: count)
    }

    // MARK: - Periodic sync timer
    //
    // Two cadences combined:
    //   - STATUS polling every 60s (Pattern #4): cheap, keeps sidebar counts
    //     fresh and detects new messages in non-IDLE folders
    //   - Full refreshAll every 300s: fallback in case STATUS missed something
    //     or the IDLE connection silently dropped

    func startPeriodicSync() {
        periodicSyncTimer?.invalidate()
        var tick: Int = 0
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            tick += 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                // §27: clear expired optimistic-cooldown entries so a bulk op's
                // 10k UUIDs don't live in memory until restart.
                self.pruneExpiredMutations()
                await self.pollFolderStatuses()
                await self.updateDockBadge()
                // Every 5th tick (5 min) — full refresh as safety net
                if tick % 5 == 0 {
                    await self.refreshAll()
                }
            }
        }
    }

    // MARK: - System wake observer

    /// Subscribes to `NSWorkspace.didWakeNotification`. `Timer.scheduledTimer`
    /// is suspended while the Mac sleeps — without an explicit wake hook the
    /// first STATUS poll after wake is delayed until the next 60s tick.
    ///
    /// Also marks every cached IMAP socket as `needsHealthProbe = true` so the
    /// STATUS sweep that follows does NOOP-probe → reconnect on dead sockets
    /// instead of stumbling into a `bad(Unknown command …)` desync.
    func startWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                LogService.log(.info, .sync, "System wake — probing connections + STATUS sweep")
                await self.markAllConnectionsNeedProbe()
                await self.pollFolderStatuses()
                await self.updateDockBadge()
            }
        }
    }

    // MARK: - App foreground observer (Thunderbird `m_needNoop` parity)

    /// Subscribes to `NSApplication.didBecomeActiveNotification`. When the
    /// user brings the app back to foreground after time in App Nap or after
    /// having been hidden, our cached IMAP connections may have been killed
    /// silently by NAT timeout / middlebox state expiry. The TCP socket
    /// often still reports `.ready`, but the IMAP stream is desynchronized
    /// — the next SELECT receives `bad(Unknown command <gmail-msgid>)`.
    ///
    /// Marking every cached IMAPService as `needsHealthProbe = true` forces
    /// a NOOP with a short timeout before the next real command. Failed
    /// probes auto-reconnect inside `ensureHealthyConnection`.
    func startForegroundObserver() {
        guard becomeActiveObserver == nil else { return }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                LogService.log(.debug, .sync, "App became active — marking IMAP sockets for probe")
                await self.markAllConnectionsNeedProbe()
            }
        }
    }


    // MARK: - Session-desync detection (Thunderbird `HandleProtocolError` parity)

    /// True for errors that indicate the IMAP session itself is desynced or
    /// dead and the socket must not be reused:
    ///   • BAD `Unknown command <session-id>` — Gmail's post-NAT-timeout signal
    ///   • RFC 5530 `[CLIENTBUG]` — mail.ru/Yahoo "wrong state" rejection
    ///   • `IMAPError.timeout` / "operation timed out" — server stopped reading
    ///     or replying; on Gmail the very next command echoes back as a BAD.
    /// Reusing the same socket only repeats the failure; catch-sites mark the
    /// IMAPService for probe so the next entry-point reconnects.
    nonisolated static func isSessionDesyncError(_ error: Error) -> Bool {
        if let imapErr = error as? IMAPError {
            switch imapErr {
            case .timeout:
                return true
            case .commandFailed(let reason):
                let lower = reason.lowercased()
                return lower.contains("unknown command") || lower.contains("[clientbug]")
            default:
                break
            }
        }
        let lower = "\(error)".lowercased()
        return lower.contains("operation timed out") || lower.contains("broken pipe")
    }

    /// If `error` looks like a session-desync BAD, mark `imap` so the next
    /// IMAP operation force-probes and reconnects instead of reusing the
    /// poisoned socket. Safe to call on any error — no-ops otherwise.
    func recycleConnectionIfDesynced(_ error: Error, imap: IMAPService) async {
        guard Self.isSessionDesyncError(error) else { return }
        LogService.log(.warning, .imap,
            "Session-desync BAD; marking socket for probe",
            detail: "\(error)")
        await imap.markNeedsProbe()
    }

    // MARK: - Execute queued action (for drain)

    func executeQueuedAction(_ action: PendingAction) async throws {
        guard let account = try await pool.read({ db in
            try Account.fetchOne(db, key: action.accountID)
        }) else { return }

        // UIDVALIDITY check (RFC 3501 §2.3.1.1): discard stale actions
        if let savedUV = action.sourceUidValidity, let folderPath = action.sourceFolderPath {
            let currentUV: UInt32? = try? await pool.read { db in
                try UInt32.fetchOne(db, sql:
                    "SELECT uid_validity FROM folders WHERE account_id = ? AND path = ?",
                    arguments: [action.accountID, folderPath])
            }
            if let currentUV, currentUV != savedUV {
                LogService.log(.warning, .sync,
                    "Discarding stale action: UIDVALIDITY changed",
                    detail: "\(action.type.rawValue) \(folderPath) \(savedUV)→\(currentUV)")
                return
            }
        }

        let imap = getOrCreateIMAPService(for: account)
        await wireTokenProvider(for: account, imap: imap)
        if await !imap.isConnected { try await imap.connect() }

        if let folderPath = action.sourceFolderPath {
            _ = try await imap.selectFolder(folderPath)
        }

        guard let uid = action.messageUID else { return }

        switch action.type {
        case .markRead:
            try await imap.markRead(uids: [uid])
        case .markUnread:
            try await imap.markUnread(uids: [uid])
        case .flag:
            try await imap.setFlagged(true, uids: [uid])
        case .unflag:
            try await imap.setFlagged(false, uids: [uid])
        case .move:
            guard let target = action.targetFolderPath else { return }
            try await imap.moveMessages(uids: [uid], to: target)
        case .delete:
            try await imap.deleteMessages(uids: [uid])
        case .markJunk:
            guard let target = action.targetFolderPath else { return }
            try await imap.moveMessages(uids: [uid], to: target)
        case .archive:
            guard let target = action.targetFolderPath else { return }
            // Auto-create archive subfolder only if missing — avoids repeated
            // ALREADYEXISTS churn when draining many archive actions to the
            // same target (e.g. [Gmail]/All Mail).
            let exists: Bool = (try? await pool.read { db in
                try Bool.fetchOne(db, sql:
                    "SELECT 1 FROM folders WHERE account_id = ? AND path = ? LIMIT 1",
                    arguments: [action.accountID, target])
            }) ?? false
            if !exists {
                do {
                    try await imap.createFolder(path: target)
                } catch {
                    LogService.log(.debug, .imap, "CREATE \(target): \(error)")
                }
            }
            try await imap.moveMessages(uids: [uid], to: target)
        default:
            LogService.log(.warning, .sync, "Unhandled queued action: \(action.type.rawValue)")
        }
    }
}
