//
//  ToolbarBridge.swift
//  MyEmail
//
//  NSToolbar item identifiers and delegate. The toolbar itself is
//  installed programmatically by MainWindowController — there is no
//  SwiftUI bridge layer anymore.
//

import AppKit

// MARK: - Toolbar item identifiers

extension NSToolbarItem.Identifier {
    static let getMail            = NSToolbarItem.Identifier("getMail")
    static let compose            = NSToolbarItem.Identifier("compose")
    static let archive            = NSToolbarItem.Identifier("archive")
    static let tbDelete           = NSToolbarItem.Identifier("delete")
    static let reply              = NSToolbarItem.Identifier("reply")
    static let replyAll           = NSToolbarItem.Identifier("replyAll")
    static let forward            = NSToolbarItem.Identifier("forward")
    static let markRead           = NSToolbarItem.Identifier("markRead")
    static let flag               = NSToolbarItem.Identifier("flag")
    static let junk               = NSToolbarItem.Identifier("junk")
    static let search             = NSToolbarItem.Identifier("search")
    static let threadingFlat      = NSToolbarItem.Identifier("threadingFlat")
    static let threadingThreaded  = NSToolbarItem.Identifier("threadingThreaded")
    static let toggleLog          = NSToolbarItem.Identifier("toggleLog")
}

// MARK: - Main-window identifier

/// Stable identifier set on the main window after toolbar install, so that
/// title-update helpers can reliably find it regardless of current `title`.
let mainWindowIdentifier = NSUserInterfaceItemIdentifier("MyEmailMainWindow")

// MARK: - Toolbar delegate

@MainActor
final class MainToolbarDelegate: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    var onAction: ((String) -> Void)?
    var onSearchTextChanged: ((String) -> Void)?

    weak var toolbar: NSToolbar?

    private let defaultItems: [NSToolbarItem.Identifier] = [
        .getMail,
        .space,
        .archive, .tbDelete, .junk,
        .space,
        .compose, .reply, .replyAll, .forward,
        .space,
        .markRead, .flag,
        .flexibleSpace,
        .toggleLog,
        .threadingFlat, .threadingThreaded,
        .search,
    ]

    private let allItems: [NSToolbarItem.Identifier] = [
        .getMail,
        .compose, .archive, .tbDelete, .junk,
        .reply, .replyAll, .forward,
        .markRead, .flag,
        .toggleLog,
        .threadingFlat, .threadingThreaded,
        .search,
        .flexibleSpace, .space,
    ]

    // MARK: - NSToolbarDelegate

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .search:
            return makeSearchItem()
        default:
            return makeButtonItem(itemIdentifier)
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultItems
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        allItems
    }

    // MARK: - Button items

    private struct ButtonDef {
        let label: String; let icon: String
    }

    private static let defs: [NSToolbarItem.Identifier: ButtonDef] = [
        .getMail: ButtonDef(label: String(localized: "Get Mail"), icon: "tray.and.arrow.down"),
        .compose: ButtonDef(label: String(localized: "New Message"), icon: "square.and.pencil"),
        .archive: ButtonDef(label: String(localized: "Archive"), icon: "archivebox"),
        .tbDelete: ButtonDef(label: String(localized: "Delete"), icon: "trash"),
        .reply: ButtonDef(label: String(localized: "Reply"), icon: "arrowshape.turn.up.left"),
        .replyAll: ButtonDef(label: String(localized: "Reply All"), icon: "arrowshape.turn.up.left.2"),
        .forward: ButtonDef(label: String(localized: "Forward"), icon: "arrowshape.turn.up.right"),
        .markRead: ButtonDef(label: String(localized: "Read/Unread"), icon: "envelope.open"),
        .flag: ButtonDef(label: String(localized: "Flag"), icon: "flag"),
        .junk: ButtonDef(label: String(localized: "Junk"), icon: "xmark.bin"),
        .toggleLog: ButtonDef(label: String(localized: "Toggle Log"), icon: "terminal"),
        .threadingFlat: ButtonDef(label: String(localized: "Flat View"), icon: "list.bullet"),
        .threadingThreaded: ButtonDef(label: String(localized: "Threaded View"), icon: "list.bullet.indent"),
    ]

    private func buttonDef(for id: NSToolbarItem.Identifier) -> ButtonDef? {
        Self.defs[id]
    }

    private func makeButtonItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let def = buttonDef(for: id) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = def.label
        item.paletteLabel = def.label
        item.toolTip = def.label
        item.image = NSImage(systemSymbolName: def.icon, accessibilityDescription: def.label)
        item.target = self
        item.action = #selector(buttonClicked(_:))
        return item
    }

    @objc private func buttonClicked(_ sender: NSToolbarItem) {
        onAction?(sender.itemIdentifier.rawValue)
    }

    // MARK: - Threading selection visuals

    /// Updates icon fill state of the threading items to reflect current mode.
    /// Same symbol family, only fill variation changes — no size jump.
    /// Synchronous mutation is safe because this runs from MainWindowController's
    /// withObservationTracking callback, which lives outside any SwiftUI layout pass.
    func refreshThreadingSelection(isThreaded: Bool) {
        guard let toolbar else { return }
        let accent = NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])
        let muted = NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor])
        for item in toolbar.items {
            switch item.itemIdentifier {
            case .threadingFlat:
                item.image = NSImage(
                    systemSymbolName: "list.bullet",
                    accessibilityDescription: item.label
                )?.withSymbolConfiguration(isThreaded ? muted : accent)
            case .threadingThreaded:
                item.image = NSImage(
                    systemSymbolName: "list.bullet.indent",
                    accessibilityDescription: item.label
                )?.withSymbolConfiguration(isThreaded ? accent : muted)
            default:
                break
            }
        }
    }

    // MARK: - Search item

    private func makeSearchItem() -> NSSearchToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: .search)
        item.searchField.delegate = self
        item.searchField.placeholderString = String(localized: "Search…")
        return item
    }

    // NSSearchFieldDelegate
    nonisolated func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        let text = field.stringValue
        Task { @MainActor in onSearchTextChanged?(text) }
    }

    nonisolated func control(
        _ control: NSControl, textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            Task { @MainActor in onSearchTextChanged?("") }
            (control as? NSSearchField)?.stringValue = ""
            return true
        }
        return false
    }
}

