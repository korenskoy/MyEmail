//
//  EmlViewerWindowController.swift
//  MyEmail
//
//  AppKit-owned standalone window for viewing a raw `.eml` file that is
//  NOT in the local GRDB store (e.g. opened from Finder, received as a
//  message/rfc822 chip, or dragged in). One controller per source-file
//  path — re-front if already open. Wipes its tmpdir on close.
//

import AppKit
import SwiftEmailParser
import SwiftUI

@MainActor
final class EmlViewerWindowController: NSWindowController, NSWindowDelegate {
    let key: String
    let sourceURL: URL
    private let tmpDir: URL
    private let onClose: (String) -> Void

    init(
        key: String,
        sourceURL: URL,
        email: EmailMessage,
        tmpDir: URL,
        attachments: [MyEmail.Attachment],
        inlineRefs: [InlineRef],
        onClose: @escaping (String) -> Void
    ) {
        self.key = key
        self.sourceURL = sourceURL
        self.tmpDir = tmpDir
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = email.subject ?? sourceURL.lastPathComponent
        window.minSize = NSSize(width: 500, height: 400)
        // Unique autosave per source path keeps each file's window geometry
        // independent across sessions.
        let autosaveID = key.data(using: .utf8)?.base64EncodedString().prefix(16) ?? "default"
        window.setFrameAutosaveName("MyEmailEmlViewer-\(autosaveID)")

        let root = EmlViewerView(
            email: email,
            attachments: attachments,
            inlineRefs: inlineRefs
        )
        window.contentView = NSHostingView(rootView: root)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose(key)
        // Best-effort cleanup; ignore failures (tmpdir may already be gone).
        try? FileManager.default.removeItem(at: tmpDir)
    }
}
