//
//  SyncService+Folders.swift
//  MyEmail
//
//  Folder sync: LIST with SPECIAL-USE, persist to GRDB, map folder paths.
//

import Foundation
import GRDB
import SwiftMail

extension SyncService {

    // MARK: - Sync folders from IMAP

    func syncFolders(account: Account, imap: IMAPService) async throws {
        let mailboxes = try await imap.listAllFolders()
        let specialUseBoxes = try await imap.listFolders()

        // Build specialUse lookup by name from SPECIAL-USE LIST
        var specialUseMap: [String: SpecialUse] = [:]
        for box in specialUseBoxes {
            if let use = mapSpecialUse(box.attributes) {
                specialUseMap[box.name] = use
            }
        }

        // Build user-configured path → specialUse map (highest priority)
        let userPathMap = buildUserPathMap(account: account)

        // Merge: all folders with specialUse overlay
        // Priority (Thunderbird order): user config > SPECIAL-USE > name heuristic
        var folders: [Folder] = []
        for box in mailboxes {
            let isNoSelect = box.attributes.contains(.noSelect)
            if isNoSelect { continue }

            let specialUse = userPathMap[box.name]
                ?? specialUseMap[box.name]
                ?? inferSpecialUse(path: box.name, separator: box.hierarchyDelimiter ?? "/")
            let displayName = IMAPUTF7.decode(
                box.name.components(separatedBy: box.hierarchyDelimiter ?? "/").last ?? box.name
            )

            let folder = Folder(
                id: UUID(),
                accountID: account.id,
                path: box.name,
                name: box.name,
                displayName: displayName,
                separator: box.hierarchyDelimiter ?? "/",
                specialUse: specialUse,
                subscribed: true,
                uidValidity: nil,
                uidNext: nil,
                highestModSequence: nil,
                visibleLimit: 200,
                moreMessages: .unknown,
                highestKnownUid: nil,
                totalCount: 0,
                unreadCount: 0
            )
            folders.append(folder)
        }

        // RFC 6154: one folder per special-use role. Some servers propagate
        // attributes to children — keep only the shortest path per role.
        var specialUseRoots: [SpecialUse: String] = [:]
        for folder in folders {
            guard let use = folder.specialUse else { continue }
            if let existing = specialUseRoots[use], existing.count <= folder.path.count { continue }
            specialUseRoots[use] = folder.path
        }
        for i in folders.indices {
            if let use = folders[i].specialUse, folders[i].path != specialUseRoots[use] {
                folders[i].specialUse = nil
            }
        }

        // Upsert: match on (account_id, path), update existing, insert new
        try await pool.write { db in
            let existingPaths = try String.fetchSet(db, sql:
                "SELECT path FROM folders WHERE account_id = ?",
                arguments: [account.id])

            for folder in folders {
                if existingPaths.contains(folder.path) {
                    // Update display_name and special_use only
                    try db.execute(sql: """
                        UPDATE folders SET display_name = ?, special_use = ?
                        WHERE account_id = ? AND path = ?
                        """, arguments: [
                            folder.displayName,
                            folder.specialUse?.rawValue,
                            account.id,
                            folder.path
                        ])
                } else {
                    var mutable = folder
                    try mutable.insert(db)
                }
            }

            // Remove folders that no longer exist on server
            let serverPaths = Set(folders.map(\.path))
            let toDelete = existingPaths.subtracting(serverPaths)
            if !toDelete.isEmpty {
                try Folder
                    .filter(Column("account_id") == account.id)
                    .filter(toDelete.contains(Column("path")))
                    .deleteAll(db)
            }
        }

        // Update account folder path mapping using already-known data
        try await updateAccountFolderPaths(account: account, folders: folders)

        LogService.log(.info, .sync, "Synced \(folders.count) folders", detail: account.email)
    }

    // MARK: - User-configured folder path → SpecialUse (highest priority)

    private func buildUserPathMap(account: Account) -> [String: SpecialUse] {
        var map: [String: SpecialUse] = [:]
        if let p = account.sentFolderPath { map[p] = .sent }
        if let p = account.draftsFolderPath { map[p] = .drafts }
        if let p = account.trashFolderPath { map[p] = .trash }
        if let p = account.junkFolderPath { map[p] = .junk }
        if let p = account.archiveRootPath { map[p] = .archive }
        return map
    }

    // MARK: - Map Mailbox.Info attributes → SpecialUse

    private func mapSpecialUse(_ attrs: Mailbox.Info.Attributes) -> SpecialUse? {
        if attrs.contains(.inbox) { return .inbox }
        if attrs.contains(.sent) { return .sent }
        if attrs.contains(.drafts) { return .drafts }
        if attrs.contains(.trash) { return .trash }
        if attrs.contains(.junk) { return .junk }
        if attrs.contains(.archive) { return .archive }
        // SwiftMail doesn't expose \All — detected by path in inferSpecialUse
        return nil
    }

    /// Fallback heuristic when server doesn't report SPECIAL-USE flags.
    /// RFC 6154: one folder per role, children are ordinary.
    private func inferSpecialUse(path: String, separator: String) -> SpecialUse? {
        let decoded = IMAPUTF7.decode(path)
        let lower = decoded.lowercased()
        if lower == "inbox" { return .inbox }

        // Gmail \All — SwiftMail doesn't expose the IMAP \All attribute
        if lower.hasPrefix("[gmail]/") {
            let leaf = String(lower.dropFirst("[gmail]/".count))
            if leaf == "all mail" { return .all }
        }

        // Subfolders never infer special-use
        let sep = separator.isEmpty ? "/" : separator
        if decoded.contains(sep) { return nil }

        // Exact-match (Thunderbird/Apple Mail common names)
        let sentNames: Set = ["sent", "sent messages", "sent items", "sent mail"]
        let draftNames: Set = ["drafts", "draft"]
        let trashNames: Set = ["trash", "deleted messages", "deleted items", "bin"]
        let junkNames: Set = ["junk", "junk e-mail", "spam", "bulk mail"]
        let archiveNames: Set = ["archive", "archives"]
        // Russian (Yandex, Mail.ru, Rambler)
        let sentNamesRu: Set = ["отправленные", "отправлено"]
        let draftNamesRu: Set = ["черновики"]
        let trashNamesRu: Set = ["корзина", "удалённые", "удаленные"]
        let junkNamesRu: Set = ["спам", "нежелательная почта"]
        let archiveNamesRu: Set = ["архив"]

        if sentNames.contains(lower) || sentNamesRu.contains(lower) { return .sent }
        if draftNames.contains(lower) || draftNamesRu.contains(lower) { return .drafts }
        if trashNames.contains(lower) || trashNamesRu.contains(lower) { return .trash }
        if junkNames.contains(lower) || junkNamesRu.contains(lower) { return .junk }
        if archiveNames.contains(lower) || archiveNamesRu.contains(lower) { return .archive }
        return nil
    }

    // MARK: - Update account folder path mapping (§9.11)
    // Only auto-detect paths that the user hasn't manually configured.

    private func updateAccountFolderPaths(
        account: Account, folders: [Folder]
    ) async throws {
        var mapping: [SpecialUse: String] = [:]
        for f in folders {
            if let use = f.specialUse { mapping[use] = f.path }
        }

        // Refetch current account to get latest user-configured paths
        let current: Account? = try await pool.read { db in
            try Account.fetchOne(db, key: account.id)
        }
        guard let current else { return }

        // Only fill in nil paths — never overwrite user's manual configuration
        let sent = current.sentFolderPath ?? mapping[.sent]
        let drafts = current.draftsFolderPath ?? mapping[.drafts]
        let trash = current.trashFolderPath ?? mapping[.trash]
        let junk = current.junkFolderPath ?? mapping[.junk]
        let archive = current.archiveRootPath ?? mapping[.archive] ?? mapping[.all]

        try await pool.write { db in
            try db.execute(sql: """
                UPDATE accounts
                SET sent_folder_path = ?, drafts_folder_path = ?,
                    trash_folder_path = ?, junk_folder_path = ?,
                    archive_root_path = ?
                WHERE id = ?
                """, arguments: [sent, drafts, trash, junk, archive, account.id])
        }
    }
}
