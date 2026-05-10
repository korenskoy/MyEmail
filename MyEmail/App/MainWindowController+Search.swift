//
//  MainWindowController+Search.swift
//  MyEmail
//
//  Search debounce + server/local dispatch for the main window search field.
//  Copied from the former ToolbarInstaller; lives on MainWindowController
//  because it mutates AppState and owns the debounce task.
//

import AppKit
import Foundation

extension MainWindowController {

    func handleSearchTextChanged(_ text: String) {
        appState.searchText = text
        if text.isEmpty {
            clearSearch()
        } else {
            debouncedSearch()
        }
    }

    // MARK: - Search pipeline

    private func debouncedSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.triggerSearch()
        }
    }

    private func triggerSearch() {
        let text = appState.searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { clearSearch(); return }

        let query = SearchQueryParser.parse(text)
        guard !query.isEmpty else { return }

        appState.serverSearchTask?.cancel()
        appState.isSearching = true

        let scope = appState.searchScope
        let folderID = appState.selectedFolder?.id
        let accountID = appState.selectedFolder?.accountID
        let appState = self.appState
        let env = self.environment

        appState.serverSearchTask = Task {
            defer { appState.isSearching = false }

            do {
                let localResults = try await env.syncService.searchLocal(
                    query: query, scope: scope,
                    folderID: folderID, accountID: accountID
                )
                appState.searchResults = localResults
            } catch {
                LogService.log(.error, .search, "Local search failed", detail: "\(error)")
            }

            guard !Task.isCancelled else { return }

            do {
                let accounts = Self.accountsForScope(
                    scope, accountID: accountID, appState: appState
                )
                let folders = Self.foldersForScope(
                    scope, folderID: folderID, appState: appState
                )

                try await withThrowingTaskGroup(of: Void.self) { group in
                    for account in accounts {
                        let accountFolders = folders.filter { $0.accountID == account.id }
                        group.addTask {
                            for folder in accountFolders {
                                guard !Task.isCancelled else { return }
                                let serverUIDs = try await env.syncService.searchOnServer(
                                    query: query, account: account,
                                    folderPath: folder.path
                                )
                                if !serverUIDs.isEmpty {
                                    try await env.syncService.hydrateSearchResults(
                                        uids: serverUIDs,
                                        folderID: folder.id,
                                        folderPath: folder.path,
                                        account: account
                                    )
                                }
                            }
                        }
                    }
                    try await group.waitForAll()
                }

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
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        appState.serverSearchTask?.cancel()
        appState.serverSearchTask = nil
        appState.searchText = ""
        appState.searchResults = []
        appState.isSearching = false
    }

    // MARK: - Scope helpers

    private static func accountsForScope(
        _ scope: SearchScope, accountID: UUID?, appState: AppState
    ) -> [Account] {
        switch scope {
        case .currentFolder, .currentAccount:
            guard let aid = accountID else { return [] }
            return appState.accounts.filter { $0.id == aid }
        case .allAccounts:
            return appState.accounts
        }
    }

    private static func foldersForScope(
        _ scope: SearchScope, folderID: UUID?, appState: AppState
    ) -> [Folder] {
        switch scope {
        case .currentFolder:
            guard let fid = folderID else { return [] }
            return appState.folders.filter { $0.id == fid }
        case .currentAccount, .allAccounts:
            return appState.folders
        }
    }
}
