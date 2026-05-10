//
//  ComposeAttachmentsStripView.swift
//  MyEmail
//
//  Strip of pending attachments shown above the compose toolbar.
//  Mirrors AttachmentStripView visually but each chip carries a remove (×)
//  affordance and has no Quick Look integration (file already lives on disk).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposeAttachmentsStripView: View {
    let attachments: [ComposeAttachment]
    let onRemove: (ComposeAttachment) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(attachments) { att in
                chip(att)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func chip(_ att: ComposeAttachment) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: fileIcon(for: att))
                .resizable()
                .frame(width: 20, height: 20)
            Text(att.filename)
                .font(.system(size: 12))
                .lineLimit(1)
            Text(FormatHelpers.formatByteCount(Int(att.size)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                onRemove(att)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove attachment"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .cornerRadius(4)
    }

    private func fileIcon(for att: ComposeAttachment) -> NSImage {
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
