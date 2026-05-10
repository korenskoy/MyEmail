//
//  DraftRecoveryService.swift
//  MyEmail
//
//  Auto-save compose state every 5 seconds (DESIGN.md §5.2).
//  Recovery directory: ~/Library/Application Support/MyEmail/drafts-recovery/
//  On normal close (Send/Save/Discard): file deleted.
//  On relaunch after crash: scan directory, show restore dialog.
//

import Foundation

struct DraftRecoveryState: Codable, Identifiable, Sendable {
    let id: UUID
    let from: String
    let to: String
    let cc: String
    let subject: String
    let bodyText: String
    let savedAt: Date

    var displayTitle: String {
        subject.isEmpty ? String(localized: "(No subject)") : subject
    }
}

@Observable
@MainActor
final class DraftRecoveryService {
    private static let directoryName = "drafts-recovery"

    var pendingRecoveries: [DraftRecoveryState] = []

    /// Thread-safe path accessor (value type, safe from any isolation).
    nonisolated private var recoveryDir: URL? {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        return appSupport?.appendingPathComponent("MyEmail/\(DraftRecoveryService.directoryName)")
    }

    // MARK: - Save

    nonisolated func save(windowID: UUID, from: String, to: String, cc: String,
                          subject: String, bodyText: String) {
        guard let dir = recoveryDir else { return }

        let state = DraftRecoveryState(
            id: windowID, from: from, to: to, cc: cc,
            subject: subject, bodyText: bodyText, savedAt: Date()
        )

        // Off-main-thread file I/O
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("\(windowID.uuidString).json")
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: path, options: .atomic)
            }
        }
    }

    // MARK: - Remove (normal close)

    func remove(windowID: UUID) {
        guard let dir = recoveryDir else { return }
        let path = dir.appendingPathComponent("\(windowID.uuidString).json")
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Scan on launch

    func scanForRecoveries() {
        guard let dir = recoveryDir else { return }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }

        let decoder = JSONDecoder()
        pendingRecoveries = files.compactMap { url -> DraftRecoveryState? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(DraftRecoveryState.self, from: data)
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: - Discard all

    func discardAll() {
        guard let dir = recoveryDir else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
        pendingRecoveries = []
    }
}
