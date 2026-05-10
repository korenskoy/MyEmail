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
        let preMeta = await captureSourceFolders(ids)
        await syncService.deleteMessages(ids)
        registerMoveBack(preMeta, actionName: String(localized: "Delete"), undoManager: undoManager)
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
