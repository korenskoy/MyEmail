//
//  SyncService+Preview.swift
//  MyEmail
//
//  Batch-fetch preview snippets for messages after header sync.
//  Uses BODY.PEEK[1] (first MIME part, usually text/plain) via
//  pipelined FETCH for speed. Best-effort — failures don't block sync.
//

import Foundation
import GRDB
import SwiftMail

extension SyncService {

    private static let previewMaxLength = 140

    /// Fetch preview snippets for recent messages without body.
    /// Folder must already be SELECTed on `imap`.
    func fetchPreviews(folderID: UUID, imap: IMAPService, limit: Int = 20) async {
        let targets: [(id: UUID, uid: UInt32)] = (try? await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, uid FROM messages
                WHERE folder_id = ? AND uid > 0 AND preview = '' AND download_state = 'envelope'
                ORDER BY date DESC LIMIT ?
                """, arguments: [folderID, limit])
            .map { (id: $0["id"] as UUID, uid: $0["uid"] as UInt32) }
        }) ?? []

        guard !targets.isEmpty else { return }

        let section = Section([1])
        let parts: [(uid: UID, section: Section)] = targets.map {
            (uid: UID($0.uid), section: section)
        }

        do {
            let results = try await imap.fetchPartsPipelined(parts: parts)

            for target in targets {
                guard let partResults = results[UID(target.uid)],
                      let (_, data) = partResults.first else { continue }

                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""

                let preview = String(text.prefix(Self.previewMaxLength))
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)

                guard !preview.isEmpty else { continue }

                try? await pool.write { db in
                    try db.execute(
                        sql: "UPDATE messages SET preview = ? WHERE id = ?",
                        arguments: [preview, target.id]
                    )
                }
            }

            LogService.log(.debug, .sync,
                "Fetched \(results.count) previews", detail: "folder=\(folderID)")
        } catch {
            LogService.log(.debug, .sync, "Preview fetch skipped", detail: "\(error)")
        }
    }
}
