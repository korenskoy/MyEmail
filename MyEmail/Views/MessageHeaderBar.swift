//
//  MessageHeaderBar.swift
//  MyEmail
//
//  Message header: sender, recipients, subject, date, action buttons.
//

import AppKit
import SwiftUI
import SwiftMail

struct MessageHeaderBar: View {
    let message: Message
    var gravatarImage: NSImage?
    var onReply: (() -> Void)?
    var onReplyAll: (() -> Void)?
    var onForward: (() -> Void)?
    var onViewSource: (() -> Void)?
    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMarkSpam: (() -> Void)?

    @AppStorage("showMailUserAgent") private var showMUA: Bool = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        // Parse once — avoid re-parsing the same address 3× per body re-eval.
        let fromEmail = EmailAddress.emailOnly(from: message.fromAddress)
        let fromDisplayName = (message.fromName?.isEmpty == false ? message.fromName : nil)
            ?? EmailAddress.displayName(from: message.fromAddress)

        VStack(alignment: .leading, spacing: 8) {
            // Sender row: avatar + name/email + action buttons
            HStack(alignment: .top, spacing: 10) {
                senderAvatar(email: fromEmail)

                VStack(alignment: .leading, spacing: 2) {
                    AddressTokenView(
                        displayName: fromDisplayName,
                        email: fromEmail,
                        font: .system(size: 15, weight: .semibold)
                    )

                    Text(fromEmail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        // Line up with the sender name above — Menu's
                        // borderlessButton label has a hidden ~3pt leading
                        // inset that plain Text doesn't.
                        .padding(.leading, 3)
                }

                Spacer()

                actionButtons
            }

            // Recipients
            if !message.toAddresses.isEmpty {
                AddressListRow(label: "To:", addresses: message.toAddresses)
            }
            if !message.ccAddresses.isEmpty {
                AddressListRow(label: "Cc:", addresses: message.ccAddresses)
            }
            if !message.replyToAddresses.isEmpty {
                AddressListRow(
                    label: String(localized: "Reply-To:"),
                    addresses: message.replyToAddresses
                )
            }

            // Subject
            Text(message.subject)
                .font(.system(size: 16, weight: .bold))
                .textSelection(.enabled)

            // Date line (plain text — icon is not in this row's layout).
            Text(Self.dateFormatter.string(from: message.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Icon is absolutely positioned at the bottom-right of the whole
        // header (before outer padding). Outer .padding(14) then becomes
        // the icon's margin, so trailing-margin == bottom-margin.
        .overlay(alignment: .bottomTrailing) {
            if showMUA, let ua = message.userAgent, !ua.isEmpty {
                MUAIconSlot(userAgent: ua)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func senderAvatar(email: String) -> some View {
        if let image = gravatarImage {
            Image(nsImage: image)
                .resizable()
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .transition(.opacity)
        } else {
            InitialsAvatarView(
                name: message.fromName ?? EmailAddress(message.fromAddress)?.name,
                email: email,
                size: 36
            )
        }
    }

    private var actionButtons: some View {
        // Spark-style ordering: triage actions (Archive / Delete / Spam) on
        // the left for fast left-to-right keyboard-free scanning during
        // inbox triage; compose actions (Reply / Reply All / Forward) and
        // the rarely-used View Source on the right.
        HStack(spacing: 6) {
            if let onArchive {
                Button(action: onArchive) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 14))
                }.buttonStyle(.borderless).help("Archive")
            }
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                }.buttonStyle(.borderless).help("Delete")
            }
            if let onMarkSpam {
                Button(action: onMarkSpam) {
                    Image(systemName: "exclamationmark.octagon")
                        .font(.system(size: 14))
                }.buttonStyle(.borderless).help("Mark as Spam")
            }

            if (onArchive != nil || onDelete != nil || onMarkSpam != nil)
                && (onReply != nil || onReplyAll != nil || onForward != nil || onViewSource != nil) {
                Divider().frame(height: 14).padding(.horizontal, 2)
            }

            if let onReply {
                Button(action: onReply) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 14))
                }.buttonStyle(.borderless).help("Reply")
            }
            if let onReplyAll {
                Button(action: onReplyAll) {
                    Image(systemName: "arrowshape.turn.up.left.2")
                        .font(.system(size: 14))
                }.buttonStyle(.borderless).help("Reply All")
            }
            if let onForward {
                Button(action: onForward) {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.system(size: 14))
                }.buttonStyle(.borderless).help("Forward")
            }
            if let onViewSource {
                Button(action: onViewSource) {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 14))
                }.buttonStyle(.borderless).help("View Source")
            }
        }
    }
}

// MARK: - MUA icon slot

/// Small mail-client icon rendered next to the date. Delegates detection to
/// the GPL-isolated MUAResolver XPC service; keeps a stable 14×14 frame so
/// the surrounding layout never shifts while the async resolve is in flight.
private struct MUAIconSlot: View {
    let userAgent: String
    @State private var resolved: MUAResolverClient.Resolved?

    var body: some View {
        Group {
            if let data = resolved?.pngData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .frame(width: 32, height: 32)
        .help(userAgent)
        .accessibilityLabel(Text(resolved?.displayName ?? userAgent))
        .task(id: userAgent) {
            resolved = await MUAResolverClient.shared.resolve(userAgent: userAgent)
        }
    }
}

// MARK: - Interactive address token

struct AddressTokenView: View {
    let displayName: String
    let email: String
    var font: Font = .system(size: 12)

    @Environment(AppEnvironment.self) private var env
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            Text(email)
                .font(.callout)

            Divider()

            Button(String(localized: "Copy address")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(email, forType: .string)
            }

            Button(String(localized: "Add to trusted senders")) {
                env.trustedSenderService.addTrusted(email)
            }

            Button(String(localized: "Compose message")) {
                (NSApp.delegate as? AppDelegate)?.openCompose(mode: .newMessage)
            }

            Divider()

            Button(String(localized: "Search messages") + ": \(displayName)") {
                appState.searchText = "from:\(email)"
            }
        } label: {
            Text(displayName)
                .font(font)
                .underline(false)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Address list row (To:/Cc:)

struct AddressListRow: View {
    let label: String
    let addresses: [String]
    @State private var isExpanded = false

    /// Max height of the expanded scrollable area (~5 lines at 12pt).
    private static let expandedMaxHeight: CGFloat = 100

    /// Left gutter = sender avatar width (36) so recipient tokens align
    /// with the sender name column. HStack spacing 10 matches sender row.
    private static let labelGutter: CGFloat = 36
    private static let gutterSpacing: CGFloat = 10

    /// `.menuStyle(.borderlessButton)` adds an invisible leading inset around
    /// its label in macOS 15+ (more pronounced under the macOS 26 / Tahoe
    /// button style). Measured empirically — nudge to match `From:` row.
    /// 0 means no horizontal nudge (token lines up with To: label column).
    private static let menuChromeInset: CGFloat = 0

    var body: some View {
        if isExpanded {
            expandedLayout
        } else {
            collapsedLayout
        }
    }

    // MARK: - Collapsed (single row that fits)

    private var collapsedLayout: some View {
        HStack(alignment: .center, spacing: Self.gutterSpacing) {
            labelText
                .frame(width: Self.labelGutter, alignment: .trailing)
            GeometryReader { geo in
                collapsedRow(width: geo.size.width)
            }
            .frame(height: 22)
            // Menu borderlessButton's label sits a few points above the
            // center of its hit area. Nudge the whole recipient column
            // down so the visible token text lines up with the To: label
            // baseline. Empirical: 3pt matches macOS 26 rendering.
            .offset(y: 3)
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func collapsedRow(width: CGFloat) -> some View {
        let (visible, hidden) = pickFittingTokens(width: width)
        HStack(spacing: 4) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, raw in
                token(for: raw)
            }
            if hidden > 0 {
                Button {
                    isExpanded = true
                } label: {
                    Text("and \(hidden) more")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Expanded (bounded scroll, plain text, no per-address menus)

    private var expandedLayout: some View {
        HStack(alignment: .top, spacing: Self.gutterSpacing) {
            labelText
                .frame(width: Self.labelGutter, alignment: .trailing)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(addresses.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 4)
                }
                .frame(maxHeight: Self.expandedMaxHeight)

                Button {
                    isExpanded = false
                } label: {
                    Text("Show less")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.system(size: 12))
    }

    private var labelText: some View {
        Text(label)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))
    }

    @ViewBuilder
    private func token(for raw: String) -> some View {
        let parsed = SwiftMail.EmailAddress(raw)
        let addr = parsed?.address ?? raw
        let name = parsed?.name ?? ""
        AddressTokenView(
            displayName: name.isEmpty ? addr : name,
            email: addr
        )
    }

    /// CoreText sizing — fast even for 1000+ addresses. We measure the raw
    /// string (slightly pessimistic) and reserve worst-case badge width so
    /// the layout never overflows on the second pass.
    private func pickFittingTokens(width: CGFloat) -> (visible: [String], hidden: Int) {
        guard width > 0, !addresses.isEmpty else { return ([], 0) }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12)
        ]
        let spacing: CGFloat = 4
        // Menu chevron + horizontal padding around the label.
        let chrome: CGFloat = 18
        // Worst-case badge text width — `addresses.count` is the upper bound.
        let badgeText = "and \(addresses.count) more"
        let badgeWidth = (badgeText as NSString).size(withAttributes: attrs).width + chrome

        let available = max(0, width - badgeWidth - spacing)
        var consumed: CGFloat = 0
        var visible: [String] = []
        visible.reserveCapacity(min(addresses.count, 16))

        for raw in addresses {
            let display = displayFragment(of: raw)
            let textWidth = (display as NSString).size(withAttributes: attrs).width
            let tokenWidth = textWidth + chrome
            let next = consumed + (visible.isEmpty ? 0 : spacing) + tokenWidth
            if next > available && !visible.isEmpty { break }
            consumed = next
            visible.append(raw)
        }

        if visible.count == addresses.count { return (visible, 0) }
        return (visible, addresses.count - visible.count)
    }

    /// Lightweight extraction for measurement: prefer the part shown by the
    /// token (name or email-only). Avoids the full SwiftMail parser cost in
    /// a hot loop over 1000 addresses.
    private func displayFragment(of raw: String) -> String {
        if let lt = raw.firstIndex(of: "<"), let gt = raw.firstIndex(of: ">"),
           lt < gt {
            let name = raw[..<lt].trimmingCharacters(
                in: .whitespacesAndNewlines.union(.init(charactersIn: "\""))
            )
            if !name.isEmpty { return name }
            return String(raw[raw.index(after: lt)..<gt])
        }
        return raw
    }
}
