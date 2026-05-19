//
//  ComposeWindowController.swift
//  MyEmail
//
//  AppKit-owned Compose window. Multi-instance — N drafts = N controllers
//  keyed by instanceID in AppDelegate.composeControllers.
//

import AppKit
import SwiftUI

@MainActor
final class ComposeWindowController: NSWindowController, NSWindowDelegate {
    let instanceID: UUID
    private let onClose: (UUID) -> Void

    init(
        mode: ComposeMode,
        appState: AppState,
        environment: AppEnvironment,
        onClose: @escaping (UUID) -> Void
    ) {
        let instanceID = UUID()
        self.instanceID = instanceID
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.title(for: mode)
        window.minSize = NSSize(width: 560, height: 400)
        // Manual frame persistence: NSWindow.setFrameAutosaveName refuses to
        // save when another window already uses the same name, which breaks
        // multi-instance Compose. Restore from UserDefaults instead.
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            window.center()
        }

        // SwiftUI `@Environment(\.dismiss)` does not resolve inside an
        // AppKit-owned NSHostingView — use an explicit closure.
        let dismiss: () -> Void = { [weak window] in
            window?.performClose(nil)
        }

        let rootView = ComposeWindowContent(mode: mode, dismiss: dismiss)
            .environment(appState)
            .environment(environment)
            .environment(environment.logService)

        window.contentView = NSHostingView(rootView: rootView)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        onClose(instanceID)
    }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(
            NSStringFromRect(frame),
            forKey: Self.frameDefaultsKey
        )
    }

    private static let frameDefaultsKey = "MyEmailComposeWindowFrame"

    // MARK: - Titles

    private static func title(for mode: ComposeMode) -> String {
        switch mode {
        case .newMessage, .mailto: return String(localized: "New Message")
        case .reply:               return String(localized: "Reply")
        case .replyAll:            return String(localized: "Reply All")
        case .forward:             return String(localized: "Forward")
        }
    }
}
