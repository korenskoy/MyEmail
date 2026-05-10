//
//  AttachmentStripView.swift
//  MyEmail
//
//  Wrap-layout strip of non-inline attachments pinned at bottom (Thunderbird-style).
//

import Quartz
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentStripView: View {
    let attachments: [Attachment]
    let onRefetch: (Attachment) async -> Attachment?

    @State private var refetchingIDs: Set<UUID> = []
    @State private var quickLookCoordinator = QuickLookCoordinator()

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(attachments) { att in
                attachmentChip(att)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func attachmentChip(_ att: Attachment) -> some View {
        let isRefetching = refetchingIDs.contains(att.id)
        Button {
            Task { await quickLookAttachment(att) }
        } label: {
            HStack(spacing: 6) {
                if isRefetching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                } else {
                    Image(nsImage: fileIcon(for: att))
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                Text(att.filename)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(FormatHelpers.formatByteCount(att.size))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .contextMenu { attachmentMenu(att) }
    }

    @ViewBuilder
    private func attachmentMenu(_ att: Attachment) -> some View {
        Button(String(localized: "Quick Look")) {
            Task { await quickLookAttachment(att) }
        }
        Divider()
        Button(String(localized: "Open")) {
            Task { await openAttachment(att) }
        }
        Button(String(localized: "Save As…")) {
            Task { await saveAs(att) }
        }
        Button(String(localized: "Show in Finder")) {
            showInFinder(att)
        }
    }

    // MARK: - Actions

    private func quickLookAttachment(_ att: Attachment) async {
        guard let path = await ensureLocalFile(att) else { return }
        // Collect all locally available URLs for arrow-key navigation
        var allURLs: [URL] = []
        var selectedIndex = 0
        for a in attachments {
            let url: URL
            if a.id == att.id {
                url = URL(fileURLWithPath: path)
                selectedIndex = allURLs.count
            } else if let p = a.localPath, FileManager.default.fileExists(atPath: p) {
                url = URL(fileURLWithPath: p)
            } else {
                continue
            }
            allURLs.append(url)
        }
        quickLookCoordinator.show(urls: allURLs, selectedIndex: selectedIndex)
    }

    private func openAttachment(_ att: Attachment) async {
        guard let path = await ensureLocalFile(att) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func saveAs(_ att: Attachment) async {
        guard let path = await ensureLocalFile(att) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = att.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: path), to: dest
            )
        } catch {
            LogService.log(.error, .sync, "Save attachment failed", detail: "\(error)")
        }
    }

    private func showInFinder(_ att: Attachment) {
        guard let path = att.localPath,
              FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: path)]
        )
    }

    /// Return local file path, re-fetching from IMAP if file was deleted.
    private func ensureLocalFile(_ att: Attachment) async -> String? {
        if let path = att.localPath, FileManager.default.fileExists(atPath: path) {
            return path
        }
        // File missing — re-fetch from server
        refetchingIDs.insert(att.id)
        defer { refetchingIDs.remove(att.id) }
        if let updated = await onRefetch(att) {
            return updated.localPath
        }
        return nil
    }

    // MARK: - Helpers

    private func fileIcon(for att: Attachment) -> NSImage {
        let ext = (att.filename as NSString).pathExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: utType)
        }
        if let utType = UTType(mimeType: att.mimeType) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

}
