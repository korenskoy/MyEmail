//
//  IMAPService.swift
//  MyEmail
//
//  Actor wrapping SwiftMail.IMAPServer. One instance per account.
//  Serializes all IMAP operations through the actor mailbox — no
//  ad-hoc parallel connections (§3.6: 2 per account budget).
//
//  All SwiftMail calls are `await` — IMAPServer is itself an actor (§8.5).
//

import Foundation
import GRDB
import SwiftMail

actor IMAPService {
    private let account: Account
    private let keychain: KeychainService
    private var server: IMAPServer?

    /// Dynamic token provider — AuthService.currentAccessToken refreshes if near expiry
    private var accessTokenProvider: (@Sendable () async throws -> String)?

    // MARK: - SELECT state
    private(set) var lastSelection: Mailbox.Selection?
    private(set) var selectedFolderPath: String?

    // MARK: - Health state (Thunderbird parity §9.X)
    /// Timestamp of last successful connect+auth. `nil` while disconnected.
    private(set) var connectedAt: Date?
    /// Last successful round-trip (CONNECT, SELECT, NOOP). Used by the
    /// probe-skip freshness window so we don't NOOP-thrash a hot socket.
    private(set) var lastActivityAt: Date?
    /// Set by external observers (foreground / wake) to force a NOOP probe
    /// on the next command, even if `lastActivityAt` looks fresh.
    private(set) var needsHealthProbe: Bool = false

    /// NOOP probe timeout — TB short-fail policy. Anything slower is treated
    /// as a dead socket.
    private static let probeTimeout: TimeInterval = 5
    /// Skip the probe when the last successful round-trip is newer than this.
    /// 60s matches our STATUS-poll cadence, so two probes per ping never happen.
    private static let freshnessWindow: TimeInterval = 60
    /// Hard cap on a single connection's lifetime — force-recycle past this.
    /// TB doesn't enforce this directly, but its 24h IDLE rotation + auto-sync
    /// pauses approximate the same outcome.
    private static let maxConnectionAge: TimeInterval = 4 * 3600

    init(account: Account, keychain: KeychainService) {
        self.account = account
        self.keychain = keychain
    }

    // MARK: - Connection

    var isConnected: Bool { server != nil }

    /// Set a dynamic token provider that refreshes automatically (§9.9).
    /// Called from SyncService after constructing IMAPService.
    func setAccessTokenProvider(_ provider: @escaping @Sendable () async throws -> String) {
        self.accessTokenProvider = provider
    }

    func connect() async throws {
        // Clear stale SELECT state from prior connection
        self.lastSelection = nil
        self.selectedFolderPath = nil

        let useTLS = account.imapSecurity != .none
        let srv = IMAPServer(
            host: account.imapHost,
            port: account.imapPort,
            useTLS: useTLS
        )

        try await srv.connect()

        switch account.authType {
        case .oauth2:
            let email = account.email

            // Initial auth with current token on primary connection.
            let token: String
            if let provider = accessTokenProvider {
                token = try await provider()
            } else {
                token = try keychain.oauthAccessToken(for: account.id)
            }
            try await srv.authenticateXOAUTH2(email: email, accessToken: token)

            // MUST be set AFTER authenticateXOAUTH2: that call overwrites
            // SwiftMail's stored `authentication` with a static closure
            // capturing this token string, which is then reused by every
            // per-folder IDLE connection and auto-reconnect inside the
            // IDLE cycle task. Re-installing the dynamic provider makes
            // each fresh reauth fetch a live token (AuthService refreshes
            // if near expiry), matching Thunderbird's proactive-refresh
            // model (§9.9, rule #15).
            if let provider = accessTokenProvider {
                await srv.setXOAUTH2AccessTokenProvider(
                    email: email,
                    accessTokenProvider: provider
                )
            }

        case .plain:
            try await srv.login(
                username: account.email,
                password: try keychain.password(for: account.id)
            )
        }

        // RFC 2971: Send IMAP ID after auth (best-practice, helps server-side debugging)
        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            let clientID = Identification(name: "MyEmail", version: version, os: "macOS")
            _ = try await srv.id(clientID)
        } catch {
            // Non-fatal — server may not support ID extension
            LogService.log(.debug, .imap, "IMAP ID not supported", detail: "\(error)")
        }

        self.server = srv
        let now = Date()
        self.connectedAt = now
        self.lastActivityAt = now
        self.needsHealthProbe = false
        LogService.log(.info, .imap, "Connected \(account.email)")
    }

    func disconnect() async {
        guard let srv = server else { return }
        try? await srv.logout()
        try? await srv.disconnect()
        self.server = nil
        self.lastSelection = nil
        self.selectedFolderPath = nil
        self.connectedAt = nil
        self.lastActivityAt = nil
        self.needsHealthProbe = false
        LogService.log(.info, .imap, "Disconnected \(account.email)")
    }

    // MARK: - Health probe (Thunderbird `m_needNoop` / `gTCPKeepalive` parity)

    /// External signal that the connection may have stalled — e.g. app came
    /// back to foreground, system woke from sleep. Next entry-point command
    /// will run `healthProbe()` before issuing the real operation.
    ///
    /// Also invalidates the cached `selectedFolderPath`/`lastSelection`:
    /// NOOP is stateless and answers fine on a half-broken Gmail session
    /// where the server has implicitly dropped our SELECTED state. The next
    /// `ensureFolderSelected` must perform a real SELECT — relying on the
    /// pre-suspend cache is what produced `BAD UID FETCH not allowed now`
    /// after a successful probe.
    func markNeedsProbe() {
        guard isConnected else { return }
        self.needsHealthProbe = true
        self.selectedFolderPath = nil
        self.lastSelection = nil
    }

    /// Age of the current connection in seconds, or `nil` if disconnected.
    func ageInSeconds() -> TimeInterval? {
        connectedAt.map { Date().timeIntervalSince($0) }
    }

    /// Send a NOOP with a short timeout. Returns `true` if the socket
    /// answered cleanly within `probeTimeout`. Does NOT throw — caller decides
    /// whether to reconnect on `false`.
    ///
    /// Updates `lastActivityAt` on success and clears `needsHealthProbe`.
    func healthProbe() async -> Bool {
        guard let srv = server else { return false }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await srv.noop()
                }
                group.addTask { [timeout = Self.probeTimeout] in
                    try await Task.sleep(for: .seconds(timeout))
                    throw IMAPServiceError.probeTimedOut
                }
                _ = try await group.next()
                group.cancelAll()
            }
            self.lastActivityAt = Date()
            self.needsHealthProbe = false
            return true
        } catch {
            LogService.log(.debug, .imap,
                "Health probe failed for \(account.email)",
                detail: "\(error)")
            return false
        }
    }

    /// Gate called from every entry-point before issuing IMAP commands.
    /// Mirrors TB's `m_needNoop` flag + age-based connection recycling.
    ///
    /// Logic:
    ///   1. Disconnected? Nothing to do — caller will explicitly `connect()`.
    ///   2. Past hard-age cap? Force reconnect (no probe — assume dead).
    ///   3. Fresh activity (< `freshnessWindow`) AND not explicitly stale? Skip.
    ///   4. Otherwise: NOOP probe → on failure, reconnect with last folder.
    private func ensureHealthyConnection() async throws {
        guard isConnected else { return }

        if let age = ageInSeconds(), age > Self.maxConnectionAge {
            LogService.log(.info, .imap,
                "Connection age \(Int(age))s exceeds cap; force-reconnecting",
                detail: account.email)
            try await reconnectInternal()
            return
        }

        if !needsHealthProbe,
           let last = lastActivityAt,
           Date().timeIntervalSince(last) < Self.freshnessWindow {
            return
        }

        let healthy = await healthProbe()
        if !healthy {
            LogService.log(.info, .imap,
                "Probe failed; reconnecting",
                detail: account.email)
            try await reconnectInternal()
        }
    }

    /// Tear down + rebuild the socket on the same actor, restoring the last
    /// SELECT if any. Keeps `accessTokenProvider` (it's actor-stored).
    private func reconnectInternal() async throws {
        let lastFolder = selectedFolderPath
        await disconnect()
        try await connect()
        if let lastFolder {
            _ = try await selectFolderRaw(lastFolder)
        }
    }

    // MARK: - SELECT

    @discardableResult
    func selectFolder(_ path: String) async throws -> Mailbox.Selection {
        try await ensureHealthyConnection()
        return try await selectFolderRaw(path)
    }

    /// Raw SELECT without probe gate — used by `reconnectInternal` and from
    /// the probe-gated `selectFolder` itself (where probing already happened
    /// in the outer call). Goes through `serverOrThrow` to avoid recursion.
    private func selectFolderRaw(_ path: String) async throws -> Mailbox.Selection {
        let srv = try serverOrThrow()
        let sel = try await srv.selectMailbox(path)
        self.lastSelection = sel
        self.selectedFolderPath = path
        self.lastActivityAt = Date()
        return sel
    }

    /// Resume SELECT with QRESYNC parameters (RFC 7162 §3.2.5). The returned
    /// `Mailbox.Selection` carries `highestModSequence` (new server watermark)
    /// and `vanishedUIDs` (UIDs expunged since the client's `modSeq`), so the
    /// ghost set arrives inline instead of needing a separate SEARCH.
    @discardableResult
    func selectFolderWithQResync(
        _ path: String,
        uidValidity: UInt32,
        modSeq: UInt64,
        knownUids: Set<UInt32>? = nil
    ) async throws -> Mailbox.Selection {
        try await ensureHealthyConnection()
        let srv = try serverOrThrow()
        let sel = try await srv.selectMailboxWithQResync(
            path, uidValidity: uidValidity, modSeq: modSeq, knownUIDs: knownUids
        )
        self.lastSelection = sel
        self.selectedFolderPath = path
        self.lastActivityAt = Date()
        return sel
    }

    /// Skip re-SELECT if folder already active on this connection.
    /// Use for read-only operations (search, body fetch, pagination).
    /// Still runs the probe gate so a cached-SELECT shortcut doesn't bypass
    /// stale-socket detection after wake/foreground.
    @discardableResult
    func ensureFolderSelected(_ path: String) async throws -> Mailbox.Selection {
        try await ensureHealthyConnection()
        if selectedFolderPath == path, let sel = lastSelection {
            return sel
        }
        return try await selectFolderRaw(path)
    }

    // MARK: - Fetch headers

    /// Fetch recent N messages using sequence numbers (RFC 4549 §4.1).
    /// Sequence numbers are always dense (1...EXISTS), no sparse UID gaps.
    func fetchRecentHeaders(
        in folderPath: String,
        count: Int = 200
    ) async throws -> [MessageInfo] {
        let sel = try await selectFolder(folderPath)
        let total = UInt32(sel.messageCount)
        guard total > 0 else { return [] }
        let from = total > UInt32(count) ? total - UInt32(count) + 1 : 1
        let srv = try await requireServer()
        return try await srv.fetchMessageInfos(
            sequenceRange: SequenceNumber(from)...SequenceNumber(total),
            options: .noEnvelope
        )
    }

    /// Fetch headers for every message in the selected folder via
    /// `FETCH 1:<EXISTS>` (Thunderbird-style eager enumeration — mirrors
    /// `GetMsgHdrsToDownload` in `nsImapProtocol.cpp`). FETCH responses are
    /// per-message (~1 KB each), so the 8 KB line-length limit that breaks
    /// open-ended UID SEARCH doesn't apply here.
    ///
    /// NOTE: For large mailboxes (≥500 messages) the caller should prefer
    /// `fetchHeaders(sequenceRange:)` in batches of ~500 to avoid hitting
    /// the IMAP command timeout on the single FETCH (see Thunderbird's
    /// `FolderMsgDumpLoop` in `nsImapProtocol.cpp:4539`).
    func fetchAllHeaders(in folderPath: String) async throws -> [MessageInfo] {
        let sel = try await selectFolder(folderPath)
        let total = UInt32(sel.messageCount)
        guard total > 0 else { return [] }
        let srv = try await requireServer()
        return try await srv.fetchMessageInfos(
            sequenceRange: SequenceNumber(1)...SequenceNumber(total),
            options: .noEnvelope
        )
    }

    /// Fetch headers for a sequence-number range. Thin wrapper so callers
    /// can chunk a full-folder enumeration into ~500-sequence batches.
    /// SwiftMail `fetchMessageInfosBulk` sends a single `FETCH lo:hi (...)`
    /// (no internal chunking for sequence ranges), so the whole range
    /// streams back in one server round-trip.
    func fetchHeaders(sequenceRange: ClosedRange<SequenceNumber>) async throws -> [MessageInfo] {
        let srv = try await requireServer()
        return try await srv.fetchMessageInfos(sequenceRange: sequenceRange, options: .noEnvelope)
    }

    /// Fetch headers for a specific UID range (for incremental sync).
    func fetchHeaders(
        uidRange: ClosedRange<UID>
    ) async throws -> [MessageInfo] {
        let srv = try await requireServer()
        return try await srv.fetchMessageInfos(uidRange: uidRange, options: .noEnvelope)
    }

    /// Fetch headers for UIDs >= startUID (open-ended).
    func fetchHeaders(
        from startUID: UID
    ) async throws -> [MessageInfo] {
        let srv = try await requireServer()
        return try await srv.fetchMessageInfos(uidRange: startUID..., options: .noEnvelope)
    }

    /// Fetch raw RFC822 source for a single UID (View Source).
    /// Uses MyEmail fork's chunked 256 KB BODY.PEEK[]<offset.count> fetch so the
    /// channel idles between chunks and unsolicited EXISTS/FLAGS drain cleanly.
    func fetchRawMessage(uid: UInt32) async throws -> Data {
        let srv = try await requireServer()
        return try await srv.fetchRawMessageChunked(identifier: UID(uid))
    }

    /// Pipelined fetch of MIME parts for multiple UIDs (preview snippets).
    func fetchPartsPipelined(
        parts: [(uid: UID, section: Section)]
    ) async throws -> [UID: [(section: Section, data: Data)]] {
        let srv = try await requireServer()
        return try await srv.fetchPartsPipelined(parts: parts)
    }

    /// Fetch headers for a specific set of UIDs (non-contiguous).
    func fetchHeadersBySet(_ uids: [UInt32]) async throws -> [MessageInfo] {
        guard !uids.isEmpty else { return [] }
        var set = UIDSet()
        for uid in uids { set.insert(UID(uid)) }
        let srv = try await requireServer()
        return try await srv.fetchMessageInfosBulk(using: set, options: .noEnvelope)
    }

    /// Fetch flags for a single UID via FETCH (FLAGS). Used by rawHeaderFallback.
    func fetchSingleMessageInfo(uid: UInt32) async throws -> MessageInfo? {
        let srv = try await requireServer()
        return try await srv.fetchMessageInfo(for: UID(uid))
    }

    // MARK: - List all UIDs (for reconcile)

    /// `SEARCH ALL` — returns set of all UIDs in currently selected folder.
    func listAllUIDs() async throws -> Set<UInt32> {
        try await uidSearchAsSet(criteria: [.all])
    }

    // MARK: - List folders

    func listFolders() async throws -> [Mailbox.Info] {
        let srv = try await requireServer()
        return try await srv.listSpecialUseMailboxes()
    }

    func listAllFolders() async throws -> [Mailbox.Info] {
        let srv = try await requireServer()
        return try await srv.listMailboxes()
    }

    // MARK: - Raw client factory (for commands SwiftMail doesn't expose)

    /// Create an authenticated raw IMAP client for DELETE, RENAME, EXAMINE.
    /// Opens a separate short-lived connection.
    func createAuthenticatedRawClient() async throws -> IMAPRawClient {
        let raw = IMAPRawClient(
            host: account.imapHost,
            port: UInt16(account.imapPort),
            security: account.imapSecurity
        )
        try await raw.connect()

        switch account.authType {
        case .oauth2:
            if let provider = accessTokenProvider {
                let token = try await provider()
                try await raw.authenticateXOAUTH2(email: account.email, accessToken: token)
            } else {
                let token = try keychain.oauthAccessToken(for: account.id)
                try await raw.authenticateXOAUTH2(email: account.email, accessToken: token)
            }
        case .plain:
            let password = try keychain.password(for: account.id)
            try await raw.login(user: account.email, password: password)
        }
        return raw
    }

    // MARK: - Private

    /// Probe-gated server accessor. All entry-point IMAP ops MUST use this
    /// (Thunderbird `m_needNoop` parity): runs `ensureHealthyConnection()`
    /// which does a short-timeout NOOP probe + auto-reconnect when the
    /// socket has been idle, marked stale by foreground/wake observers, or
    /// past the hard age cap. Cheap fast-path when `lastActivityAt` is fresh.
    func requireServer() async throws -> IMAPServer {
        try await ensureHealthyConnection()
        return try serverOrThrow()
    }

    /// Server accessor without probe. Used by code paths where probing
    /// would recurse (probe itself, reconnect) or where the caller has
    /// just made a fresh round-trip (selectFolderRaw after connect).
    private func serverOrThrow() throws -> IMAPServer {
        guard let server else {
            throw IMAPServiceError.notConnected
        }
        return server
    }
}

// MARK: - Errors

enum IMAPServiceError: Error, Sendable {
    case notConnected
    case authenticationFailed
    case folderNotFound(String)
    case probeTimedOut
}
