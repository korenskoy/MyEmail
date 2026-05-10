//
//  SyncService+Pagination.swift
//  MyEmail
//
//  Thunderbird-style eager model: all headers are downloaded on first sync,
//  so pagination is a safety net rather than the primary loading path.
//  `loadOlderMessages` simply re-triggers `incrementalSync` — which performs
//  an unbounded backfill for any UID below the current local floor.
//

import Foundation
import GRDB

extension SyncService {

    /// Safety-net "load older" trigger. In the Thunderbird eager model every
    /// envelope is already downloaded on first sync, so this function just
    /// re-runs `incrementalSync` to repair any gap. `count` is accepted for
    /// API back-compat with the pagination footer and ignored internally.
    /// Returns `false` once reconcile completes — the pagination footer
    /// clears on the next ValueObservation tick.
    @discardableResult
    func loadOlderMessages(
        folderID: UUID,
        count: Int = 200
    ) async -> Bool {
        let context: (folder: Folder, account: Account)? =
            try? await pool.read { db in
                guard let folder = try Folder.fetchOne(db, key: folderID),
                      let account = try Account.fetchOne(db, key: folder.accountID)
                else { return nil }
                return (folder, account)
            }

        guard let ctx = context else {
            LogService.log(.debug, .sync, "loadOlderMessages: folder/account not found")
            return false
        }

        let imap = getOrCreateIMAPService(for: ctx.account)
        await wireTokenProvider(for: ctx.account, imap: imap)

        isSyncing = true
        defer { isSyncing = false }

        do {
            if await !imap.isConnected { try await imap.connect() }

            try await incrementalSync(
                account: ctx.account,
                folderID: folderID,
                folderPath: ctx.folder.path,
                imap: imap
            )

            let updated = try await pool.read { db in
                try Folder.fetchOne(db, key: folderID)
            }
            return updated?.moreMessages != .false
        } catch {
            LogService.log(.error, .sync, "Failed to load older messages",
                           detail: "\(error)")
            return false
        }
    }
}
