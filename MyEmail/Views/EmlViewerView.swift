//
//  EmlViewerView.swift
//  MyEmail
//
//  Read-only viewer for a raw `.eml` file parsed by SwiftEmailParser.
//  Unlike `MessageDetailView`, this view never touches GRDB — all data
//  (headers, body, attachments) comes straight from the in-memory
//  `EmailMessage` and the per-window tmpdir managed by
//  `EmlViewerWindowController`.
//

import SwiftEmailParser
import SwiftUI

struct EmlViewerView: View {
    let email: EmailMessage
    let attachments: [MyEmail.Attachment]
    let inlineRefs: [InlineRef]

    @AppStorage("blockRemoteContent") private var blockRemoteContent = true
    @AppStorage("plainTextFontSize") private var plainFontSize: Int = 13
    @AppStorage("plainTextMonospace") private var plainMonospace: Bool = false
    @AppStorage("plainTextQuoteColor1") private var plainQuoteColor1: String = "#7B5EA7"
    @AppStorage("plainTextQuoteColor2") private var plainQuoteColor2: String = "#1A9D7A"
    @AppStorage("plainTextQuoteColor3") private var plainQuoteColor3: String = "#28A745"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    private var visibleAttachments: [MyEmail.Attachment] {
        attachments.filter { !$0.isInline }
    }

    var body: some View {
        VStack(spacing: 0) {
            EmlViewerHeader(email: email, dateFormatter: Self.dateFormatter)
            Divider()
            bodyArea
            if !visibleAttachments.isEmpty {
                Divider()
                AttachmentStripView(
                    attachments: visibleAttachments,
                    onRefetch: { _ in nil }
                )
            }
        }
    }

    @ViewBuilder
    private var bodyArea: some View {
        let html = renderedHTML
        if let html, !html.isEmpty {
            HTMLMailView(html: html, baseURL: nil, inlineRefs: inlineRefs)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Spacer()
                Text("No body content")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var renderedHTML: String? {
        if let html = email.htmlBody, !html.isEmpty {
            return HTMLHeadInjector.prepare(
                html: html,
                allowRemoteContent: !blockRemoteContent,
                inlineAttachments: inlineRefs
            )
        }
        let text = (email.textBody ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return HTMLHeadInjector.wrapPlainText(
            email.textBody ?? "",
            fontSize: plainFontSize,
            monospace: plainMonospace,
            quoteColor1: plainQuoteColor1,
            quoteColor2: plainQuoteColor2,
            quoteColor3: plainQuoteColor3
        )
    }
}

// MARK: - Header subview

private struct EmlViewerHeader: View {
    let email: EmailMessage
    let dateFormatter: DateFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let subject = email.subject, !subject.isEmpty {
                Text(subject)
                    .font(.system(size: 16, weight: .bold))
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Text("From:")
                    .foregroundStyle(.secondary)
                Text(formattedAddresses(email.from))
                    .textSelection(.enabled)
            }
            .font(.system(size: 12))
            if !email.to.isEmpty {
                HStack(spacing: 6) {
                    Text("To:")
                        .foregroundStyle(.secondary)
                    Text(formattedAddresses(email.to))
                        .textSelection(.enabled)
                }
                .font(.system(size: 12))
            }
            if !email.cc.isEmpty {
                HStack(spacing: 6) {
                    Text("Cc:")
                        .foregroundStyle(.secondary)
                    Text(formattedAddresses(email.cc))
                        .textSelection(.enabled)
                }
                .font(.system(size: 12))
            }
            if let date = email.date {
                Text(dateFormatter.string(from: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func formattedAddresses(_ addrs: [EmailAddress]) -> String {
        addrs.map { addr in
            if let name = addr.name, !name.isEmpty {
                return "\(name) <\(addr.address)>"
            }
            return addr.address
        }
        .joined(separator: ", ")
    }
}
