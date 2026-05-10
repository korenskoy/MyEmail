//
//  SettingsWindowController.swift
//  MyEmail
//
//  AppKit-owned Settings window. No NSToolbar — standard title bar only.
//  Content is SwiftUI SettingsSplitView inside NSHostingView.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    init(appState: AppState, environment: AppEnvironment) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Settings")
        window.minSize = NSSize(width: 860, height: 560)
        window.setFrameAutosaveName("MyEmailSettingsWindow")
        window.isReleasedWhenClosed = false

        let rootView = SettingsSplitView()
            .environment(appState)
            .environment(environment)
            .environment(environment.logService)

        let host = NSHostingView(rootView: rootView)
        window.contentView = host

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Show or raise the Settings window. Safe to call repeatedly — the window
    /// is sticky (`isReleasedWhenClosed = false`), so the same instance re-appears.
    func show() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
