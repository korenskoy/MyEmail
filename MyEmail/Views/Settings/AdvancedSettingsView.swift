//
//  AdvancedSettingsView.swift
//  MyEmail
//
//  Advanced: cache management, timeouts, debug tools.
//  DESIGN.md §13.
//

import SwiftUI

struct AdvancedSettingsView: View {
    @AppStorage("imapTimeoutSeconds") private var imapTimeout: Int = 30
    @AppStorage("smtpTimeoutSeconds") private var smtpTimeout: Int = 30

    @AppStorage("bodyPrefetchEnabled") private var bodyPrefetchEnabled: Bool = true
    @AppStorage("bodyPrefetchMaxCount") private var bodyPrefetchMaxCount: Int = 30
    @AppStorage("bodyPrefetchMaxSizeKB") private var bodyPrefetchMaxSizeKB: Int = 1024

    @State private var cacheSize: String = "Calculating…"

    var body: some View {
        Form {
            Section("Timeouts") {
                Picker("IMAP connection timeout", selection: $imapTimeout) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("120 seconds").tag(120)
                }

                Picker("SMTP connection timeout", selection: $smtpTimeout) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
            }

            Section("Background download") {
                Toggle("Pre-download message bodies", isOn: $bodyPrefetchEnabled)
                Text("Speeds up message opening. Disable to save bandwidth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Max messages to pre-download", selection: $bodyPrefetchMaxCount) {
                    Text("10").tag(10)
                    Text("30").tag(30)
                    Text("50").tag(50)
                    Text("100").tag(100)
                }
                .disabled(!bodyPrefetchEnabled)

                Picker("Max size per message", selection: $bodyPrefetchMaxSizeKB) {
                    Text("256 KB").tag(256)
                    Text("1 MB").tag(1024)
                    Text("5 MB").tag(5120)
                    Text("Unlimited").tag(0)
                }
                .disabled(!bodyPrefetchEnabled)
            }

            Section("Cache") {
                HStack {
                    Text("Database size")
                    Spacer()
                    Text(cacheSize)
                        .foregroundStyle(.secondary)
                }

                Button("Clear attachment cache") {
                    clearAttachmentCache()
                }
            }

            Section("Debug") {
                Text("Toggle the Debug Log Panel with ⌥⌘Y")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { calculateCacheSize() }
    }

    private func calculateCacheSize() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        guard let dbPath = appSupport?.appendingPathComponent("MyEmail/db.sqlite") else {
            cacheSize = "Unknown"
            return
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath.path),
           let size = attrs[.size] as? Int64 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            cacheSize = formatter.string(fromByteCount: size)
        } else {
            cacheSize = "N/A"
        }
    }

    private func clearAttachmentCache() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        guard let attachDir = appSupport?.appendingPathComponent("MyEmail/attachments") else { return }

        try? FileManager.default.removeItem(at: attachDir)
        try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        LogService.log(.info, .uiDebug, "Attachment cache cleared")
    }
}
