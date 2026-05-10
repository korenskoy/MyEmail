//
//  SearchBarView.swift
//  MyEmail
//
//  Search bar with scope picker. Triggers local FTS5 + server IMAP SEARCH.
//  ⌘F activates, Esc clears.
//

import SwiftUI

struct SearchBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppEnvironment.self) private var env
    @FocusState private var isFocused: Bool
    @State private var debounceTask: Task<Void, Never>?
    @State private var showHelp = false
    @State private var recent: [String] = []

    var body: some View {
        @Bindable var appState = appState

        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search…", text: $appState.searchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { submitSearch() }
                .onChange(of: appState.searchText) {
                    if appState.searchText.isEmpty {
                        clearSearch()
                    } else {
                        debouncedSearch()
                    }
                }
                .onExitCommand { clearSearch() }
                .onChange(of: appState.focusSearchField) {
                    if appState.focusSearchField {
                        isFocused = true
                        appState.focusSearchField = false
                    }
                }

            // Always in layout — opacity controls visibility (sacred rule #9)
            Picker("", selection: $appState.searchScope) {
                Text("Folder").tag(SearchScope.currentFolder)
                Text("Account").tag(SearchScope.currentAccount)
                Text("All").tag(SearchScope.allAccounts)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .opacity(appState.isSearchActive ? 1 : 0)
            .disabled(!appState.isSearchActive)
            .onChange(of: appState.searchScope) { triggerSearch() }

            // Result count badge (hidden when empty/loading to avoid jitter).
            Text(resultCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .opacity(appState.isSearchActive && !appState.isSearching ? 1 : 0)
                .frame(minWidth: 60, alignment: .trailing)

            Button(action: clearSearch) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(appState.isSearchActive ? 1 : 0)
            .disabled(!appState.isSearchActive)

            // Recent searches menu — always visible when history has entries.
            Menu {
                if recent.isEmpty {
                    Text("No recent searches")
                } else {
                    ForEach(recent, id: \.self) { entry in
                        Button(entry) {
                            appState.searchText = entry
                            triggerSearch()
                        }
                    }
                    Divider()
                    Button("Clear recent searches") {
                        RecentSearchesStore.shared.clear()
                        recent = []
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Recent searches")

            Button(action: { showHelp = true }) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Show search help")

            ProgressView()
                .controlSize(.small)
                .opacity(appState.isSearching ? 1 : 0)
        }
        .background(scopeShortcuts)
        .sheet(isPresented: $showHelp) {
            SearchHelpView()
        }
        .onAppear { recent = RecentSearchesStore.shared.load() }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Derived

    /// Invisible shortcut buttons so ⌘⇧1/2/3 switches scope only while the
    /// search field is in use. Using ⇧ to avoid colliding with any future
    /// ⌘1/2/3 tab semantics.
    @ViewBuilder
    private var scopeShortcuts: some View {
        Group {
            Button("") { appState.searchScope = .currentFolder; triggerSearch() }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button("") { appState.searchScope = .currentAccount; triggerSearch() }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            Button("") { appState.searchScope = .allAccounts; triggerSearch() }
                .keyboardShortcut("3", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .disabled(!appState.isSearchActive)
    }

    private var resultCountLabel: String {
        let n = appState.searchResults.count
        if n == 0 { return String(localized: "No results") }
        return String(localized: "Found: \(n)")
    }

    // MARK: - Actions

    /// Called from Enter key — persists the raw query to recent history and
    /// runs a search immediately. Debounced path does NOT persist (avoids
    /// every partial keystroke landing in recents).
    private func submitSearch() {
        let trimmed = appState.searchText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            RecentSearchesStore.shared.save(trimmed)
            recent = RecentSearchesStore.shared.load()
        }
        triggerSearch()
    }

    /// Debounce 300ms — avoids search on every keystroke.
    private func debouncedSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            triggerSearch()
        }
    }

    private func triggerSearch() {
        let text = appState.searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { clearSearch(); return }

        let query = SearchQueryParser.parse(text)
        guard !query.isEmpty else { return }

        // Cancel previous server search
        appState.serverSearchTask?.cancel()
        appState.isSearching = true

        let scope = appState.searchScope
        let folderID = appState.selectedFolder?.id
        let accountID = appState.selectedFolder?.accountID

        appState.serverSearchTask = Task {
            defer { appState.isSearching = false }

            // Local FTS5 search
            do {
                let localResults = try await env.syncService.searchLocal(
                    query: query, scope: scope,
                    folderID: folderID, accountID: accountID
                )
                appState.searchResults = localResults
            } catch {
                LogService.log(.error, .search, "Local search failed", detail: "\(error)")
            }

            // Server-side IMAP SEARCH (parallel per account in scope)
            guard !Task.isCancelled else { return }

            do {
                let accounts = accountsForScope(scope, accountID: accountID)
                let folders = foldersForScope(scope, folderID: folderID)

                // Parallel per-account server search via TaskGroup
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for account in accounts {
                        let accountFolders = folders.filter { $0.accountID == account.id }
                        group.addTask {
                            for folder in accountFolders {
                                guard !Task.isCancelled else { return }
                                let serverUIDs = try await env.syncService.searchOnServer(
                                    query: query, account: account, folderPath: folder.path
                                )
                                if !serverUIDs.isEmpty {
                                    try await env.syncService.hydrateSearchResults(
                                        uids: serverUIDs, folderID: folder.id,
                                        folderPath: folder.path, account: account
                                    )
                                }
                            }
                        }
                    }
                    try await group.waitForAll()
                }

                // Re-run local search to pick up hydrated results
                guard !Task.isCancelled else { return }
                let updated = try await env.syncService.searchLocal(
                    query: query, scope: scope,
                    folderID: folderID, accountID: accountID
                )
                appState.searchResults = updated
            } catch {
                if !Task.isCancelled {
                    LogService.log(.error, .search, "Server search failed", detail: "\(error)")
                }
            }
        }
    }

    private func clearSearch() {
        debounceTask?.cancel()
        debounceTask = nil
        appState.serverSearchTask?.cancel()
        appState.serverSearchTask = nil
        appState.searchText = ""
        appState.searchResults = []
        appState.isSearching = false
    }

    // MARK: - Scope helpers

    private func accountsForScope(_ scope: SearchScope, accountID: UUID?) -> [Account] {
        switch scope {
        case .currentFolder, .currentAccount:
            guard let aid = accountID else { return [] }
            return appState.accounts.filter { $0.id == aid }
        case .allAccounts:
            return appState.accounts
        }
    }

    private func foldersForScope(_ scope: SearchScope, folderID: UUID?) -> [Folder] {
        switch scope {
        case .currentFolder:
            guard let fid = folderID else { return [] }
            return appState.folders.filter { $0.id == fid }
        case .currentAccount, .allAccounts:
            return appState.folders
        }
    }
}
