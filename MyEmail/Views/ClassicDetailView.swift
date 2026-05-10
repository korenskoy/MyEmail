//
//  ClassicDetailView.swift
//  MyEmail
//
//  Classic layout detail: VSplitView(message list, reading pane).
//  Split position persisted via @AppStorage.
//

import SwiftUI

struct ClassicDetailView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("classicSplitRatio") private var splitRatio: Double = 0.4

    var body: some View {
        @Bindable var appState = appState

        GeometryReader { geo in
            let totalHeight = geo.size.height
            let listHeight = max(100, totalHeight * splitRatio)
            let detailHeight = max(100, totalHeight - listHeight - 4)

            VStack(spacing: 0) {
                    MessageListTable(
                        items: appState.isSearchActive
                            ? appState.searchResults
                            : appState.messageItems,
                        folderID: appState.selectedFolder?.id,
                        selectedMessageIDs: $appState.selectedMessageIDs,
                        showAccountColumn: appState.isUnifiedInbox || appState.searchScope == .allAccounts,
                        isSentOrDrafts: appState.selectedFolder?.isSentOrDrafts ?? false
                    )
                    .frame(height: listHeight)

                    SplitHandleView(
                        listHeight: listHeight,
                        totalHeight: totalHeight,
                        ratio: $splitRatio
                    )

                    Group {
                        if appState.selectedMessageIDs.count > 1 {
                            BulkActionPanelView()
                        } else if let msgID = appState.selectedMessageID {
                            MessageDetailView(messageID: msgID)
                        } else {
                            EmptyStateView(
                                icon: "envelope",
                                message: String(localized: "Select a message")
                            )
                        }
                    }
                    .frame(height: detailHeight)
                }
            .transaction { $0.animation = nil }
        }
    }
}

// MARK: - Resizable split handle

private struct SplitHandleView: View {
    let listHeight: CGFloat
    let totalHeight: CGFloat
    @Binding var ratio: Double

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .overlay {
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newRatio = (listHeight + value.translation.height) / totalHeight
                                ratio = max(0.15, min(0.85, newRatio))
                            }
                    )
            }
    }
}
