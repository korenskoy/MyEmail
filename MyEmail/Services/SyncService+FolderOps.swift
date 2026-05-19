//
//  SyncService+FolderOps.swift
//  MyEmail
//
//  Folder CRUD: create, rename, delete, expunge (DESIGN.md §4.3).
//

import Foundation
import GRDB

extension SyncService {

    // MARK: - Create subfolder

    func createSubfolder(name: String, parentPath: String, account: Account) async {
        // Look up parent folder's hierarchy separator (RFC 3501 §5.1.1)
        let sep: String = (try? await pool.read { db in
            try String.fetchOne(db, sql:
                "SELECT separator FROM folders WHERE account_id = ? AND path = ?",
                arguments: [account.id, parentPath])
        }) ?? "/"
        let encodedName = IMAPUTF7.encode(name)
        let fullPath = parentPath.isEmpty ? encodedName : "\(parentPath)\(sep)\(encodedName)"

        let imap = getOrCreateIMAPService(for: account)
        do {
            if await !imap.isConnected { try await imap.connect() }
            try await imap.createFolder(path: fullPath)

            // Refresh folder list
            try await syncFolders(account: account, imap: imap)
            LogService.log(.info, .sync, "Created folder", detail: fullPath)
        } catch {
            LogService.log(.error, .sync, "Create folder failed", detail: "\(error)")
        }
    }

    // MARK: - Rename folder (IMAP RENAME)

    func renameFolder(folderID: UUID, newName: String) async {
        let pool = DatabaseService.shared.pool

        let ctx: (folder: Folder, account: Account)? = try? await pool.read { db in
            guard let folder = try Folder.fetchOne(db, key: folderID),
                  let account = try Account.fetchOne(db, key: folder.accountID) else { return nil }
            return (folder, account)
        }
        guard let (folder, account) = ctx else { return }

        let sep = folder.separator.isEmpty ? "/" : folder.separator
        let components = folder.path.components(separatedBy: sep)
        let encodedName = IMAPUTF7.encode(newName)
        let newPath = (components.dropLast() + [encodedName]).joined(separator: sep)

        let imap = getOrCreateIMAPService(for: account)
        do {
            await wireTokenProvider(for: account, imap: imap)
            if await !imap.isConnected { try await imap.connect() }

            // IMAP RENAME — atomic server-side operation (RFC 3501 §6.3.5)
            try await imap.renameMailbox(from: folder.path, to: newPath)

            // Refresh folder list to pick up changes
            try await syncFolders(account: account, imap: imap)
            LogService.log(.info, .sync, "Folder renamed", detail: "\(folder.path) → \(newPath)")
        } catch {
            LogService.log(.error, .sync, "Rename folder failed", detail: "\(error)")
        }
    }

    // MARK: - Delete folder (IMAP DELETE)

    func deleteFolder(folderID: UUID) async {
        let pool = DatabaseService.shared.pool

        let ctx: (folder: Folder, account: Account)? = try? await pool.read { db in
            guard let folder = try Folder.fetchOne(db, key: folderID),
                  let account = try Account.fetchOne(db, key: folder.accountID) else { return nil }
            return (folder, account)
        }
        guard let (folder, account) = ctx else { return }

        let imap = getOrCreateIMAPService(for: account)
        do {
            await wireTokenProvider(for: account, imap: imap)
            if await !imap.isConnected { try await imap.connect() }

            // Expunge messages first (some servers require empty mailbox for DELETE)
            try await imap.selectFolder(folder.path)
            let allUIDs = try await imap.listAllUIDs()
            if !allUIDs.isEmpty {
                try await imap.deleteMessages(uids: Array(allUIDs))
            }

            // IMAP DELETE — removes the mailbox from server (RFC 3501 §6.3.4)
            try await imap.deleteMailbox(folder.path)

            // Local cleanup (CASCADE handles messages via FK)
            try await pool.write { db in
                try db.execute(sql: """
                    DELETE FROM pending_actions
                    WHERE (source_folder_path = ? OR target_folder_path = ?) AND account_id = ?
                    """, arguments: [folder.path, folder.path, folder.accountID])
                try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [folderID])
            }

            // Refresh folder list
            try await syncFolders(account: account, imap: imap)
            LogService.log(.info, .sync, "Folder deleted", detail: folder.path)
        } catch {
            LogService.log(.error, .sync, "Delete folder failed", detail: "\(error)")
        }
    }

    // MARK: - Empty folder (STORE \Deleted + EXPUNGE, RFC 3501 §6.4.3/§6.4.6)

    func emptyFolder(folderID: UUID) async {
        let pool = DatabaseService.shared.pool

        // Load target folder, account, and all descendant folders (Trash/Spam,
        // Trash/Spam/Nested, …). Descendants ordered deepest-first so each
        // parent is already empty by the time we DELETE it — some servers
        // (Gmail, Dovecot) refuse DELETE on a mailbox with \HasChildren.
        let ctx: (folder: Folder, account: Account, descendants: [Folder])? = try? await pool.read { db in
            guard let folder = try Folder.fetchOne(db, key: folderID),
                  let account = try Account.fetchOne(db, key: folder.accountID) else { return nil }
            let sep = folder.separator.isEmpty ? "/" : folder.separator
            let likePrefix = (folder.path + sep)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            let descendants = try Folder.fetchAll(db, sql: """
                SELECT * FROM folders
                WHERE account_id = ? AND path LIKE ? ESCAPE '\\'
                ORDER BY LENGTH(path) DESC
                """, arguments: [account.id, likePrefix])
            return (folder, account, descendants)
        }
        guard let (folder, account, descendants) = ctx else { return }

        let imap = getOrCreateIMAPService(for: account)
        do {
            await wireTokenProvider(for: account, imap: imap)
            if await !imap.isConnected { try await imap.connect() }

            // 1. Purge descendants deepest-first: STORE \Deleted + EXPUNGE + DELETE mailbox.
            //    Failures per child are logged but don't abort the overall empty —
            //    user expects Trash cleared even if one nested mailbox is flaky.
            for child in descendants {
                do {
                    try await imap.selectFolder(child.path)
                    let childUIDs = try await imap.listAllUIDs()
                    if !childUIDs.isEmpty {
                        try await imap.deleteMessages(uids: Array(childUIDs))
                    }
                    try await imap.deleteMailbox(child.path)
                    try await pool.write { db in
                        try db.execute(sql: """
                            DELETE FROM pending_actions
                            WHERE (source_folder_path = ? OR target_folder_path = ?) AND account_id = ?
                            """, arguments: [child.path, child.path, account.id])
                        try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [child.id])
                    }
                    LogService.log(.info, .sync, "Nested folder purged", detail: child.path)
                } catch {
                    LogService.log(.warning, .sync, "Nested folder purge failed",
                                   detail: "\(child.path): \(error)")
                }
            }

            // 2. Purge the target folder itself (messages only — Trash/Junk stays).
            try await imap.selectFolder(folder.path)
            let allUIDs = try await imap.listAllUIDs()
            if !allUIDs.isEmpty {
                try await imap.deleteMessages(uids: Array(allUIDs))
            }

            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM messages WHERE folder_id = ?",
                    arguments: [folderID]
                )
                try db.execute(
                    sql: "UPDATE folders SET unread_count = 0, total_count = 0 WHERE id = ?",
                    arguments: [folderID]
                )
            }

            // 3. Re-sync folder list if descendants were removed so sidebar rebuilds.
            if !descendants.isEmpty {
                try await syncFolders(account: account, imap: imap)
            }

            LogService.log(.info, .sync, "Folder emptied", detail: folder.path)
        } catch {
            LogService.log(.error, .sync, "Empty folder failed", detail: "\(error)")
        }
    }

    // MARK: - Force resync (dev tool)

    func forceResyncFolder(folderID: UUID) async {
        let pool = DatabaseService.shared.pool

        let ctx: (folder: Folder, account: Account)? = try? await pool.read { db in
            guard let folder = try Folder.fetchOne(db, key: folderID),
                  let account = try Account.fetchOne(db, key: folder.accountID) else { return nil }
            return (folder, account)
        }
        guard let (folder, account) = ctx else { return }

        let imap = getOrCreateIMAPService(for: account)
        do {
            await wireTokenProvider(for: account, imap: imap)
            if await !imap.isConnected { try await imap.connect() }
            let sel = try await imap.selectFolder(folder.path)
            try await fullResync(
                account: account, folderID: folder.id,
                folderPath: folder.path, imap: imap, selection: sel
            )
            LogService.log(.info, .sync, "Force resync complete", detail: folder.path)
        } catch {
            LogService.log(.error, .sync, "Force resync failed", detail: "\(error)")
        }
    }

    // MARK: - Mark all read (local + IMAP)

    func markAllReadWithSync(folderID: UUID) async {
        let pool = DatabaseService.shared.pool

        // Fetch context + unread UIDs in one read, then do local update
        let context = try? await pool.read { db -> (Folder, Account, [UInt32])? in
            guard let folder = try Folder.fetchOne(db, key: folderID),
                  let account = try Account.fetchOne(db, key: folder.accountID) else { return nil }
            let uids = try UInt32.fetchAll(
                db,
                sql: "SELECT uid FROM messages WHERE folder_id = ? AND uid > 0 AND is_read = 0",
                arguments: [folderID]
            )
            return (folder, account, uids)
        }

        guard let (folder, account, unreadUIDs) = context else { return }

        try? await pool.write { db in
            try db.execute(
                sql: "UPDATE messages SET is_read = 1 WHERE folder_id = ? AND is_read = 0",
                arguments: [folderID]
            )
        }

        guard !unreadUIDs.isEmpty else { return }

        let imap = getOrCreateIMAPService(for: account)
        do {
            if await !imap.isConnected { try await imap.connect() }
            _ = try await imap.selectFolder(folder.path)
            try await imap.markRead(uids: unreadUIDs)
            LogService.log(.info, .sync, "Mark all read synced to IMAP", detail: "folder=\(folder.path), count=\(unreadUIDs.count)")
        } catch {
            LogService.log(.warning, .sync, "Mark all read IMAP failed, local only", detail: "\(error)")
        }
    }
}
