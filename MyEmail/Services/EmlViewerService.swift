//
//  EmlViewerService.swift
//  MyEmail
//
//  Opens .eml files (from Finder, from message/rfc822 chip attachments, etc.)
//  in a dedicated MyEmail window instead of routing through LaunchServices
//  to Mail.app. Each viewer owns a per-window tmpdir for materialized
//  inline images and chip attachments; the tmpdir is wiped on window close.
//

import AppKit
import Foundation
import SwiftEmailParser

@MainActor
final class EmlViewerService {
    static let shared = EmlViewerService()

    /// Indexed by absolute source-file path so the same file re-fronts an
    /// existing window instead of opening a duplicate.
    private var controllers: [String: EmlViewerWindowController] = [:]

    private init() {}

    /// Open the given `.eml` URL in a viewer window. If a viewer for the
    /// same path is already open, brings it to front. Logs and beeps on
    /// parse failure rather than throwing — this is a user-facing entry point.
    func open(url: URL) {
        let key = url.standardizedFileURL.path
        if let existing = controllers[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let email = try EmailMessage(data: data)
            let tmpDir = try Self.makeTmpDir()
            let materialized = try Self.materializeAttachments(email, into: tmpDir)

            let controller = EmlViewerWindowController(
                key: key,
                sourceURL: url,
                email: email,
                tmpDir: tmpDir,
                attachments: materialized.attachments,
                inlineRefs: materialized.inlineRefs,
                onClose: { [weak self] k in self?.controllers[k] = nil }
            )
            controllers[key] = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } catch {
            LogService.shared.log(
                .error, .uiDebug,
                "Failed to open .eml",
                detail: "\(error.localizedDescription) path=\(url.path)"
            )
            NSSound.beep()
        }
    }

    // MARK: - Materialization

    struct Materialized {
        let attachments: [MyEmail.Attachment]
        let inlineRefs: [InlineRef]
    }

    private static func makeTmpDir() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MyEmail-eml-viewer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        return base
    }

    private static func materializeAttachments(
        _ email: EmailMessage, into tmpDir: URL
    ) throws -> Materialized {
        var attachments: [MyEmail.Attachment] = []
        var inlineRefs: [InlineRef] = []
        var usedFilenames: Set<String> = []
        let ephemeralMessageID = UUID()

        for (index, att) in email.attachments.enumerated() {
            let raw = att.filename ?? (att.contentId ?? "attachment-\(index + 1)")
            var filename = sanitizeFilename(raw)
            if usedFilenames.contains(filename) {
                filename = "\(index + 1)-\(filename)"
            }
            usedFilenames.insert(filename)

            let fileURL = tmpDir.appendingPathComponent(filename)
            try att.data.write(to: fileURL)

            let record = MyEmail.Attachment(
                id: UUID(),
                partID: att.contentId ?? "part-\(index + 1)",
                filename: filename,
                mimeType: att.mimeType,
                size: att.size,
                contentID: att.contentId,
                isInline: att.isInline,
                localPath: fileURL.path,
                messageID: ephemeralMessageID
            )
            attachments.append(record)

            if att.isInline, let cid = att.contentId {
                inlineRefs.append(InlineRef(contentID: cid, localPath: fileURL.path))
            }
        }
        return Materialized(attachments: attachments, inlineRefs: inlineRefs)
    }

    /// Minimal path-safe sanitization. Mirrors the logic in
    /// SyncService+Body.sanitizeFilename but kept local to avoid pulling in
    /// the full sync service for a one-off ephemeral path.
    nonisolated private static func sanitizeFilename(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        // Strip path components / leading dots
        while name.hasPrefix(".") || name.hasPrefix(" ") {
            name.removeFirst()
        }
        if name.isEmpty { name = "attachment" }
        if name.count > 200 {
            name = String(name.prefix(200))
        }
        return name
    }
}
