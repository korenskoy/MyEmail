//
//  SyncService+Search.swift
//  MyEmail
//
//  Hybrid search: local FTS5 (subject/from/to/cc/bcc/list_id/preview/body_text)
//  + server-side IMAP SEARCH + hydration. Results as MessageListItem (§9.4).
//
//  BM25 column order below MUST match FTS5 definition in
//  DatabaseService+Schema.swift.
//

import Foundation
import GRDB
import SwiftMail

extension SyncService {

    /// MessageListItem SELECT columns — shared with AppState (§5.4 projection).
    private static let searchSelectColumns = """
        m.id, m.uid, m.subject, m.from_name, m.from_address,
        m.to_addresses, m.date, m.preview,
        m.is_read, m.is_flagged, m.is_answered,
        m.has_attachments,
        m.thread_id, m.folder_id, m.account_id, m.size, m.interaction_score,
        m.message_id, m.in_reply_to, m."references"
        """

    /// BM25 column weights — higher = more influential on rank.
    /// Order: subject, from_name, from_address, to_search, cc_search, bcc_search,
    ///        list_id, preview, body_text.
    private static let bm25Weights = "20.0, 16.0, 12.0, 8.0, 5.0, 5.0, 12.0, 4.0, 4.0"

    // MARK: - Local FTS5 + predicate search

    func searchLocal(
        query: SearchQuery,
        scope: SearchScope,
        folderID: UUID?,
        accountID: UUID?
    ) async throws -> [MessageListItem] {
        let lowered = LoweredSearchQuery(query)

        let results = try await pool.read { db in
            var clauses: [String] = []
            var args: [any DatabaseValueConvertible] = []

            // Build FTS MATCH if any full-text component exists.
            let ftsMatch = Self.buildFTSMatch(query)
            let useFTS = ftsMatch != nil

            var joins = ""
            if useFTS {
                joins += " JOIN messages_fts ON m.rowid = messages_fts.rowid"
                clauses.append("messages_fts MATCH ?")
                args.append(ftsMatch!)
            }

            // Scope
            let (scopeWhere, scopeArgs) = Self.scopeSQL(
                scope, folderID: folderID, accountID: accountID
            )
            if !scopeWhere.isEmpty {
                clauses.append(scopeWhere)
                args.append(contentsOf: scopeArgs)
            }

            // Date range
            if let after = query.after {
                clauses.append("m.date >= ?")
                args.append(after.timeIntervalSince1970)
            }
            if let before = query.before {
                clauses.append("m.date < ?")
                args.append(before.timeIntervalSince1970)
            }
            // Size
            if let larger = query.largerThan {
                clauses.append("m.size > ?")
                args.append(larger)
            }
            if let smaller = query.smallerThan {
                clauses.append("m.size < ?")
                args.append(smaller)
            }
            // Folder by name (in:) — join folders; case-insensitive compare.
            if let folderName = query.folderName, !folderName.isEmpty {
                joins += " JOIN folders f ON m.folder_id = f.id"
                clauses.append("(LOWER(f.name) = ? OR LOWER(f.path) = ? OR LOWER(f.special_use) = ?)")
                let v = folderName.lowercased()
                args.append(v); args.append(v); args.append(v)
            }
            // Flag filter
            if let isFilter = query.isFilter {
                switch isFilter {
                case .unread:   clauses.append("m.is_read = 0")
                case .read:     clauses.append("m.is_read = 1")
                case .flagged:  clauses.append("m.is_flagged = 1")
                case .unflagged: clauses.append("m.is_flagged = 0")
                }
            }
            // Attachment filter
            if let hasFilter = query.hasFilter {
                switch hasFilter {
                case .attachment:   clauses.append("m.has_attachments = 1")
                case .noattachment: clauses.append("m.has_attachments = 0")
                }
            }

            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")

            // Ranking: BM25 when FTS in play; date DESC otherwise.
            let orderSQL: String
            if useFTS {
                orderSQL = """
                    ORDER BY (bm25(messages_fts, \(Self.bm25Weights)) * 1000.0
                              - m.interaction_score * 100.0
                              - m.date / 604800.0) ASC
                    """
            } else {
                orderSQL = "ORDER BY m.date DESC"
            }

            let sql = """
                SELECT \(Self.searchSelectColumns)
                FROM messages m
                \(joins)
                \(whereSQL)
                \(orderSQL)
                LIMIT 500
                """

            let statementArgs = StatementArguments(args) ?? StatementArguments()
            return try MessageListItem.fetchAll(db, sql: sql, arguments: statementArgs)
        }

        // Residual client-side filters run outside the DB reader: SQL can't
        // express substring match on multi-value from/to/cc/bcc precisely
        // (e.g. matching both name and email simultaneously). MessageMatcher
        // handles the rest — and doesn't need to hold the pool reader open.
        guard lowered.hasAnyClientFilter else { return results }
        return results.filter { MessageMatcher.matches($0, query: lowered) }
    }

    // MARK: - FTS5 MATCH builder

    /// Compose a single FTS5 MATCH expression from the parsed query.
    /// Returns nil when there is nothing that requires full-text matching
    /// (caller falls back to predicate-only SQL over `messages`).
    nonisolated static func buildFTSMatch(_ q: SearchQuery) -> String? {
        var pieces: [String] = []

        // Freetext AND tokens — match any indexed column.
        for token in q.freetext {
            if let e = ftsEscape(token) { pieces.append(e) }
        }
        // Phrase matches — FTS5 quoted strings match consecutive tokens.
        for phrase in q.phrases {
            if let e = ftsEscape(phrase) { pieces.append(e) }
        }
        // Excludes (NOT).
        for token in q.excludes {
            if let e = ftsEscape(token) { pieces.append("NOT \(e)") }
        }

        // Field operators → column-qualified MATCH.
        // `from:` matches either from_name or from_address.
        for v in q.from {
            if let e = ftsEscape(v) {
                pieces.append("({from_name from_address}:\(e))")
            }
        }
        for v in q.to {
            if let e = ftsEscape(v) { pieces.append("to_search:\(e)") }
        }
        for v in q.cc {
            if let e = ftsEscape(v) { pieces.append("cc_search:\(e)") }
        }
        for v in q.bcc {
            if let e = ftsEscape(v) { pieces.append("bcc_search:\(e)") }
        }
        if let v = q.subject, let e = ftsEscape(v) {
            pieces.append("subject:\(e)")
        }
        if let v = q.body, let e = ftsEscape(v) {
            pieces.append("body_text:\(e)")
        }
        if let v = q.listID, let e = ftsEscape(v) {
            pieces.append("list_id:\(e)")
        }

        // Negated field operators: NOT col:value (column-qualified exclude).
        for v in q.excludeFrom {
            if let e = ftsEscape(v) {
                pieces.append("NOT ({from_name from_address}:\(e))")
            }
        }
        for v in q.excludeTo {
            if let e = ftsEscape(v) { pieces.append("NOT to_search:\(e)") }
        }
        for v in q.excludeCc {
            if let e = ftsEscape(v) { pieces.append("NOT cc_search:\(e)") }
        }
        for v in q.excludeBcc {
            if let e = ftsEscape(v) { pieces.append("NOT bcc_search:\(e)") }
        }
        for v in q.excludeSubject {
            if let e = ftsEscape(v) { pieces.append("NOT subject:\(e)") }
        }
        for v in q.excludeBody {
            if let e = ftsEscape(v) { pieces.append("NOT body_text:\(e)") }
        }

        return pieces.isEmpty ? nil : pieces.joined(separator: " AND ")
    }

    /// Escape a single FTS5 search term: quoted string with inner `"` doubled.
    /// Returns nil for empty/whitespace-only input.
    nonisolated private static func ftsEscape(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - Server-side IMAP SEARCH

    func searchOnServer(
        query: SearchQuery,
        account: Account,
        folderPath: String
    ) async throws -> Set<UInt32> {
        let imap = getOrCreateIMAPService(for: account)
        await wireTokenProvider(for: account, imap: imap)
        if await !imap.isConnected { try await imap.connect() }
        try await imap.ensureFolderSelected(folderPath)

        var criteria: [SearchCriteria] = []

        if let freetext = query.freetextJoined, !freetext.isEmpty {
            criteria.append(.text(freetext))
        }
        for v in query.from where !v.isEmpty {
            criteria.append(.from(v))
        }
        for v in query.to where !v.isEmpty {
            criteria.append(.to(v))
        }
        for v in query.cc where !v.isEmpty {
            criteria.append(.cc(v))
        }
        for v in query.bcc where !v.isEmpty {
            criteria.append(.bcc(v))
        }
        if let v = query.subject, !v.isEmpty {
            criteria.append(.subject(v))
        }
        if let v = query.body, !v.isEmpty {
            criteria.append(.body(v))
        }
        if let after = query.after {
            criteria.append(.since(after))
        }
        if let before = query.before {
            criteria.append(.before(before))
        }
        if let larger = query.largerThan {
            criteria.append(.larger(larger))
        }
        if let smaller = query.smallerThan {
            criteria.append(.smaller(smaller))
        }
        if let isFilter = query.isFilter {
            switch isFilter {
            case .unread:    criteria.append(.unseen)
            case .read:      criteria.append(.seen)
            case .flagged:   criteria.append(.flagged)
            case .unflagged: criteria.append(.unflagged)
            }
        }

        // Negated field operators — IMAP SEARCH supports .not(). Plain negated
        // words (`-spam`) stay client-side because they're freetext.
        for v in query.excludeFrom where !v.isEmpty {
            criteria.append(.not(.from(v)))
        }
        for v in query.excludeTo where !v.isEmpty {
            criteria.append(.not(.to(v)))
        }
        for v in query.excludeCc where !v.isEmpty {
            criteria.append(.not(.cc(v)))
        }
        for v in query.excludeBcc where !v.isEmpty {
            criteria.append(.not(.bcc(v)))
        }
        for v in query.excludeSubject where !v.isEmpty {
            criteria.append(.not(.subject(v)))
        }
        for v in query.excludeBody where !v.isEmpty {
            criteria.append(.not(.body(v)))
        }
        // list:/has:attachment/plain-exclude/phrase not mappable to IMAP SEARCH —
        // handled client-side after hydration.

        if criteria.isEmpty { criteria.append(.all) }

        return try await imap.searchMessages(criteria: criteria)
    }

    /// Hydrate server search results: fetch missing headers and persist.
    func hydrateSearchResults(
        uids: Set<UInt32>,
        folderID: UUID,
        folderPath: String,
        account: Account
    ) async throws {
        let existingUIDs: Set<UInt32> = try await pool.read { db in
            let rows = try UInt32.fetchAll(db, sql:
                "SELECT uid FROM messages WHERE folder_id = ?",
                arguments: [folderID])
            return Set(rows)
        }

        let missing = uids.subtracting(existingUIDs)
        guard !missing.isEmpty else { return }

        let imap = getOrCreateIMAPService(for: account)

        let sorted = Array(missing.sorted())
        let batchSize = 50
        var hydrated = 0
        for batchStart in stride(from: 0, to: sorted.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, sorted.count)
            let batch = Array(sorted[batchStart..<batchEnd])
            do {
                let infos = try await imap.fetchHeadersBySet(batch)
                try await persistHeaders(infos, folderID: folderID, accountID: account.id)
                hydrated += infos.count
            } catch {
                LogService.log(.warning, .search,
                               "Batch fetch failed, reconnecting for per-UID retry",
                               detail: "\(error)")
                await imap.disconnect()
                await wireTokenProvider(for: account, imap: imap)
                try await imap.connect()
                try await imap.selectFolder(folderPath)

                for uid in batch {
                    do {
                        let infos = try await imap.fetchHeadersBySet([uid])
                        try await persistHeaders(infos, folderID: folderID, accountID: account.id)
                        hydrated += infos.count
                    } catch {
                        LogService.log(.warning, .search,
                                       "Skipping UID \(uid) (parse error)")
                        await imap.disconnect()
                        await wireTokenProvider(for: account, imap: imap)
                        try await imap.connect()
                        try await imap.selectFolder(folderPath)
                    }
                }
            }
        }
        LogService.log(.info, .search,
                       "Hydrated \(hydrated)/\(missing.count) search results",
                       detail: folderPath)
    }

    // MARK: - Scope SQL helpers

    nonisolated private static func scopeSQL(
        _ scope: SearchScope,
        folderID: UUID?,
        accountID: UUID?
    ) -> (String, [any DatabaseValueConvertible]) {
        switch scope {
        case .currentFolder:
            guard let fid = folderID else { return ("", []) }
            return ("m.folder_id = ?", [fid])
        case .currentAccount:
            guard let aid = accountID else { return ("", []) }
            return ("m.account_id = ?", [aid])
        case .allAccounts:
            return ("", [])
        }
    }
}
