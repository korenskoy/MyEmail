//
//  MessageListNSCells.swift
//  MyEmail
//
//  AppKit NSTableCellView subclasses used by MessageListNSTable.
//  Pure AppKit — no SwiftUI bridging inside cells. This is what keeps
//  the header row (and everything else) rock-solid across data updates.
//

import AppKit

// MARK: - Status column (thread count OR flag star)

final class StatusCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let star  = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.isHidden = true

        star.translatesAutoresizingMaskIntoConstraints = false
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        star.contentTintColor = .systemOrange
        star.imageScaling = .scaleProportionallyDown
        star.isHidden = true

        addSubview(label)
        addSubview(star)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.centerXAnchor.constraint(equalTo: centerXAnchor),
            star.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: 11),
            star.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    func configure(text: String?, showStar: Bool) {
        if let t = text {
            label.stringValue = t
            label.isHidden = false
            star.isHidden = true
        } else {
            label.isHidden = true
            star.isHidden = !showStar
        }
    }
}

// MARK: - Subject column (unread dot + bold/regular text)

final class SubjectCellView: NSTableCellView {
    private let dot = DotView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func setup() {
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.isScrollable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    func configure(subject: String, isUnread: Bool) {
        dot.isHidden = !isUnread
        label.stringValue = subject
        label.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: isUnread ? .semibold : .regular
        )
    }
}

// MARK: - Attachment column (paperclip icon when message has attachments)

final class AttachmentCellView: NSTableCellView {
    private let paperclip = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func setup() {
        paperclip.translatesAutoresizingMaskIntoConstraints = false
        paperclip.image = NSImage(systemSymbolName: "paperclip",
                                  accessibilityDescription: nil)
        paperclip.contentTintColor = .secondaryLabelColor
        paperclip.imageScaling = .scaleProportionallyDown
        paperclip.isHidden = true
        addSubview(paperclip)
        NSLayoutConstraint.activate([
            paperclip.centerXAnchor.constraint(equalTo: centerXAnchor),
            paperclip.centerYAnchor.constraint(equalTo: centerYAnchor),
            paperclip.widthAnchor.constraint(equalToConstant: 11),
            paperclip.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    func configure(hasAttachment: Bool) {
        paperclip.isHidden = !hasAttachment
    }
}

/// Small filled circle drawn via CALayer for crisp sub-pixel rendering.
private final class DotView: NSView {
    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func updateLayer() {
        guard let layer = layer else { return }
        layer.backgroundColor = NSColor.controlAccentColor.cgColor
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }
}

// MARK: - Plain text cell (From/To, Date, Size, Account)

final class PlainTextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.isScrollable = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(text: String,
                   bold: Bool,
                   secondary: Bool,
                   alignment: NSTextAlignment,
                   monospaced: Bool) {
        label.stringValue = text
        label.alignment = alignment
        label.textColor = secondary ? .secondaryLabelColor : .labelColor

        let size = NSFont.systemFontSize
        let weight: NSFont.Weight = bold ? .semibold : .regular
        label.font = monospaced
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
    }
}
