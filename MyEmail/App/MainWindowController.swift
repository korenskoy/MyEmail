//
//  MainWindowController.swift
//  MyEmail
//
//  AppKit-owned main window. Programmatic NSWindow + NSToolbar + SwiftUI
//  RootView inside NSHostingView. Observes AppState via one-shot
//  withObservationTracking and re-arms each change.
//
//  Handles toolbar actions and @objc menu actions via responder chain.
//  Search dispatch logic lives in MainWindowController+Search.swift.
//

import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let appState: AppState
    let environment: AppEnvironment

    let toolbarDelegate = MainToolbarDelegate()

    /// Running debounce task for search text changes. Replaced on each keystroke.
    var searchDebounceTask: Task<Void, Never>?

    init(appState: AppState, environment: AppEnvironment) {
        self.appState = appState
        self.environment = environment

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MyEmail"
        window.minSize = NSSize(width: 900, height: 600)
        window.identifier = mainWindowIdentifier
        // Manual frame persistence — `setFrameAutosaveName` stopped
        // restoring reliably once the window's identifier was used
        // elsewhere (toolbar/state restoration). Read/write our own
        // UserDefaults key; delegate methods below save on every move.
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            window.center()
        }

        let rootView = RootView()
            .environment(appState)
            .environment(environment)
            .environment(environment.logService)

        window.contentView = NSHostingView(rootView: rootView)

        let toolbar = NSToolbar(identifier: "MainToolbar.v2")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        toolbarDelegate.toolbar = toolbar

        super.init(window: window)
        window.delegate = self

        wireToolbar()
        trackTitle()
        trackThreading()
        trackToolbarVisibility()
        updateWindowTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func showMain() {
        showWindow(nil)
        // Set autosaveName on the internal NSSplitView(s) created by
        // NavigationSplitView/HSplitView so divider positions persist.
        // Must happen before makeKeyAndOrderFront to avoid layout jump.
        installSplitViewAutosave()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installSplitViewAutosave() {
        guard let contentView = window?.contentView else { return }
        let splits = Self.findAllSplitViews(in: contentView)
        for (index, split) in splits.enumerated() {
            split.autosaveName = "MyEmailSplit\(index)"
        }
    }

    nonisolated private static func findAllSplitViews(in view: NSView) -> [NSSplitView] {
        var result: [NSSplitView] = []
        if let split = view as? NSSplitView {
            result.append(split)
        }
        for child in view.subviews {
            result.append(contentsOf: findAllSplitViews(in: child))
        }
        return result
    }

    // MARK: - Toolbar wiring

    private func wireToolbar() {
        toolbarDelegate.onAction = { [weak self] id in
            self?.handleToolbarAction(id)
        }
        toolbarDelegate.onSearchTextChanged = { [weak self] text in
            self?.handleSearchTextChanged(text)
        }
    }

    private func handleToolbarAction(_ id: String) {
        switch id {
        case "getMail":           getMail(nil)
        case "compose":           newMessage(nil)
        case "reply":             replyToMessage(nil)
        case "replyAll":          replyAllToMessage(nil)
        case "forward":           forwardMessage(nil)
        case "archive":           archiveMessage(nil)
        case "delete":            deleteMessage(nil)
        case "markRead":          toggleReadState(nil)
        case "flag":              toggleFlag(nil)
        case "junk":              markAsJunk(nil)
        case "threadingFlat":     appState.isThreaded = false
        case "threadingThreaded": appState.isThreaded = true
        case "toggleLog":
            let key = "debugLogPanelVisible"
            UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        default:                  break
        }
    }

    // MARK: - Observation (canonical one-shot pattern)

    private func trackTitle() {
        withObservationTracking {
            _ = appState.selectedSidebarItem
            _ = appState.selectedFolder
            _ = appState.messageItems.count
            _ = appState.isSearchActive
            _ = appState.searchResults.count
            _ = appState.isUnifiedInbox
            updateWindowTitle()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackTitle() }
        }
    }

    private func trackThreading() {
        withObservationTracking {
            _ = appState.isThreaded
            toolbarDelegate.refreshThreadingSelection(isThreaded: appState.isThreaded)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackThreading() }
        }
    }

    /// Hide toolbar when no accounts — empty state should present only the
    /// welcome card, no chrome to click on.
    private func trackToolbarVisibility() {
        withObservationTracking {
            let hasAccounts = !appState.accounts.isEmpty
            window?.toolbar?.isVisible = hasAccounts
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackToolbarVisibility() }
        }
    }

    /// Synchronous title/subtitle mutation. Safe because the chrome is AppKit-owned
    /// and this is never called from inside a SwiftUI layout pass.
    func updateWindowTitle() {
        guard let window else { return }

        let title: String
        let count: Int

        if appState.isSearchActive {
            title = String(localized: "Search Results")
            count = appState.searchResults.count
        } else if appState.isUnifiedInbox {
            title = String(localized: "Unified Inbox")
            count = appState.messageItems.count
        } else if let folder = appState.selectedFolder {
            title = folder.localizedName
            count = appState.messageItems.count
        } else {
            title = "MyEmail"
            count = 0
        }

        if count > 0 {
            window.title = "\(title) — \(count)"
        } else {
            window.title = title
        }
    }

    // MARK: - @objc action selectors (toolbar + menu responder chain)

    @objc func getMail(_ sender: Any?) {
        let accounts = appState.accounts.filter { $0.isEnabled }
        Task { [environment] in
            for account in accounts {
                await environment.syncService.syncAccount(account)
            }
        }
    }

    @objc func newMessage(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openCompose(mode: .newMessage)
    }

    @objc func replyToMessage(_ sender: Any?) {
        guard let msgID = appState.selectedMessageID,
              let accID = accountID(for: msgID) else { return }
        (NSApp.delegate as? AppDelegate)?
            .openCompose(mode: .reply(messageID: msgID, accountID: accID))
    }

    @objc func replyAllToMessage(_ sender: Any?) {
        guard let msgID = appState.selectedMessageID,
              let accID = accountID(for: msgID) else { return }
        (NSApp.delegate as? AppDelegate)?
            .openCompose(mode: .replyAll(messageID: msgID, accountID: accID))
    }

    @objc func forwardMessage(_ sender: Any?) {
        guard let msgID = appState.selectedMessageID,
              let accID = accountID(for: msgID) else { return }
        (NSApp.delegate as? AppDelegate)?
            .openCompose(mode: .forward(messageID: msgID, accountID: accID))
    }

    @objc func archiveMessage(_ sender: Any?) {
        let ids = Array(appState.selectedMessageIDs)
        guard !ids.isEmpty else { return }
        let um = window?.undoManager
        Task { [environment] in
            await environment.undoService.archiveMessages(ids, undoManager: um)
        }
    }

    @objc func deleteMessage(_ sender: Any?) {
        let ids = Array(appState.selectedMessageIDs)
        guard !ids.isEmpty else { return }
        let um = window?.undoManager
        Task { [environment] in
            await environment.undoService.deleteMessages(ids, undoManager: um)
        }
    }

    @objc func toggleReadState(_ sender: Any?) {
        let ids = Array(appState.selectedMessageIDs)
        guard !ids.isEmpty else { return }
        let um = window?.undoManager
        let anyUnread = ids.contains { id in
            appState.messageItems.first { $0.id == id }?.isRead == false
        }
        Task { [environment] in
            if anyUnread {
                await environment.undoService.markAsRead(ids, undoManager: um)
            } else {
                await environment.undoService.markAsUnread(ids, undoManager: um)
            }
        }
    }

    @objc func toggleFlag(_ sender: Any?) {
        let ids = Array(appState.selectedMessageIDs)
        guard !ids.isEmpty else { return }
        let um = window?.undoManager
        let anyUnflagged = ids.contains { id in
            appState.messageItems.first { $0.id == id }?.isFlagged == false
        }
        Task { [environment] in
            await environment.undoService.setFlagged(ids, flagged: anyUnflagged, undoManager: um)
        }
    }

    @objc func markAsJunk(_ sender: Any?) {
        let ids = Array(appState.selectedMessageIDs)
        guard !ids.isEmpty else { return }
        Task { [environment] in
            await environment.syncService.markAsJunk(ids)
        }
    }

    @objc func toggleThreading(_ sender: Any?) {
        appState.isThreaded.toggle()
    }

    @objc func openSelectedMessageInNewWindow(_ sender: Any?) {
        guard let msgID = appState.selectedMessageIDs.first else { return }
        (NSApp.delegate as? AppDelegate)?.openMessage(id: msgID)
    }

    @objc func customizeToolbar(_ sender: Any?) {
        window?.toolbar?.runCustomizationPalette(nil)
    }

    @objc func findInCurrentFolder(_ sender: Any?) {
        focusSearchField()
    }

    @objc func globalSearch(_ sender: Any?) {
        appState.searchScope = .allAccounts
        focusSearchField()
    }

    private func focusSearchField() {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items {
            if let search = item as? NSSearchToolbarItem {
                search.beginSearchInteraction()
                return
            }
        }
    }

    // MARK: - Helpers

    private func accountID(for id: UUID) -> UUID? {
        if let acc = appState.selectedFolder?.accountID { return acc }
        return appState.messageItems.first { $0.id == id }?.accountID
    }

    // MARK: - Frame persistence

    private static let frameDefaultsKey = "MyEmailMainWindowFrame"

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(
            NSStringFromRect(frame),
            forKey: Self.frameDefaultsKey
        )
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
    }
}

// MARK: - NSUserInterfaceValidations

extension MainWindowController: NSUserInterfaceValidations {
    nonisolated func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        // Runs off main — use MainActor.assumeIsolated since we only read
        // MainActor-bound state and the caller guarantees main queue.
        MainActor.assumeIsolated {
            guard let selector = item.action else { return true }
            let hasSelection = !appState.selectedMessageIDs.isEmpty
            switch selector {
            case #selector(replyToMessage(_:)),
                 #selector(replyAllToMessage(_:)),
                 #selector(forwardMessage(_:)),
                 #selector(archiveMessage(_:)),
                 #selector(deleteMessage(_:)),
                 #selector(toggleReadState(_:)),
                 #selector(toggleFlag(_:)),
                 #selector(markAsJunk(_:)),
                 #selector(openSelectedMessageInNewWindow(_:)):
                return hasSelection
            case #selector(newMessage(_:)):
                return !appState.accounts.isEmpty
            default:
                return true
            }
        }
    }
}
