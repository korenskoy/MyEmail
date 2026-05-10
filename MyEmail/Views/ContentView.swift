//
//  ContentView.swift
//  MyEmail
//
//  Classic layout (MailMate-style): sidebar | VSplitView(list, detail).
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppEnvironment.self) private var env
    @AppStorage("windowLayout") private var layout: String = "wide"

    var body: some View {
        Group {
            if appState.accounts.isEmpty {
                emptyState
            } else if layout == "classic" {
                HSplitView {
                    SidebarView()
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 350)
                    ClassicDetailView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(alignment: .top) { banners }
            } else {
                WideLayoutView()
                    .overlay(alignment: .top) { banners }
            }
        }
        .transaction { $0.animation = nil }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await initialSync() }
        .task { wireNotificationNavigation() }
        .onChange(of: appState.selectedSidebarItem) { _, newItem in
            guard case .folder(let folderID) = newItem else {
                env.syncService.currentlySelectedFolderID = nil
                return
            }
            // Track current selection so prefetch scope-gate can match it.
            env.syncService.currentlySelectedFolderID = folderID
            Task {
                await env.syncService.syncFolderIfNeeded(folderID: folderID)
                await env.syncService.ensureIDLEForSelected(folderID: folderID)
            }
            // Body prefetch: warm cache for the newly-opened folder.
            // Cancels any previous folder's in-flight prefetch (replace: true default).
            env.syncService.schedulePrefetch(folderID: folderID)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
            Text("MyEmail")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            Text("Add an account in Settings (⌘,)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                (NSApp.delegate as? AppDelegate)?.showSettings(nil)
            } label: {
                Text("Open Settings")
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
        }
    }

    private var banners: some View {
        ErrorBannerView()
            .padding(.top, 1)
    }

    private func wireNotificationNavigation() {
        NotificationService.shared.onNotificationClick = { accountID, folderID, messageUID in
            appState.selectedSidebarItem = .folder(folderID)
            Task {
                let msgID = await env.syncService.messageID(uid: messageUID, folderID: folderID)
                if let msgID { appState.selectedMessageIDs = [msgID] }
            }
        }
    }

    private func initialSync() async {
        do {
            appState.accounts = try env.accountRepository.all()
            appState.rebuildAccountLookup()
        } catch {
            LogService.log(.error, .sync, "Failed to load accounts", detail: "\(error)")
            return
        }

        guard !appState.accounts.isEmpty else { return }

        appState.observeFolders()
        appState.observeAccounts()

        if appState.selectedSidebarItem == nil,
           let inbox = appState.folders.first(where: { $0.specialUse == .inbox }) {
            appState.selectedSidebarItem = .folder(inbox.id)
        }

        for account in appState.accounts {
            await env.syncService.syncAccount(account)
        }
        await env.syncService.updateDockBadge()
    }
}
