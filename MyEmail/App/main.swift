//
//  main.swift
//  MyEmail
//
//  AppKit entry point. Replaces `@main struct MyEmailApp: App`.
//  Gives us deterministic control over NSApp bootstrap, menu bar, and
//  window orchestration — all chrome is AppKit-owned, SwiftUI is
//  strictly content inside NSHostingView.
//

import AppKit

let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
}
app.run()
