//
//  MessageDetailView.swift
//  MyEmail
//
//  Message reading pane: headers + HTML body + attachments.
//  Body fetched on demand via SyncService.loadFullMessage(id:).
//

import SwiftUI
import SwiftMail

struct MessageDetailView: View {
    let messageID: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(AppState.self) private var appState
    @State private var message: Message?
    @State private var isLoading = false
    @State private var allowRemoteContent = false
    @State private var inlineRefs: [InlineRef] = []
    @State private var attachments: [Attachment] = []
    @State private var sourceSheet: SourceSheet?
    // Cached prepared HTML — rebuilt off main thread when renderKey changes.
    // Prevents HTMLHeadInjector.prepare() regex running on every SwiftUI body re-eval.
    @State private var renderedBodyHTML: String = ""
    // Which mode renderedBodyHTML was built for. Gates the web view so it never
    // loads the other mode's stale content during the async rebuild window —
    // a double loadHTMLString on a freshly recreated WKWebView blanks it.
    @State private var renderedForMode: RenderMode = .none
    @State private var bodyVersion: Int = 0
    @Environment(\.undoManager) private var undoManager
    @AppStorage("enableGravatar") private var enableGravatar = false
    // Global body-format preference: true → render HTML when available,
    // false → prefer plain text. Persists across messages and launches.
    @AppStorage("preferPlainBody") private var preferPlainBody = false
    @AppStorage("plainTextFontSize") private var plainFontSize: Int = 13
    @AppStorage("plainTextMonospace") private var plainMonospace: Bool = false
    @AppStorage("plainTextQuoteColor1") private var plainQuoteColor1: String = "#7B5EA7"
    @AppStorage("plainTextQuoteColor2") private var plainQuoteColor2: String = "#1A9D7A"
    @AppStorage("plainTextQuoteColor3") private var plainQuoteColor3: String = "#28A745"

    private enum RenderMode: Hashable {
        case html, plain, encrypted, attachmentsOnly, none
    }

    private var renderMode: RenderMode {
        guard let msg = message else { return .none }
        let hasHTML = !(msg.bodyHTML ?? "").isEmpty
        let hasText = !(msg.bodyText ?? "").isEmpty
        if hasHTML && !(preferPlainBody && hasText) { return .html }
        if hasText { return .plain }
        if msg.isEncrypted { return .encrypted }
        if !attachments.isEmpty { return .attachmentsOnly }
        return .none
    }

    private struct RenderKey: Hashable {
        let messageID: UUID
        let mode: RenderMode
        let bodyVersion: Int
        let allowRemote: Bool
        let inlineRefsCount: Int
        let plainFontSize: Int
        let plainMonospace: Bool
        let plainQuoteColor1: String
        let plainQuoteColor2: String
        let plainQuoteColor3: String
    }

    private var renderKey: RenderKey {
        RenderKey(
            messageID: messageID,
            mode: renderMode,
            bodyVersion: bodyVersion,
            allowRemote: allowRemoteContent,
            inlineRefsCount: inlineRefs.count,
            plainFontSize: plainFontSize,
            plainMonospace: plainMonospace,
            plainQuoteColor1: plainQuoteColor1,
            plainQuoteColor2: plainQuoteColor2,
            plainQuoteColor3: plainQuoteColor3
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let message {
                MessageHeaderBar(
                    message: message,
                    gravatarImage: enableGravatar
                        ? env.gravatarService.avatar(for: EmailAddress.emailOnly(from: message.fromAddress))
                        : nil,
                    onReply: { openCompose(.reply(messageID: message.id, accountID: message.accountID)) },
                    onReplyAll: { openCompose(.replyAll(messageID: message.id, accountID: message.accountID)) },
                    onForward: { openCompose(.forward(messageID: message.id, accountID: message.accountID)) },
                    onViewSource: { Task { await viewSource() } },
                    onArchive: {
                        let id = message.id
                        Task { await env.undoService.archiveMessages([id], undoManager: undoManager) }
                    },
                    onDelete: {
                        let id = message.id
                        Task { await env.undoService.deleteMessages([id], undoManager: undoManager) }
                    },
                    onMarkSpam: {
                        let id = message.id
                        Task { await env.syncService.markAsJunk([id]) }
                    }
                )
                Divider()
                bodyContent(message)
                if hasBothFormats(message) {
                    BodyFormatTabs(preferPlainBody: $preferPlainBody)
                }
                if !attachments.isEmpty {
                    Divider()
                    AttachmentStripView(
                        attachments: attachments,
                        onRefetch: { att in
                            try? await env.syncService.refetchAttachment(att)
                        }
                    )
                }
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(String(localized: "Failed to load message"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: messageID) { await loadBody() }
        .task(id: renderKey) { await rebuildRenderedHTML() }
        .onReceive(NotificationCenter.default.publisher(for: .messageDidResync)) { note in
            guard (note.object as? String).flatMap(UUID.init) == messageID else { return }
            Task { await loadBody() }
        }
        .sheet(item: $sourceSheet) { sheet in
            RawSourceView(source: sheet.source, onDismiss: { sourceSheet = nil })
        }
    }

    private func openCompose(_ mode: ComposeMode) {
        (NSApp.delegate as? AppDelegate)?.openCompose(mode: mode)
    }

    // MARK: - Body

    private func hasBothFormats(_ msg: Message) -> Bool {
        let hasHTML = !(msg.bodyHTML ?? "").isEmpty
        let hasText = !(msg.bodyText ?? "").isEmpty
        return hasHTML && hasText
    }

    @ViewBuilder
    private func bodyContent(_ msg: Message) -> some View {
        switch renderMode {
        case .html:
            VStack(spacing: 0) {
                if !allowRemoteContent {
                    RemoteContentBanner(
                        senderEmail: msg.fromAddress,
                        onAllow: { allowRemoteContent = true },
                        onTrustSender: { trustSender(msg.fromAddress); allowRemoteContent = true }
                    )
                }
                if renderedForMode == .html, !renderedBodyHTML.isEmpty {
                    HTMLMailView(
                        html: renderedBodyHTML,
                        baseURL: nil,
                        inlineRefs: inlineRefs
                    )
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .plain:
            if renderedForMode == .plain, !renderedBodyHTML.isEmpty {
                HTMLMailView(html: renderedBodyHTML, baseURL: nil)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .encrypted:
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(String(localized: "Encrypted message (PGP/GPG)"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(String(localized: "MyEmail does not support PGP/GPG decryption. Use a compatible application to read this message."))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .attachmentsOnly:
            VStack(spacing: 8) {
                Image(systemName: "paperclip")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(String(localized: "Attachment-only message"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(String(localized: "This message contains attachments only. See the attachment bar below."))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .none:
            VStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Message body unavailable"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Rebuilds the cached HTML off the main thread. Driven by `.task(id: renderKey)`.
    /// SwiftUI cancels the previous task when renderKey changes — we honor cancellation
    /// after the detached work to avoid overwriting with stale output.
    private func rebuildRenderedHTML() async {
        let mode = renderMode
        switch mode {
        case .html:
            guard let msg = message else { renderedBodyHTML = ""; renderedForMode = .none; return }
            let html = msg.bodyHTML ?? ""
            let refs = inlineRefs
            let allow = allowRemoteContent
            let out = await Task.detached(priority: .userInitiated) {
                HTMLHeadInjector.prepare(
                    html: html, allowRemoteContent: allow, inlineAttachments: refs
                )
            }.value
            if Task.isCancelled { return }
            renderedBodyHTML = out
            renderedForMode = .html
        case .plain:
            guard let msg = message else { renderedBodyHTML = ""; renderedForMode = .none; return }
            let text = msg.bodyText ?? ""
            let size = plainFontSize
            let mono = plainMonospace
            let c1 = plainQuoteColor1
            let c2 = plainQuoteColor2
            let c3 = plainQuoteColor3
            let out = await Task.detached(priority: .userInitiated) {
                HTMLHeadInjector.wrapPlainText(
                    text, fontSize: size, monospace: mono,
                    quoteColor1: c1, quoteColor2: c2, quoteColor3: c3
                )
            }.value
            if Task.isCancelled { return }
            renderedBodyHTML = out
            renderedForMode = .plain
        case .encrypted, .attachmentsOnly, .none:
            renderedBodyHTML = ""
            renderedForMode = mode
        }
    }

    @AppStorage("blockRemoteContent") private var blockRemoteContent = true

    private func loadBody() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let loadedMsg = try await env.syncService.loadFullMessage(id: messageID)

            var newInlineRefs: [InlineRef] = []
            var newAttachments: [Attachment] = []
            var shouldAutoAllow = false

            if let msg = loadedMsg {
                let loaded = try await env.syncService.loadAttachments(for: msg.id)
                newInlineRefs = loaded.inlineRefs
                newAttachments = loaded.regular
                shouldAutoAllow = !blockRemoteContent || isSenderTrusted(msg.fromAddress)
            }

            // Batched state commit — single body re-eval → single rebuildRenderedHTML
            message = loadedMsg
            inlineRefs = newInlineRefs
            attachments = newAttachments
            allowRemoteContent = shouldAutoAllow
            bodyVersion &+= 1

            // Mark-as-read is not needed to display the body — fire it after the
            // commit so the body shows immediately instead of blocking on the DB
            // write queue (contended by prefetch).
            if let msg = loadedMsg, !msg.isRead {
                Task { await env.syncService.markAsRead([msg.id]) }
            }
        } catch {
            LogService.log(.error, .sync, "Failed to load message body", detail: "\(error)")
        }
    }

    private func isSenderTrusted(_ address: String) -> Bool {
        env.trustedSenderService.isTrusted(EmailAddress.emailOnly(from: address))
    }

    private func trustSender(_ address: String) {
        env.trustedSenderService.addTrusted(EmailAddress.emailOnly(from: address))
    }

    private func viewSource() async {
        do {
            let src = try await env.syncService.fetchRawSource(messageID: messageID)
            sourceSheet = SourceSheet(source: src)
        } catch {
            sourceSheet = SourceSheet(source: nil)
            LogService.log(.error, .sync, "View Source failed", detail: "\(error)")
        }
    }
}

// MARK: - Body format tabs

/// Excel-style bottom tab strip for switching between HTML and plain-text
/// rendering of a message. Shown only when both variants are non-empty.
/// The choice persists globally via `@AppStorage("preferPlainBody")`.
private struct BodyFormatTabs: View {
    @Binding var preferPlainBody: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                tab(
                    title: String(localized: "HTML"),
                    selected: !preferPlainBody
                ) { preferPlainBody = false }
                tab(
                    title: String(localized: "Plain text"),
                    selected: preferPlainBody
                ) { preferPlainBody = true }
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func tab(
        title: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background(
                    selected
                        ? Color(NSColor.controlBackgroundColor)
                        : Color.clear
                )
                .overlay(alignment: .trailing) {
                    // Separator between tabs (Excel-like).
                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(width: 1)
                }
        }
        .buttonStyle(.plain)
    }
}
