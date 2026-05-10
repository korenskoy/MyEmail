//
//  SidebarView.swift
//  MyEmail
//
//  Sidebar with Unified Inbox + per-account folder trees.
//  List (OK for sidebar per anti-req: "List — только sidebar").
//

import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppEnvironment.self) private var env
    @AppStorage("showUnifiedInbox") private var showUnifiedInbox = true
    @State private var cachedTrees: [(account: Account, tree: [FolderNode])] = []
    @State private var folderToEmpty: Folder?
    @State private var collapsedFolderIDs: Set<UUID> = SidebarView.loadCollapsedIDs()
    @State private var collapsedAccountIDs: Set<UUID> = SidebarView.loadCollapsedAccountIDs()

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedSidebarItem) {
            if showUnifiedInbox {
                HStack {
                    Label("Unified Inbox", systemImage: "tray.fill")
                    Spacer()
                    if unifiedUnreadCount > 0 {
                        UnreadBadge(count: unifiedUnreadCount)
                    }
                }
                .tag(SidebarItem.unifiedInbox)
            }

            ForEach(cachedTrees, id: \.account.id) { entry in
                Section(isExpanded: accountExpandedBinding(for: entry.account.id)) {
                    folderNodes(entry.tree)
                } header: {
                    Text(entry.account.name)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OfflineStatusBannerView()
        }
        .onAppear { rebuildTrees() }
        .onChange(of: appState.folders) { _, _ in rebuildTrees() }
        .onChange(of: appState.accounts) { _, _ in rebuildTrees() }
        .alert(
            String(localized: "Permanently delete all messages?"),
            isPresented: Binding(
                get: { folderToEmpty != nil },
                set: { if !$0 { folderToEmpty = nil } }
            )
        ) {
            Button(String(localized: "Cancel"), role: .cancel) { folderToEmpty = nil }
            Button(String(localized: "Empty"), role: .destructive) {
                if let folder = folderToEmpty {
                    Task { await env.syncService.emptyFolder(folderID: folder.id) }
                }
                folderToEmpty = nil
            }
        } message: {
            if let folder = folderToEmpty {
                Text("All messages in \"\(folder.localizedName)\" will be permanently deleted. This cannot be undone.")
            }
        }
    }

    // MARK: - Recursive folder tree with persistent expand/collapse

    @ViewBuilder
    private func folderNodes(_ nodes: [FolderNode]) -> some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: expandedBinding(for: node.folder.id)) {
                    AnyView(folderNodes(children))
                } label: {
                    folderRow(node.folder)
                }
            } else {
                folderRow(node.folder)
            }
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: Folder) -> some View {
        FolderRowView(folder: folder)
            .tag(SidebarItem.folder(folder.id))
            .contextMenu { folderContextMenu(folder) }
            .dropDestination(for: String.self) { items, _ in
                let ids = items.compactMap { UUID(uuidString: $0) }
                guard !ids.isEmpty else { return false }
                Task { await env.syncService.moveMessages(ids, to: folder.id) }
                return true
            }
    }

    private func accountExpandedBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedAccountIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedAccountIDs.remove(id)
                } else {
                    collapsedAccountIDs.insert(id)
                }
                Self.saveCollapsedAccountIDs(collapsedAccountIDs)
            }
        )
    }

    private func expandedBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolderIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedFolderIDs.remove(id)
                } else {
                    collapsedFolderIDs.insert(id)
                }
                Self.saveCollapsedIDs(collapsedFolderIDs)
            }
        )
    }

    // MARK: - Persistence

    private static let collapsedKey = "sidebarCollapsedFolderIDs"

    private static func loadCollapsedIDs() -> Set<UUID> {
        guard let strings = UserDefaults.standard.stringArray(forKey: collapsedKey) else {
            return []
        }
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }

    private static func saveCollapsedIDs(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: collapsedKey)
    }

    private static let collapsedAccountKey = "sidebarCollapsedAccountIDs"

    private static func loadCollapsedAccountIDs() -> Set<UUID> {
        guard let strings = UserDefaults.standard.stringArray(forKey: collapsedAccountKey) else {
            return []
        }
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }

    private static func saveCollapsedAccountIDs(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: collapsedAccountKey)
    }

    // MARK: - Tree building

    private func rebuildTrees() {
        cachedTrees = appState.accounts.map { account in
            let folders = appState.folders
                .filter { $0.accountID == account.id }
            return (account, FolderTreeBuilder.build(from: folders))
        }
    }

    private var unifiedUnreadCount: Int {
        appState.folders
            .filter { $0.specialUse == .inbox }
            .reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: - Context menu (DESIGN.md §4.3)

    @ViewBuilder
    private func folderContextMenu(_ folder: Folder) -> some View {
        Button(String(localized: "Mark All Read")) {
            Task { await env.syncService.markAllReadWithSync(folderID: folder.id) }
        }

        switch emptyFolderRole(folder) {
        case .trash:
            Button(String(localized: "Empty Trash"), role: .destructive) {
                folderToEmpty = folder
            }
        case .junk:
            Button(String(localized: "Empty Junk"), role: .destructive) {
                folderToEmpty = folder
            }
        case .none:
            EmptyView()
        }

        Divider()

        Button(String(localized: "New Subfolder…")) {
            promptNewSubfolder(parent: folder)
        }

        if folder.specialUse == nil {
            Button(String(localized: "Rename…")) {
                promptRenameFolder(folder)
            }
            Button(String(localized: "Delete"), role: .destructive) {
                Task { await env.syncService.deleteFolder(folderID: folder.id) }
            }
        }

        Divider()

        Button(String(localized: "Run filters on folder")) {
            Task {
                await env.syncService.runRulesManually(
                    in: folder.id,
                    accountID: folder.accountID,
                    messageIDs: nil
                )
            }
        }

        Divider()

        Button(String(localized: "Resync Folder")) {
            Task { await env.syncService.forceResyncFolder(folderID: folder.id) }
        }
    }

    private enum EmptyRole { case trash, junk }

    /// Check if folder is Trash/Junk by specialUse OR account settings.
    private func emptyFolderRole(_ folder: Folder) -> EmptyRole? {
        if folder.specialUse == .trash { return .trash }
        if folder.specialUse == .junk { return .junk }
        guard let account = appState.accounts.first(where: { $0.id == folder.accountID }) else {
            return nil
        }
        if account.trashFolderPath == folder.path { return .trash }
        if account.junkFolderPath == folder.path { return .junk }
        return nil
    }

    /// Shared NSAlert text input prompt.
    private func promptTextInput(
        title: String, info: String, confirmTitle: String, defaultValue: String = ""
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: String(localized: "Cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultValue
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = input.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func promptNewSubfolder(parent: Folder) {
        guard let account = appState.accounts.first(where: { $0.id == parent.accountID }) else { return }
        guard let name = promptTextInput(
            title: String(localized: "New Subfolder"),
            info: String(localized: "Enter folder name:"),
            confirmTitle: String(localized: "Create")
        ) else { return }
        Task { await env.syncService.createSubfolder(name: name, parentPath: parent.path, account: account) }
    }

    private func promptRenameFolder(_ folder: Folder) {
        guard let newName = promptTextInput(
            title: String(localized: "Rename Folder"),
            info: String(localized: "Enter new name:"),
            confirmTitle: String(localized: "Rename"),
            defaultValue: folder.displayName
        ), newName != folder.displayName else { return }
        Task { await env.syncService.renameFolder(folderID: folder.id, newName: newName) }
    }
}

// MARK: - FolderRowView

struct FolderRowView: View {
    let folder: Folder

    var body: some View {
        HStack {
            Label {
                Text(folder.localizedName)
            } icon: {
                Image(systemName: iconName)
            }
            Spacer()
            if folder.unreadCount > 0 {
                UnreadBadge(
                    count: folder.unreadCount,
                    muted: folder.specialUse == .junk || folder.specialUse == .trash
                )
            }
        }
    }

    private var iconName: String {
        switch folder.specialUse {
        case .inbox:   return "tray"
        case .sent:    return "paperplane"
        case .drafts:  return "doc"
        case .trash:   return "trash"
        case .junk:    return "xmark.bin"
        case .archive: return "archivebox"
        case .all:     return "tray.2"
        case nil:      return "folder"
        }
    }
}

// MARK: - Filled unread badge (MailMate-style)

struct UnreadBadge: View {
    let count: Int
    var muted: Bool = false

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(muted ? Color.secondary : Color.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(muted ? Color.secondary.opacity(0.2) : Color.accentColor, in: Capsule())
    }
}
