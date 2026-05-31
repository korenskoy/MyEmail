//
//  SyncService.swift
//  MyEmail
//
//  @MainActor @Observable orchestrator. No `import SwiftUI` (§3.3).
//  UI reads `isSyncing` / `isOnline` via @Observable; messages arrive
//  via ValueObservation in AppState.
//
//  M3 scope: INBOX-only sync with bidirectional reconcile.
//  Extensions: SyncService+Private.swift
//

import Foundation
import GRDB
import Observation
import SwiftMail

/// Typed result box for cross-Task return-value passing in
/// `SyncService.runSerializedPerAccount`. Module-scoped because Swift
/// forbids nested generic types inside a generic function.
private final class SyncSerialBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

@Observable
@MainActor
final class SyncService {
    // MARK: - Observable state for UI

    var isSyncing = false
    var isOnline = false

    // MARK: - Dependencies

    let pool: DatabasePool
    let keychain: KeychainService
    private var imapServices: [UUID: IMAPService] = [:]
    var smtpServiceStore: [UUID: SMTPService] = [:]

    /// AuthService reference for token refresh
    var authService: AuthService?

    /// Offline queue for failed operations
    var offlineQueue: OfflineQueueService?

    /// Rule engine for applying mail rules to new messages (§6.7.1)
    var ruleEngine: RuleEngine?

    /// Optimistic mutation cooldown (§9.10)
    var recentMutationStore: [UUID: Date] = [:]

    /// In-flight lazy folder syncs (prevents duplicate concurrent syncs).
    /// Read by `SyncService+BackgroundSync` to skip STATUS poll on folders
    /// already being synced by a user-initiated open.
    var syncingFolders: Set<UUID> = []

    /// Per-account in-flight sync tasks. Concurrent `syncAccount` calls for
    /// the same account coalesce — the second caller awaits the first task's
    /// result instead of opening a second IMAP connection & running SELECT twice.
    /// Read by `SyncService+BackgroundSync` to skip STATUS poll while bootstrap
    /// sync is running.
    var runningSyncs: [UUID: Task<Folder?, Never>] = [:]

    /// Per-account serial queue tail (Thunderbird URL queue parity).
    /// `nsImapProtocol` runs exactly one URL at a time per connection
    /// (`ImapThreadMainLoop` in `nsImapProtocol.cpp:~1450`, serialized
    /// via `m_urlReadyToRunMonitor`). We match that invariant: every
    /// remote op that uses the shared IMAPService chains onto this tail,
    /// so two folder syncs on the same account never interleave their
    /// SELECT/FETCH commands on the same socket.
    private var accountSerialTail: [UUID: Task<Void, Never>] = [:]

    /// Dedicated "command" socket pool for user-triggered reads (body /
    /// attachment fetch, View Source). Runs on a second IMAP connection per
    /// account, so a stalled sync/backfill on the primary socket does not
    /// block a user opening a message. Matches Thunderbird's connection pool
    /// (multiple `nsImapProtocol` instances per account; one URL at a time
    /// per socket). Command ops chain onto `accountCommandSerialTail` to
    /// preserve per-socket sequentiality.
    private var commandIMAPServices: [UUID: IMAPService] = [:]
    var accountCommandSerialTail: [UUID: Task<Void, Never>] = [:]

    /// Per-folder background body-prefetch tasks (Thunderbird AutoSync parity).
    /// Cancelled on folder switch, disable, disconnect, account re-auth.
    var prefetchTasks: [UUID: Task<Void, Never>] = [:]

    /// Currently-selected folder ID, set by `ContentView` on sidebar selection.
    /// Body prefetch is gated to this folder + every INBOX (per plan scope).
    var currentlySelectedFolderID: UUID?

    /// Folders currently under bulk operation — IDLE events are queued, not processed (rule §9.14)
    var bulkOpFolderIDs: Set<UUID> = []
    /// Pending IDLE events queued during bulk ops
    var pendingIdleEvents: [UUID: [IMAPServerEvent]] = [:]

    /// Last observed EXISTS count per folder. Used to drop redundant IDLE
    /// `exists(N)` pushes: if `N` equals the value stored here, the mailbox
    /// count has not changed since the last successful sync and no SELECT /
    /// QRESYNC is warranted. Invalidated on EXPUNGE (count decreases) so the
    /// next legitimate EXISTS is not swallowed. Thunderbird / K-9 coalesce
    /// IDLE pushes similarly — RFC 2177 itself does not mandate this.
    var lastExistsCount: [UUID: Int] = [:]

    /// Active IDLE tasks keyed by folder path. Allows multi-folder push
    /// notifications (Pattern #3). Default idle folders: INBOX.
    var idleTasks: [String: Task<Void, Never>] = [:]

    /// Periodic sync timer (stored MainActor property — §8.3)
    var periodicSyncTimer: Timer?

    /// NSWorkspace.didWakeNotification observer. Triggers an immediate STATUS
    /// sweep when the Mac wakes from sleep — `Timer.scheduledTimer` halts
    /// during sleep and only resumes on the next 60s tick after wake, which
    /// can leave the UI stale for nearly a minute (Thunderbird wakes its
    /// biff manager on `wake_notification` for the same reason).
    var wakeObserver: NSObjectProtocol?

    /// NSApplication.didBecomeActiveNotification observer. Marks every cached
    /// IMAPService as needing a NOOP health probe before its next command,
    /// mirroring Thunderbird's `m_needNoop` flag set in `ProcessImapAction`.
    /// Catches NAT-timeout / suspend-killed connections that survived as
    /// "ready" NWConnection/NIO channels but whose underlying TCP flow is dead.
    var becomeActiveObserver: NSObjectProtocol?

    init(
        pool: DatabasePool = DatabaseService.shared.pool,
        keychain: KeychainService = .shared
    ) {
        self.pool = pool
        self.keychain = keychain
    }

    // MARK: - Public API

    /// Initial sync after account added — connect + fetch INBOX.
    /// Returns the synced INBOX Folder (or nil on failure) so caller
    /// can start ValueObservation without a duplicate DB query.
    ///
    /// Coalesces concurrent calls for the same account (NWPath recovery +
    /// bootstrap + refreshAll may fire together) — second caller awaits the
    /// first task instead of racing a duplicate IMAP session.
    @discardableResult
    func syncAccount(_ account: Account, retryAfterRefresh: Bool = true) async -> Folder? {
        if let existing = runningSyncs[account.id] {
            LogService.log(.debug, .sync, "syncAccount coalesced", detail: account.email)
            return await existing.value
        }
        let task = Task { [weak self] () -> Folder? in
            guard let self else { return nil }
            return await self._runSyncAccount(account, retryAfterRefresh: retryAfterRefresh)
        }
        runningSyncs[account.id] = task
        let result = await task.value
        runningSyncs[account.id] = nil
        return result
    }

    private func _runSyncAccount(_ account: Account, retryAfterRefresh: Bool) async -> Folder? {
        // Acquire the per-account serial lock so we don't interleave
        // SELECT/FETCH with a concurrent `syncFolderIfNeeded` / IDLE-driven
        // sync on the same IMAP connection.
        do {
            return try await runSerializedPerAccount(account.id) { [weak self] in
                await self?._runSyncAccountLocked(account, retryAfterRefresh: retryAfterRefresh)
            }
        } catch {
            // runSerializedPerAccount only throws what `op` throws; op is
            // non-throwing (returns Folder?).
            return nil
        }
    }

    private func _runSyncAccountLocked(_ account: Account, retryAfterRefresh: Bool) async -> Folder? {
        isSyncing = true
        defer { isSyncing = false }

        let imap = getOrCreateIMAPService(for: account)
        await wireTokenProvider(for: account, imap: imap)

        do {
            if await !imap.isConnected {
                try await imap.connect()
            }
            isOnline = true

            // Thunderbird §14.2: drain pending commands BEFORE pulling server state
            let drained = await offlineQueue?.drain { action in
                try await self.executeQueuedAction(action)
            } ?? 0
            if drained > 0 {
                LogService.log(.info, .sync, "Drained \(drained) pending before sync",
                               detail: account.email)
            }

            // Sync folder list from IMAP (SPECIAL-USE mapping)
            try await syncFolders(account: account, imap: imap)

            // Ensure INBOX folder exists in DB; returns (folderID, Selection)
            let (inboxFolderID, selection) = try await ensureInboxFolder(
                for: account, imap: imap
            )

            // Incremental sync INBOX — pass selection to avoid double SELECT.
            // Wrapper also posts notifications for any new messages picked up
            // here (covers refreshAll path when IDLE push didn't arrive first).
            try await syncInboxAndNotify(
                account: account,
                folderID: inboxFolderID,
                imap: imap,
                cachedSelection: selection
            )

            // Body prefetch warm INBOX after bootstrap sync.
            schedulePrefetch(folderID: inboxFolderID, replace: false)

            LogService.log(.info, .sync, "Sync complete for \(account.email)")

            // Pattern #2: Background prefetch all other folders (low priority).
            // Fires once after initial INBOX sync, skips already-synced folders.
            // Followed by a STATUS sweep so already-synced folders catch up on
            // changes that happened while the app was offline (Thunderbird
            // biff-on-startup parity). Without this, the first detection of a
            // server-side filter / rule move into a non-INBOX folder would
            // wait for the next 60s timer tick — up to a minute of stale UI.
            Task.detached(priority: .background) { [weak self] in
                await self?.prefetchAllFolders(account: account)
                await self?.pollFolderStatuses(for: account)
            }

            // Pattern #3: Persistent IDLE on INBOX for push notifications.
            // STATUS polling explicitly excludes inbox, so without IDLE the
            // only fallback is a 5-minute refreshAll tick.
            ensureIDLE(account: account, folderPath: "INBOX")

            // Sent/Drafts are covered by STATUS polling (see startSpecialUseIDLE).
            await startSpecialUseIDLE(account: account)

            return try await pool.read { db in
                try Folder.fetchOne(db, key: inboxFolderID)
            }
        } catch {
            // Don't set isOnline=false here — one account failing doesn't mean
            // the network is down. isOnline is reset only by NWPathMonitor.

            // Auth failure → refresh token → retry once
            if retryAfterRefresh,
               Self.isAuthError(error),
               account.authType == .oauth2, let auth = authService {
                LogService.log(.warning, .sync, "Auth failed, refreshing token", detail: account.email)
                do {
                    try await auth.refresh(accountID: account.id, reason: "auth-failure-retry")
                    let imap = getOrCreateIMAPService(for: account)
                    await imap.disconnect()
                    // Recurse into *locked* body — we still hold both the
                    // coalescing slot AND the account serial lock; going
                    // back through `_runSyncAccount` would deadlock.
                    return await _runSyncAccountLocked(account, retryAfterRefresh: false)
                } catch {
                    LogService.log(.error, .auth, "Refresh failed → needsReauth", detail: "\(error)")
                }
            }

            LogService.log(.error, .sync, "Sync failed for \(account.email)", detail: "\(error)")
            // If the error survived a refresh+retry (or refresh wasn't applicable
            // and it's still an auth error), Google has rotated the refresh-token
            // but the new access token is rejected — mark needsReauth so the
            // banner surfaces and re-auth via OAuth becomes available.
            if Self.isAuthError(error), account.authType == .oauth2 {
                markNeedsReauth(accountID: account.id, reason: "post-refresh auth failure")
            }
            return nil
        }
    }

    /// Lazy folder sync — called when user opens a non-INBOX folder.
    /// Runs incremental sync for that folder so messages become available.
    /// No-op if already in progress for this folder.
    func syncFolderIfNeeded(folderID: UUID) async {
        guard !syncingFolders.contains(folderID) else {
            LogService.log(.debug, .sync, "Folder sync already in progress", detail: "\(folderID)")
            return
        }

        let folder: Folder? = try? await pool.read { db in
            try Folder.fetchOne(db, key: folderID)
        }
        guard let folder else {
            LogService.log(.warning, .sync, "syncFolderIfNeeded: folder not found", detail: "\(folderID)")
            return
        }

        let account: Account? = try? await pool.read { db in
            try Account.fetchOne(db, key: folder.accountID)
        }
        guard let account else {
            LogService.log(.warning, .sync, "syncFolderIfNeeded: account not found", detail: folder.path)
            return
        }

        // INBOX is always synced as part of `syncAccount` — if one is already
        // in flight, await it instead of issuing a redundant SELECT/CONDSTORE
        // pass behind the per-account serial lock (cross-entry coalescing,
        // Thunderbird's `LoadNextQueuedUrl` URL dedup parity).
        if folder.specialUse == .inbox, let runningTask = runningSyncs[account.id] {
            LogService.log(.debug, .sync, "INBOX sync folded into running account sync", detail: folder.path)
            _ = await runningTask.value
            return
        }

        syncingFolders.insert(folderID)
        defer { syncingFolders.remove(folderID) }

        LogService.log(.info, .sync, "Syncing folder on select", detail: folder.path)

        // Serialize with all other ops on this account's IMAP connection —
        // prevents race with `_runSyncAccount` (bootstrap/refreshAll),
        // IDLE-driven `handleIDLEEvent`, `prefetchAllFolders`, STATUS-poll
        // triggered sync, etc.
        try? await runSerializedPerAccount(account.id) { [weak self] in
            await self?._syncFolderLocked(
                account: account, folderID: folderID, folder: folder
            )
        }
    }

    private func _syncFolderLocked(
        account: Account, folderID: UUID, folder: Folder
    ) async {
        let imap = getOrCreateIMAPService(for: account)
        await wireTokenProvider(for: account, imap: imap)

        isSyncing = true
        defer { isSyncing = false }

        do {
            if await !imap.isConnected {
                try await imap.connect()
            }

            // Drain pending commands before sync (Thunderbird §14.2)
            let drained = await offlineQueue?.drain { action in
                try await self.executeQueuedAction(action)
            } ?? 0
            if drained > 0 {
                LogService.log(.info, .sync, "Drained \(drained) pending before folder sync",
                               detail: folder.path)
            }

            try await incrementalSync(
                account: account,
                folderID: folderID,
                folderPath: folder.path,
                imap: imap
            )
            LogService.log(.info, .sync, "Folder sync complete", detail: folder.path)
            // Body prefetch top-up after fresh headers (Thunderbird AutoSync parity).
            // `replace: false` — don't churn an in-flight prefetch on bursty sync.
            schedulePrefetch(folderID: folderID, replace: false)
        } catch {
            LogService.log(.warning, .sync, "Folder sync failed", detail: "\(folder.path): \(error)")
            if Self.isAuthError(error), account.authType == .oauth2 {
                markNeedsReauth(accountID: account.id, reason: "folder sync auth failure")
            }
        }
    }

    /// Manual refresh — re-sync INBOX for all enabled accounts.
    func refreshAll() async {
        let accounts: [Account]
        do {
            accounts = try AccountRepository(pool: pool, keychain: keychain)
                .allEnabled()
        } catch {
            LogService.log(.error, .sync, "Failed to load accounts", detail: "\(error)")
            return
        }

        for account in accounts {
            await syncAccount(account)
        }
    }

    // MARK: - Per-account serial queue (Thunderbird URL queue parity)

    /// Run `op` serialized per-account. Concurrent callers for the same
    /// account queue via Task chaining — only one op touches the IMAPService
    /// connection at a time. Matches `nsImapProtocol::ImapThreadMainLoop`
    /// which processes exactly one URL before picking up the next.
    ///
    /// NOT reentrant — callers wrap at top-level entry points only. Nested
    /// calls for the same account deadlock.
    @discardableResult
    func runSerializedPerAccount<T: Sendable>(
        _ accountID: UUID,
        _ op: @MainActor @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let previous = accountSerialTail[accountID]

        // T crosses a Task boundary — wrap in a @unchecked Sendable box
        // (declared at module scope because Swift doesn't allow nested
        // generic types in a generic function).
        let box = SyncSerialBox<T>()

        let task = Task { @MainActor in
            await previous?.value
            do {
                box.result = .success(try await op())
            } catch {
                box.result = .failure(error)
            }
        }
        accountSerialTail[accountID] = task
        await task.value

        switch box.result {
        case .success(let value)?: return value
        case .failure(let runError)?: throw runError
        case .none:
            // Task completed without setting result — impossible barring
            // runtime bug. Surface as explicit error rather than fatalError
            // so the caller can log/retry.
            throw SyncServiceError.serialQueueFailure
        }
    }

    /// Same chaining pattern as `runSerializedPerAccount`, but on a separate
    /// tail for the command/body-fetch socket. Independent of the sync lock —
    /// a stalled backfill never blocks user-initiated body loads.
    @discardableResult
    func runCommandSerializedPerAccount<T: Sendable>(
        _ accountID: UUID,
        _ op: @MainActor @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let previous = accountCommandSerialTail[accountID]
        let box = SyncSerialBox<T>()
        let task = Task { @MainActor in
            await previous?.value
            do {
                box.result = .success(try await op())
            } catch {
                box.result = .failure(error)
            }
        }
        accountCommandSerialTail[accountID] = task
        await task.value
        switch box.result {
        case .success(let value)?: return value
        case .failure(let runError)?: throw runError
        case .none: throw SyncServiceError.serialQueueFailure
        }
    }

    // MARK: - IMAP service lifecycle

    /// Returns cached IMAPService or creates one. For OAuth accounts,
    /// call `wireTokenProvider` after to set the dynamic token provider.
    func getOrCreateIMAPService(for account: Account) -> IMAPService {
        if let existing = imapServices[account.id] { return existing }
        let kc = keychain
        let service = IMAPService(account: account, keychain: kc)
        imapServices[account.id] = service
        return service
    }

    /// Mark every cached IMAPService (both sync + command pools) as needing
    /// a NOOP health probe before its next command. Called from foreground /
    /// wake observers so stale TCP sockets that survived suspend get caught
    /// before they poison a SELECT.
    func markAllConnectionsNeedProbe() async {
        for (_, imap) in imapServices {
            await imap.markNeedsProbe()
        }
        for (_, imap) in commandIMAPServices {
            await imap.markNeedsProbe()
        }
    }

    /// Command/body-fetch socket. Second IMAP connection per account, kept
    /// separate from the sync socket so user-triggered reads don't race with
    /// IDLE / backfill / STATUS. Call `wireTokenProvider` after for OAuth.
    func getOrCreateCommandIMAPService(for account: Account) -> IMAPService {
        if let existing = commandIMAPServices[account.id] { return existing }
        let service = IMAPService(account: account, keychain: keychain)
        commandIMAPServices[account.id] = service
        return service
    }

    /// Wire dynamic token provider before first connect (§9.9).
    /// Must be awaited — not fire-and-forget.
    func wireTokenProvider(for account: Account, imap: IMAPService) async {
        guard account.authType == .oauth2, let auth = authService else { return }
        let accountID = account.id
        await imap.setAccessTokenProvider {
            try await auth.currentAccessToken(for: accountID)
        }
    }

    /// Drain offline queue before a sync-tick (Thunderbird parity §3a).
    /// No-op when queue is empty or another drain is in flight.
    /// OfflineQueueService.drain itself is re-entrancy-guarded via isDraining.
    func drainOfflineQueueIfNeeded() async {
        guard let queue = offlineQueue else { return }
        if queue.isDraining { return }
        if queue.pendingCount == 0 { return }
        _ = await queue.drain { [weak self] action in
            guard let self else { return }
            try await self.executeQueuedAction(action)
        }
    }

    /// Atomically mark an account as needing re-authentication.
    /// Triggers the orange banner via ValueObservation on `accounts.auth_state`,
    /// freezes the offline queue, and cancels any in-flight body prefetch
    /// (which would otherwise hammer the broken connection).
    ///
    /// Called when an auth error survives a token-refresh round-trip — i.e.
    /// the refresh-token rotation succeeded but the new access token is
    /// rejected by the IMAP server (Google scenario: user revoked app access
    /// in account settings, or scope changed server-side).
    func markNeedsReauth(accountID: UUID, reason: String) {
        let repo = AccountRepository(pool: pool, keychain: keychain)
        try? repo.setAuthState(.needsReauth, for: accountID)
        LogService.log(.warning, .auth, "Marked needsReauth",
                       detail: "account=\(accountID) reason=\(reason)")
        cancelAllPrefetch()
    }

    /// Detect IMAP authentication errors regardless of server error message format.
    static func isAuthError(_ error: Error) -> Bool {
        let desc = "\(error)"
        return desc.contains("AUTHENTICATIONFAILED")
            || desc.contains("Invalid credentials")
            || desc.contains("Authentication failed")
            || desc.contains("not advertised by server")
            || error is IMAPServiceError && "\(error)".contains("auth")
    }

    /// Fetch raw RFC822 source for View Source. Runs on the command socket
    /// so it never races with sync/IDLE on the primary connection.
    func fetchRawSource(messageID: UUID) async throws -> String? {
        guard let data = try await fetchRawSourceData(messageID: messageID) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// Byte-accurate RFC822 source for Save As (preserves non-UTF-8 bytes).
    func fetchRawSourceData(messageID: UUID) async throws -> Data? {
        let ctx: (uid: UInt32, folder: Folder, account: Account)? = try await pool.read { db in
            guard let msg = try Message.fetchOne(db, key: messageID),
                  let folder = try Folder.fetchOne(db, key: msg.folderID),
                  let account = try Account.fetchOne(db, key: msg.accountID)
            else { return nil }
            return (msg.uid, folder, account)
        }
        guard let ctx else { return nil }

        return try await runCommandSerializedPerAccount(ctx.account.id) { [weak self] in
            guard let self else { return nil }
            let imap = self.getOrCreateCommandIMAPService(for: ctx.account)
            await self.wireTokenProvider(for: ctx.account, imap: imap)
            if await !imap.isConnected { try await imap.connect() }
            try await imap.ensureFolderSelected(ctx.folder.path)
            return try await imap.fetchRawMessage(uid: ctx.uid)
        }
    }

    /// Lookup message ID by IMAP UID + folder (for notification navigation).
    func messageID(uid: UInt32, folderID: UUID) async -> UUID? {
        try? await pool.read { db in
            try UUID.fetchOne(db, sql:
                "SELECT id FROM messages WHERE folder_id = ? AND uid = ?",
                arguments: [folderID, uid])
        }
    }

    // MARK: - Errors

    enum SyncServiceError: Error {
        case serialQueueFailure
    }

    func disconnectAll() async {
        for (_, imap) in imapServices {
            await imap.disconnect()
        }
        for (_, imap) in commandIMAPServices {
            await imap.disconnect()
        }
        imapServices.removeAll()
        commandIMAPServices.removeAll()
        isOnline = false
    }

    /// Tear down transport + IDLE for a deleted account. IDLE tasks are keyed
    /// by folder path (not account ID) and paths can collide across accounts
    /// ("INBOX"), so we cancel all IDLE sessions — remaining accounts re-IDLE
    /// on their next sync cycle.
    func removeAccount(id: UUID) async {
        for (_, task) in idleTasks { task.cancel() }
        idleTasks.removeAll()

        if let imap = imapServices.removeValue(forKey: id) {
            await imap.disconnect()
        }
        if let cmdImap = commandIMAPServices.removeValue(forKey: id) {
            await cmdImap.disconnect()
        }
        smtpServiceStore.removeValue(forKey: id)

        // Cancel any running syncs for this account
        runningSyncs[id]?.cancel()
        runningSyncs.removeValue(forKey: id)
    }
}
