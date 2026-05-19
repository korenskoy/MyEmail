//
//  IMAPService+Operations.swift
//  MyEmail
//
//  IMAP operations: flags, move, delete. All batched via UIDSet (§9.1).
//

import Foundation
import SwiftMail

extension IMAPService {

    // MARK: - Flags

    func addFlags(_ flags: [Flag], uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        let set = UIDSet(uids.map { UID($0) })
        let srv = try await requireServer()
        try await srv.store(flags: flags, on: set, operation: StoreData.StoreType.add)
    }

    func removeFlags(_ flags: [Flag], uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        let set = UIDSet(uids.map { UID($0) })
        let srv = try await requireServer()
        try await srv.store(flags: flags, on: set, operation: StoreData.StoreType.remove)
    }

    func markRead(uids: [UInt32]) async throws {
        try await addFlags([Flag.seen], uids: uids)
    }

    func markUnread(uids: [UInt32]) async throws {
        try await removeFlags([Flag.seen], uids: uids)
    }

    func setFlagged(_ flagged: Bool, uids: [UInt32]) async throws {
        if flagged {
            try await addFlags([Flag.flagged], uids: uids)
        } else {
            try await removeFlags([Flag.flagged], uids: uids)
        }
    }

    // MARK: - Move (batched, §9.1)

    func moveMessages(uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        let set = UIDSet(uids.map { UID($0) })
        let srv = try await requireServer()
        try await srv.move(messages: set, to: destination)
    }

    // MARK: - Archive (SwiftMail built-in: resolves via SPECIAL-USE or name fallback)

    func archiveMessages(uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        let set = UIDSet(uids.map { UID($0) })
        let srv = try await requireServer()
        try await srv.archive(messages: set)
    }

    // MARK: - Delete (STORE \Deleted + EXPUNGE)

    func deleteMessages(uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        let set = UIDSet(uids.map { UID($0) })
        let srv = try await requireServer()
        try await srv.store(flags: [Flag.deleted], on: set, operation: StoreData.StoreType.add)
        do {
            try await srv.expunge(messages: set)
        } catch {
            let desc = "\(error)"
            if desc.contains("commandNotSupported") || desc.contains("not supported") {
                LogService.log(.warning, .imap,
                    "UID EXPUNGE not supported, falling back to global EXPUNGE")
                try await srv.expunge()
            } else {
                throw error
            }
        }
    }

    // MARK: - SEARCH

    /// `UID EXTENDED-SEARCH` → matching UIDs as `Set<UInt32>`.
    /// Used by every UID-search callsite. We never request server-side sort
    /// or PARTIAL, so `result.all` is the only field we read; SwiftMail
    /// synthesises it from a plain `SEARCH` response when ESEARCH is absent.
    func uidSearchAsSet(
        identifierSet: MessageIdentifierSet<UID>? = nil,
        criteria: [SearchCriteria]
    ) async throws -> Set<UInt32> {
        let srv = try await requireServer()
        let result: ExtendedSearchResult<UID> = try await srv.extendedSearch(
            identifierSet: identifierSet, criteria: criteria, calendar: .current
        )
        return Set((result.all?.toArray() ?? []).map(\.value))
    }

    /// IMAP SEARCH with given criteria. Returns matching UIDs.
    func searchMessages(criteria: [SearchCriteria]) async throws -> Set<UInt32> {
        try await uidSearchAsSet(criteria: criteria)
    }

    /// UID SEARCH HEADER "Message-ID" "<...>" — returns UIDs matching the
    /// given RFC 5322 Message-ID in the currently selected folder. Used by
    /// rewriteSubject fallback when APPEND returns no UIDPLUS reply.
    /// Caller selects folder beforehand.
    func searchByMessageID(_ messageID: String) async throws -> [UInt32] {
        let trimmed = messageID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let result = try await searchMessages(
            criteria: [.header("Message-ID", trimmed)]
        )
        return Array(result).sorted()
    }

    /// UID SEARCH scoped to a UID range (Thunderbird §5.2 step 5).
    /// `UID SEARCH <startUID>:<upperUID> <criteria>` — returns UIDs in range.
    ///
    /// `upperUID == nil` → open-ended `startUID:*`. **Only safe for small
    /// folders**: a single SEARCH response line larger than 8 KB trips
    /// `PayloadTooLargeError` in swift-nio-imap's `NIOSingleStepByteToMessageProcessor`
    /// (hardcoded `IMAPDefaults.lineLengthLimit`). Callers aware of folder size
    /// should pass a concrete `upperUID` (e.g. `uidNext - 1`); this method
    /// then batches the SEARCH into 1500-UID chunks (~7.5 KB per response),
    /// merging results before return.
    func searchInUIDRange(
        from startUID: UInt32,
        to upperUID: UInt32? = nil,
        criteria: [SearchCriteria] = []
    ) async throws -> Set<UInt32> {
        guard let upper = upperUID, upper >= startUID else {
            let uidSet = MessageIdentifierSet<UID>(UID(startUID)...)
            return try await uidSearchAsSet(identifierSet: uidSet, criteria: criteria)
        }

        // Chunk to keep each SEARCH response under the 8 KB line-length
        // limit (`IMAPDefaults.lineLengthLimit` in swift-nio-imap). Budget
        // worst-case 11 bytes per UID (10 digits + separator) — Gmail's
        // All Mail UIDs reach 6+ digits. 500 UIDs × 11 ≈ 5.5 KB, safe.
        let chunkSize: UInt32 = 500
        var merged: Set<UInt32> = []
        var chunkStart = startUID
        while chunkStart <= upper {
            let chunkEnd = min(upper, chunkStart &+ (chunkSize - 1))
            let uidSet = MessageIdentifierSet<UID>(UID(chunkStart)...UID(chunkEnd))
            merged.formUnion(
                try await uidSearchAsSet(identifierSet: uidSet, criteria: criteria)
            )
            // `&+ 1` guards against overflow on chunkEnd == UInt32.max.
            if chunkEnd == UInt32.max { break }
            chunkStart = chunkEnd + 1
        }
        return merged
    }

    /// Fetch flags for a set of UIDs (Thunderbird §5.2 step 8).
    /// Single round-trip replaces 5 separate SEARCH commands.
    func fetchFlagsForUIDs(_ uids: [UInt32]) async throws -> [(uid: UInt32, flags: [Flag])] {
        guard !uids.isEmpty else { return [] }
        let infos = try await fetchHeadersBySet(uids)
        return infos.compactMap { info in
            guard let uid = info.uid else { return nil }
            return (uid: uid.value, flags: info.flags)
        }
    }

    /// Thunderbird-parity full-folder reconcile: `UID FETCH 1:* (UID FLAGS)`.
    /// Returns every non-expunged UID plus its flags in one stream — safe
    /// even on 100k+ folders because each response line is self-contained
    /// (per-message, ~50 bytes) and never hits the 8 KB SEARCH line limit.
    /// Pass `changedSince` for CONDSTORE delta (`nsImapProtocol.cpp:4261-4268`).
    func fetchAllFlags(
        uidRange: PartialRangeFrom<UID> = UID(1)...,
        changedSince: UInt64? = nil
    ) async throws -> [(uid: UInt32, flags: [Flag], modSeq: UInt64?)] {
        let srv = try await requireServer()
        let infos = try await srv.fetchFlagsOnly(
            using: UIDSet(uidRange), changedSince: changedSince
        )
        return infos.compactMap { info in
            guard let uid = info.uid else { return nil }
            return (uid: uid.value, flags: info.flags, modSeq: info.modSequence)
        }
    }

    /// Closed-range variant for bounded reconcile passes (e.g. backfill
    /// below a UID floor, avoids fetching the full folder when only the
    /// tail matters).
    func fetchAllFlags(
        uidRange: ClosedRange<UInt32>,
        changedSince: UInt64? = nil
    ) async throws -> [(uid: UInt32, flags: [Flag], modSeq: UInt64?)] {
        let srv = try await requireServer()
        let set = MessageIdentifierSet<UID>(UID(uidRange.lowerBound)...UID(uidRange.upperBound))
        let infos = try await srv.fetchFlagsOnly(
            using: set, changedSince: changedSince
        )
        return infos.compactMap { info in
            guard let uid = info.uid else { return nil }
            return (uid: uid.value, flags: info.flags, modSeq: info.modSequence)
        }
    }

    // MARK: - CONDSTORE / RFC 7162 delta fetch

    /// Whether the current IMAP connection advertised CONDSTORE (RFC 7162).
    var supportsCondStore: Bool {
        get async {
            guard let srv = try? await requireServer() else { return false }
            return await srv.supportsCondStore
        }
    }

    /// Whether the current IMAP connection advertised QRESYNC (RFC 7162 §3.2).
    /// QRESYNC implies CONDSTORE.
    var supportsQResync: Bool {
        get async {
            guard let srv = try? await requireServer() else { return false }
            return await srv.supportsQResync
        }
    }


    /// CONDSTORE delta FETCH (RFC 7162 §3.1.2). Returns `MessageInfo` (uid,
    /// flags, internalDate, fullHeader, modSequence — no envelope/bodyStructure)
    /// for every UID whose MODSEQ > `changedSince`. Single round-trip over `1:*`
    /// — server filters by MODSEQ. Each response line is per-message (≤1 KB),
    /// so the 8 KB line-length limit in swift-nio-imap never trips here —
    /// unlike an open-ended UID SEARCH over a large mailbox.
    func fetchChangedInfos(changedSince: UInt64) async throws -> [MessageInfo] {
        let srv = try await requireServer()
        return try await srv.fetchMessageInfos(
            uidRange: UID(1)...,
            options: .noEnvelope,
            changedSince: changedSince
        )
    }

    /// Delta FETCH of messages whose MODSEQ > `changedSince` (RFC 7162 §3.1.2).
    /// Projection over `fetchChangedInfos` that returns only `(uid, flags,
    /// modSequence)` for the legacy flag-only call site. Prefer
    /// `fetchChangedInfos` for new code that needs envelopes too.
    func fetchChangedFlags(changedSince: UInt64)
        async throws -> [(uid: UInt32, flags: [Flag], modSequence: UInt64?)]
    {
        let infos = try await fetchChangedInfos(changedSince: changedSince)
        return infos.compactMap { info in
            guard let uid = info.uid else { return nil }
            return (uid: uid.value, flags: info.flags, modSequence: info.modSequence)
        }
    }

    // MARK: - Create folder (IMAP CREATE)

    func createFolder(path: String) async throws {
        let srv = try await requireServer()
        try await srv.createMailbox(path)
    }

    // MARK: - Raw IMAP commands (EXAMINE — not in SwiftMail)

    /// IMAP DELETE mailbox — RFC 3501 §6.3.4
    func deleteMailbox(_ path: String) async throws {
        let srv = try await requireServer()
        try await srv.deleteMailbox(path)
    }

    /// IMAP RENAME mailbox — RFC 3501 §6.3.5
    func renameMailbox(from oldPath: String, to newPath: String) async throws {
        let srv = try await requireServer()
        try await srv.renameMailbox(from: oldPath, to: newPath)
    }

    /// IMAP EXAMINE (read-only SELECT) — RFC 3501 §6.3.2
    func examineFolder(_ path: String) async throws -> ExamineResult {
        let raw = try await createAuthenticatedRawClient()
        defer { Task { await raw.logout() } }
        return try await raw.examine(path)
    }

    // MARK: - STATUS (lightweight poll, no SELECT)

    /// IMAP STATUS command — returns counts + UIDs without selecting the folder.
    /// Used for periodic polling of all folders to detect changes cheaply.
    func mailboxStatus(_ path: String) async throws -> Mailbox.Status {
        let srv = try await requireServer()
        return try await srv.mailboxStatus(path)
    }

    // MARK: - APPEND (save to Sent, §6.5)

    /// IMAP APPEND — saves a composed email to the given folder with \Seen flag.
    func appendMessage(_ email: SwiftMail.Email, to mailbox: String) async throws {
        let srv = try await requireServer()
        try await srv.append(email: email, to: mailbox, flags: [.seen])
    }

    /// IMAP APPEND raw RFC822 message with explicit flags. Returns new UID if server supports UIDPLUS.
    @discardableResult
    func appendRawMessage(_ raw: String, to mailbox: String, flags: [Flag], date: Date?) async throws -> UInt32? {
        let srv = try await requireServer()
        let result = try await srv.append(rawMessage: raw, to: mailbox, flags: flags, internalDate: date)
        return result.firstUID?.value
    }

    // MARK: - IDLE

    /// Legacy IDLE on the currently selected folder.
    func startIDLE() async throws -> AsyncStream<IMAPServerEvent> {
        let srv = try await requireServer()
        return try await srv.idle()
    }

    /// Multi-folder IDLE (Pattern #3): dedicated idle connection on a specific
    /// folder. SwiftMail opens a separate connection so it doesn't conflict
    /// with the primary selection used for FETCH/SELECT.
    func startIDLE(on folderPath: String) async throws -> IMAPIdleSession {
        let srv = try await requireServer()
        return try await srv.idle(on: folderPath)
    }

    // MARK: - NOOP

    func noop() async throws -> [IMAPServerEvent] {
        let srv = try await requireServer()
        return try await srv.noop()
    }
}
