//
//  UndoActionService.swift
//  MyEmail
//
//  Undo/Redo infrastructure (DESIGN.md §7.3).
//  Wraps NSUndoManager per-window. Covers: Delete, Archive, Move,
//  Mark Read/Unread, Flag.
//
//  State transitions for Move:
//  - queued (in OfflineQueue): cancel PendingAction + revert local DB
//  - in-flight: cancel Task + enqueue reverse PendingAction
//  - synced: enqueue reverse PendingAction (move back)
//

import AppKit
import Foundation
import GRDB

@Observable
@MainActor
final class UndoActionService {
    private let syncService: SyncService

    init(syncService: SyncService) {
        self.syncService = syncService
    }

    // MARK: - Mark Read/Unread

    func markAsRead(
        _ ids: [UUID], undoManager: UndoManager?
    ) async {
        // Capture pre-state
        let wasUnread = ids
        await syncService.markAsRead(ids)

        undoManager?.registerUndo(withTarget: UndoTarget.shared) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncService.markAsUnread(wasUnread)
            }
        }
        undoManager?.setActionName(String(localized: "Mark as Read"))
    }

    func markAsUnread(
        _ ids: [UUID], undoManager: UndoManager?
    ) async {
        let wasRead = ids
        await syncService.markAsUnread(ids)

        undoManager?.registerUndo(withTarget: UndoTarget.shared) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncService.markAsRead(wasRead)
            }
        }
        undoManager?.setActionName(String(localized: "Mark as Unread"))
    }

    // MARK: - Flag

    func setFlagged(
        _ ids: [UUID], flagged: Bool, undoManager: UndoManager?
    ) async {
        await syncService.setFlagged(ids, flagged: flagged)

        undoManager?.registerUndo(withTarget: UndoTarget.shared) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncService.setFlagged(ids, flagged: !flagged)
            }
        }
        undoManager?.setActionName(flagged
            ? String(localized: "Flag")
            : String(localized: "Unflag"))
    }

    // MARK: - Pre-capture helper

    /// Capture (messageID, folderID) pairs before a destructive operation.
    private func captureSourceFolders(_ ids: [UUID]) async -> [(UUID, UUID)] {
        let pool = DatabaseService.shared.pool
        return (try? await pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, folder_id FROM messages WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(ids)
            ).map { ($0["id"] as UUID, $0["folder_id"] as UUID) }
        }) ?? []
    }

    private func registerMoveBack(
        _ preMeta: [(UUID, UUID)], actionName: String, undoManager: UndoManager?
    ) {
        guard !preMeta.isEmpty else { return }
        undoManager?.registerUndo(withTarget: UndoTarget.shared) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Batch by destination folder to avoid N separate IMAP operations
                let byFolder = Dictionary(grouping: preMeta, by: \.1)
                for (folderID, entries) in byFolder {
                    await self.syncService.moveMessages(entries.map(\.0), to: folderID)
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - Delete

    func deleteMessages(
        _ ids: [UUID], undoManager: UndoManager?
    ) async {
        guard !ids.isEmpty else { return }
        let preMeta = await captureSourceFolders(ids)
        // Resolve whether any message currently sits in a Trash folder —
        // those go straight to EXPUNGE (permanent), so the prompt must warn.
        let pool = DatabaseService.shared.pool
        let inTrashCount = (try? await pool.read { db -> Int in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages
                JOIN folders ON folders.id = messages.folder_id
                WHERE messages.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                  AND folders.special_use = ?
                """, arguments: StatementArguments(ids + [SpecialUse.trash.rawValue])) ?? 0
        }) ?? 0
        let isPermanent = inTrashCount > 0

        if !confirmDelete(count: ids.count, isPermanent: isPermanent) { return }

        await syncService.deleteMessages(ids)
        registerMoveBack(preMeta, actionName: String(localized: "Delete"), undoManager: undoManager)
    }

    /// Modal confirmation before a destructive Delete. Single message from a
    /// non-Trash folder slips through silently — the operation is undoable
    /// via Cmd+Z and reversible by hand from the Trash folder, so MailMate
    /// / Thunderbird-style "no nag" applies there. Anything bulk OR anything
    /// that will permanently expunge requires explicit confirmation.
    private func confirmDelete(count: Int, isPermanent: Bool) -> Bool {
        if count <= 1 && !isPermanent { return true }
        let alert = NSAlert()
        if isPermanent {
            alert.messageText = count == 1
                ? String(localized: "Delete this message permanently?")
                : String(format: String(localized: "Delete %d messages permanently?"), count)
            alert.informativeText = String(localized: "This action cannot be undone.")
            alert.alertStyle = .critical
        } else {
            alert.messageText = String(
                format: String(localized: "Move %d messages to Trash?"), count
            )
            alert.informativeText = String(localized: "You can restore them from the Trash folder.")
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Archive

    func archiveMessages(
        _ ids: [UUID], undoManager: UndoManager?
    ) async {
        let preMeta = await captureSourceFolders(ids)
        await syncService.archiveMessages(ids)
        registerMoveBack(preMeta, actionName: String(localized: "Archive"), undoManager: undoManager)
    }
}

// MARK: - Undo target (NSUndoManager requires NSObject target)

/// Singleton target for NSUndoManager registration.
/// NSUndoManager's `registerUndo(withTarget:handler:)` requires an NSObject.
private final class UndoTarget: NSObject, @unchecked Sendable {
    static let shared = UndoTarget()
}
