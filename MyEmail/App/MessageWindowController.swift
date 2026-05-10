//
//  MessageWindowController.swift
//  MyEmail
//
//  AppKit-owned standalone "read message" window. One controller per
//  messageID — re-front if already open.
//

import AppKit
import SwiftUI

@MainActor
final class MessageWindowController: NSWindowController, NSWindowDelegate {
    let messageID: UUID
    private let appState: AppState
    private let environment: AppEnvironment
    private let onClose: (UUID) -> Void

    init(
        messageID: UUID,
        appState: AppState,
        environment: AppEnvironment,
        onClose: @escaping (UUID) -> Void
    ) {
        self.messageID = messageID
        self.appState = appState
        self.environment = environment
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Message")
        window.minSize = NSSize(width: 500, height: 400)
        window.setFrameAutosaveName(
            "MyEmailMessageWindow-\(messageID.uuidString.prefix(8))"
        )

        let rootView = MessageDetailView(messageID: messageID)
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

    func windowWillClose(_ notification: Notification) {
        onClose(messageID)
    }

    // MARK: - @objc actions (responder chain)

    @objc func replyToMessage(_ sender: Any?) {
        guard let accID = accountID(for: messageID) else { return }
        (NSApp.delegate as? AppDelegate)?
            .openCompose(mode: .reply(messageID: messageID, accountID: accID))
    }

    @objc func replyAllToMessage(_ sender: Any?) {
        guard let accID = accountID(for: messageID) else { return }
        (NSApp.delegate as? AppDelegate)?
            .openCompose(mode: .replyAll(messageID: messageID, accountID: accID))
    }

    @objc func forwardMessage(_ sender: Any?) {
        guard let accID = accountID(for: messageID) else { return }
        (NSApp.delegate as? AppDelegate)?
            .openCompose(mode: .forward(messageID: messageID, accountID: accID))
    }

    @objc func archiveMessage(_ sender: Any?) {
        let um = window?.undoManager
        Task { [messageID, environment] in
            await environment.undoService.archiveMessages([messageID], undoManager: um)
        }
    }

    @objc func deleteMessage(_ sender: Any?) {
        let um = window?.undoManager
        Task { [messageID, environment] in
            await environment.undoService.deleteMessages([messageID], undoManager: um)
        }
    }

    @objc func toggleReadState(_ sender: Any?) {
        let um = window?.undoManager
        let isRead = appState.messageItems.first { $0.id == messageID }?.isRead ?? false
        Task { [messageID, environment] in
            if isRead {
                await environment.undoService.markAsUnread([messageID], undoManager: um)
            } else {
                await environment.undoService.markAsRead([messageID], undoManager: um)
            }
        }
    }

    @objc func toggleFlag(_ sender: Any?) {
        let um = window?.undoManager
        let isFlagged = appState.messageItems.first { $0.id == messageID }?.isFlagged ?? false
        Task { [messageID, environment] in
            await environment.undoService.setFlagged(
                [messageID], flagged: !isFlagged, undoManager: um
            )
        }
    }

    @objc func markAsJunk(_ sender: Any?) {
        Task { [messageID, environment] in
            await environment.syncService.markAsJunk([messageID])
        }
    }

    // MARK: - Helpers

    private func accountID(for id: UUID) -> UUID? {
        appState.messageItems.first { $0.id == id }?.accountID
    }
}

// MARK: - NSUserInterfaceValidations

extension MessageWindowController: NSUserInterfaceValidations {
    nonisolated func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        return true
    }
}
