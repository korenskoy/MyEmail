//
//  WideLayoutView.swift
//  MyEmail
//
//  Wide layout: NavigationSplitView (sidebar | message list | reading pane).
//  Default layout per DESIGN.md §4.1.
//

import SwiftUI

struct WideLayoutView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView()
        } content: {
            MessageListTable(
                items: appState.isSearchActive
                    ? appState.searchResults
                    : appState.messageItems,
                folderID: appState.selectedFolder?.id,
                selectedMessageIDs: $appState.selectedMessageIDs,
                showAccountColumn: appState.isUnifiedInbox
                    || appState.searchScope == .allAccounts,
                isSentOrDrafts: appState.selectedFolder?.isSentOrDrafts ?? false
            )
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 500)
        } detail: {
            if let msgID = appState.selectedMessageID {
                MessageDetailView(messageID: msgID)
            } else {
                EmptyStateView(
                    icon: "envelope",
                    message: String(localized: "Select a message")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .animation(.none, value: appState.selectedFolder?.id)
    }
}
