//
//  SearchHelpView.swift
//  MyEmail
//
//  Modal sheet with search syntax reference. Opened from SearchBarView.
//

import SwiftUI

struct SearchHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Search syntax")
                    .font(.title2).bold()
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(title: "Search syntax") {
                        bullet("Freetext search — any word in subject, from, to, body or list id.")
                        bullet("Use double quotes for an exact phrase.")
                        bullet("Prepend a minus sign to exclude a word.")
                    }

                    section(title: "Operators") {
                        bullet("From: matches name or email. Multi-value.")
                        bullet("To, CC, BCC: recipient filters.")
                        bullet("Subject: match words in subject only.")
                        bullet("Body: match words in message body only.")
                        bullet("List: mailing-list identifier (List-ID).")
                        bullet("In: restrict to folder by name.")
                        bullet("Before and After: date range.")
                        bullet("Larger and Smaller: size filter with K, M, G suffix.")
                        bullet("Is: flag filter.")
                        bullet("Has: attachment filter.")
                    }

                    section(title: "Examples") {
                        example("from:anton -spam before:7d")
                        example("subject:\"quarterly report\" larger:1M")
                        example("in:inbox is:unread has:attachment")
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func section<Content: View>(
        title: LocalizedStringKey, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func bullet(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(key)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func example(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

#Preview {
    SearchHelpView()
}
