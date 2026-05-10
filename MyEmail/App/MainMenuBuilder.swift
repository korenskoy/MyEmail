//
//  MainMenuBuilder.swift
//  MyEmail
//
//  Builds NSApp.mainMenu programmatically. Menu actions dispatch through
//  the responder chain (target == nil) to reach the key window's controller.
//  Keyboard shortcuts follow DESIGN.md §7.2; Forward is remapped to ⌥⌘F
//  because ⇧⌘F is reserved for Global Search.
//

import AppKit

@MainActor
final class MainMenuBuilder {
    private unowned let delegate: AppDelegate

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    func install() {
        let main = NSMenu()
        main.addItem(buildAppMenu())
        main.addItem(buildFileMenu())
        main.addItem(buildEditMenu())
        main.addItem(buildViewMenu())
        main.addItem(buildMessageMenu())
        main.addItem(buildWindowMenu())
        main.addItem(buildHelpMenu())
        NSApp.mainMenu = main
    }

    // MARK: - App menu

    private func buildAppMenu() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        let item = NSMenuItem()
        let menu = NSMenu(title: appName)

        menu.addItem(withTitle: String(localized: "About MyEmail"),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = delegate
        menu.addItem(settings)

        menu.addItem(.separator())

        let services = NSMenuItem(
            title: String(localized: "Services"),
            action: nil, keyEquivalent: ""
        )
        let servicesMenu = NSMenu(title: "Services")
        NSApp.servicesMenu = servicesMenu
        services.submenu = servicesMenu
        menu.addItem(services)

        menu.addItem(.separator())

        menu.addItem(withTitle: String(localized: "Hide MyEmail"),
                    action: #selector(NSApplication.hide(_:)),
                    keyEquivalent: "h")

        let hideOthers = NSMenuItem(
            title: String(localized: "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)

        menu.addItem(withTitle: String(localized: "Show All"),
                    action: #selector(NSApplication.unhideAllApplications(_:)),
                    keyEquivalent: "")

        menu.addItem(.separator())

        menu.addItem(withTitle: String(localized: "Quit MyEmail"),
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: - File menu

    private func buildFileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "File"))

        menu.addItem(makeItem(
            title: String(localized: "New Message"),
            selector: #selector(MainWindowController.newMessage(_:)),
            key: "n"
        ))

        menu.addItem(makeItem(
            title: String(localized: "Open Message in New Window"),
            selector: #selector(MainWindowController.openSelectedMessageInNewWindow(_:)),
            key: "o"
        ))

        menu.addItem(.separator())

        menu.addItem(withTitle: String(localized: "Close Window"),
                    action: #selector(NSWindow.performClose(_:)),
                    keyEquivalent: "w")

        menu.addItem(.separator())

        let getMail = makeItem(
            title: String(localized: "Get New Mail"),
            selector: #selector(MainWindowController.getMail(_:)),
            key: "n"
        )
        getMail.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(getMail)

        item.submenu = menu
        return item
    }

    // MARK: - Edit menu

    private func buildEditMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "Edit"))

        menu.addItem(withTitle: String(localized: "Undo"),
                    action: Selector(("undo:")),
                    keyEquivalent: "z")
        let redo = NSMenuItem(title: String(localized: "Redo"),
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())

        menu.addItem(withTitle: String(localized: "Cut"),
                    action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: String(localized: "Copy"),
                    action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: String(localized: "Paste"),
                    action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: String(localized: "Select All"),
                    action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: String(localized: "Find…"),
            selector: #selector(MainWindowController.findInCurrentFolder(_:)),
            key: "f"
        ))

        let globalSearch = makeItem(
            title: String(localized: "Global Search…"),
            selector: #selector(MainWindowController.globalSearch(_:)),
            key: "f"
        )
        globalSearch.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(globalSearch)

        item.submenu = menu
        return item
    }

    // MARK: - View menu

    private func buildViewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "View"))

        let toggleSidebar = NSMenuItem(
            title: String(localized: "Toggle Sidebar"),
            action: Selector(("toggleSidebar:")),
            keyEquivalent: "s"
        )
        toggleSidebar.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(toggleSidebar)

        menu.addItem(.separator())

        let layout = NSMenuItem(title: String(localized: "Layout"),
                                action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: String(localized: "Layout"))

        let wide = NSMenuItem(
            title: String(localized: "Wide"),
            action: #selector(AppDelegate.setLayoutWide(_:)),
            keyEquivalent: ""
        )
        wide.target = delegate
        layoutMenu.addItem(wide)

        let classic = NSMenuItem(
            title: String(localized: "Classic"),
            action: #selector(AppDelegate.setLayoutClassic(_:)),
            keyEquivalent: ""
        )
        classic.target = delegate
        layoutMenu.addItem(classic)

        layout.submenu = layoutMenu
        menu.addItem(layout)

        let toggleThreading = makeItem(
            title: String(localized: "Toggle Threading"),
            selector: #selector(MainWindowController.toggleThreading(_:)),
            key: "t"
        )
        toggleThreading.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(toggleThreading)

        menu.addItem(.separator())

        let toggleDebug = NSMenuItem(
            title: String(localized: "Toggle Debug Log Panel"),
            action: #selector(AppDelegate.toggleDebugLog(_:)),
            keyEquivalent: "y"
        )
        toggleDebug.keyEquivalentModifierMask = [.command, .option]
        toggleDebug.target = delegate
        menu.addItem(toggleDebug)

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: String(localized: "Customize Toolbar…"),
            selector: #selector(MainWindowController.customizeToolbar(_:)),
            key: ""
        ))

        item.submenu = menu
        return item
    }

    // MARK: - Message menu

    private func buildMessageMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "Message"))

        menu.addItem(makeItem(
            title: String(localized: "Reply"),
            selector: #selector(MainWindowController.replyToMessage(_:)),
            key: "r"
        ))

        let replyAll = makeItem(
            title: String(localized: "Reply All"),
            selector: #selector(MainWindowController.replyAllToMessage(_:)),
            key: "r"
        )
        replyAll.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(replyAll)

        // Forward = ⌥⌘F (⇧⌘F reserved for Global Search)
        let forward = makeItem(
            title: String(localized: "Forward"),
            selector: #selector(MainWindowController.forwardMessage(_:)),
            key: "f"
        )
        forward.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(forward)

        menu.addItem(.separator())

        let archive = makeItem(
            title: String(localized: "Archive"),
            selector: #selector(MainWindowController.archiveMessage(_:)),
            key: "a"
        )
        archive.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(archive)

        menu.addItem(makeItem(
            title: String(localized: "Delete"),
            selector: #selector(MainWindowController.deleteMessage(_:)),
            key: String(Character(UnicodeScalar(NSBackspaceCharacter)!))
        ))

        let markRead = makeItem(
            title: String(localized: "Mark Read/Unread"),
            selector: #selector(MainWindowController.toggleReadState(_:)),
            key: "u"
        )
        markRead.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(markRead)

        let flag = makeItem(
            title: String(localized: "Flag"),
            selector: #selector(MainWindowController.toggleFlag(_:)),
            key: "l"
        )
        flag.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(flag)

        menu.addItem(makeItem(
            title: String(localized: "Mark as Junk"),
            selector: #selector(MainWindowController.markAsJunk(_:)),
            key: "j"
        ))

        item.submenu = menu
        return item
    }

    // MARK: - Window menu

    private func buildWindowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "Window"))

        menu.addItem(withTitle: String(localized: "Minimize"),
                    action: #selector(NSWindow.performMiniaturize(_:)),
                    keyEquivalent: "m")
        menu.addItem(withTitle: String(localized: "Zoom"),
                    action: #selector(NSWindow.performZoom(_:)),
                    keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Bring All to Front"),
                    action: #selector(NSApplication.arrangeInFront(_:)),
                    keyEquivalent: "")

        NSApp.windowsMenu = menu
        item.submenu = menu
        return item
    }

    // MARK: - Help menu

    private func buildHelpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "Help"))

        menu.addItem(withTitle: String(localized: "MyEmail Help"),
                    action: #selector(NSApplication.showHelp(_:)),
                    keyEquivalent: "?")

        NSApp.helpMenu = menu
        item.submenu = menu
        return item
    }

    // MARK: - Helpers

    /// Creates a responder-chain menu item (target == nil). AppKit walks the
    /// chain from the key window's firstResponder up to our window controller.
    private func makeItem(title: String, selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = nil
        return item
    }
}
