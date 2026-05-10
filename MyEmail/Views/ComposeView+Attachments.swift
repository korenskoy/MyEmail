//
//  ComposeView+Attachments.swift
//  MyEmail
//
//  File picker, drag-drop handler, drop overlay and materialization of
//  pending ComposeAttachments into SwiftMail.Attachment for send.
//

import AppKit
import SwiftMail
import SwiftUI

extension ComposeView {

    /// NSOpenPanel-based multi-file picker. The panel itself grants
    /// temporary read access to the chosen URLs; no security-scoped
    /// bookmarks required.
    func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose files to attach")
        guard panel.runModal() == .OK else { return }
        addAttachments(from: panel.urls)
    }

    func addAttachments(from urls: [URL]) {
        for url in urls {
            do {
                let attachment = try ComposeAttachment(url: url)
                attachments.append(attachment)
            } catch {
                LogService.log(.error, .smtp, "Attachment load failed",
                               detail: "\(url.path): \(error)")
            }
        }
        if !urls.isEmpty { isDirty = true }
    }

    /// Drop handler: accepts one or more file URLs.
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        var collected: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            addAttachments(from: collected)
        }
        return true
    }

    @ViewBuilder
    var dropOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(4)
                .allowsHitTesting(false)
        }
    }

    /// Materialize pending files into SwiftMail attachments for send.
    /// Reads data lazily here so keeping files in the compose view doesn't
    /// hold their bytes in memory for the full editing session.
    func materializeAttachments() throws -> [SwiftMail.Attachment] {
        try attachments.map { item in
            SwiftMail.Attachment(
                filename: item.filename,
                mimeType: item.mimeType,
                data: try item.loadData(),
                contentID: nil,
                isInline: false
            )
        }
    }
}
