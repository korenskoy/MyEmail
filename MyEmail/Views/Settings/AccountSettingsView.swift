//
//  AccountSettingsView.swift
//  MyEmail
//
//  Tab в Settings window: список аккаунтов + Add/Remove. В M2 — минимум для
//  DOD: видно список, кнопка Add открывает sheet с Gmail/Generic flow,
//  кнопка Remove удаляет row + Keychain entries.
//
//  M3+ добавит: edit fields, Test Connection button (real IMAP), Reconnect
//  для `.needsReauth`, Enable/Disable toggle.
//

import SwiftUI
import GRDB

struct AccountSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppState.self) private var appState
    @State private var accounts: [Account] = []
    @State private var folders: [Folder] = []
    @State private var selectedAccountID: Account.ID?
    @State private var isShowingAddSheet = false
    @State private var loadError: String?

    private var selectedAccount: Binding<Account?> {
        Binding(
            get: {
                guard let id = selectedAccountID else { return nil }
                return accounts.first { $0.id == id }
            },
            set: { _ in }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                AccountListPane(
                    accounts: accounts,
                    selectedAccountID: $selectedAccountID,
                    onMove: moveAccounts
                )
                Divider()
                AddRemoveToolbar(
                    canRemove: selectedAccountID != nil,
                    onAdd: { isShowingAddSheet = true },
                    onRemove: removeSelected
                )
            }
            .frame(width: 240)

            Divider()

            // Stable right pane regardless of selection (rule #9).
            ZStack {
                if let account = selectedAccount.wrappedValue {
                    AccountDetailPane(
                        account: account,
                        folders: folders.filter { $0.accountID == account.id },
                        onSave: saveAccount
                    )
                    .id(account.id)
                } else {
                    Text("Select an account")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await reload()
        }
        .sheet(isPresented: $isShowingAddSheet, onDismiss: {
            Task { await reload() }
        }) {
            AddAccountView()
        }
        .alert(
            "Accounts error",
            isPresented: Binding(
                get: { loadError != nil },
                set: { if !$0 { loadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { loadError = nil }
        } message: {
            if let loadError {
                Text(loadError)
            }
        }
    }

    // MARK: - Actions

    private func reload() async {
        do {
            let fetched = try env.accountRepository.all()
            self.accounts = fetched
            self.folders = (try? await DatabaseService.shared.pool.read { db in
                try Folder.order(Column("account_id"), Column("path")).fetchAll(db)
            }) ?? []
        } catch {
            LogService.log(
                .error,
                .auth,
                "Failed to load accounts",
                detail: String(describing: error)
            )
            self.loadError = String(describing: error)
        }
    }

    private func removeSelected() {
        guard let id = selectedAccountID else { return }
        do {
            try env.accountRepository.delete(id: id)
            self.selectedAccountID = nil

            // Clear stale main-window selection if it was pointing at this
            // account's folder — otherwise the ValueObservation update and the
            // stale folder ID race and message list keeps rendering ghosts.
            if case .folder(let folderID) = appState.selectedSidebarItem,
               let folder = appState.folders.first(where: { $0.id == folderID }),
               folder.accountID == id {
                appState.selectedSidebarItem = nil
                appState.selectedMessageIDs = []
            }

            Task {
                await env.syncService.removeAccount(id: id)
                // Mirror into live AppState so main window reacts immediately
                // (empty-state / toolbar visibility depend on accounts.isEmpty).
                appState.accounts = (try? env.accountRepository.all()) ?? []
                appState.rebuildAccountLookup()
                appState.observeFolders()
                await reload()
            }
        } catch {
            self.loadError = String(describing: error)
        }
    }

    private func saveAccount(_ updated: Account) {
        do {
            try env.accountRepository.update(updated)
            if let idx = accounts.firstIndex(where: { $0.id == updated.id }) {
                accounts[idx] = updated
            }
        } catch {
            self.loadError = String(describing: error)
        }
    }

    private func moveAccounts(from source: IndexSet, to destination: Int) {
        var reordered = accounts
        reordered.move(fromOffsets: source, toOffset: destination)
        accounts = reordered
        do {
            try env.accountRepository.reorder(reordered.map(\.id))
            // Mirror into live AppState so sidebar reflects the new order
            // synchronously — ValueObservation will reconfirm shortly after.
            appState.accounts = (try? env.accountRepository.all()) ?? appState.accounts
            appState.rebuildAccountLookup()
        } catch {
            self.loadError = String(describing: error)
            Task { await reload() }
        }
    }
}

// MARK: - List pane

struct AccountListPane: View {
    let accounts: [Account]
    @Binding var selectedAccountID: Account.ID?
    let onMove: (IndexSet, Int) -> Void

    var body: some View {
        List(selection: $selectedAccountID) {
            ForEach(accounts) { account in
                AccountListRow(account: account)
                    .tag(account.id)
            }
            .onMove(perform: onMove)
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 40)
    }
}

private struct AccountListRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(account.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if account.authState == .needsReauth {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(Text("Needs re-authentication"))
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch account.authType {
        case .oauth2: return "envelope.circle.fill"
        case .plain:  return "at.circle.fill"
        }
    }
}

// MARK: - Account detail pane

struct AccountDetailPane: View {
    let account: Account
    let folders: [Folder]
    let onSave: (Account) -> Void

    @State private var accountName: String = ""
    @State private var senderName: String = ""
    @State private var sentPath: String = ""
    @State private var draftsPath: String = ""
    @State private var trashPath: String = ""
    @State private var junkPath: String = ""
    @State private var archivePath: String = ""
    @State private var archiveSubdivision: ArchiveSubdivision = .byMonthThunderbird
    @State private var isSaved = false

    private var isGmail: Bool { account.authType == .oauth2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                identitySection
                serverSection
                specialFoldersSection
                archiveSection
            }
            .formStyle(.grouped)

            Spacer()
            footerBar
        }
        .onAppear {
            accountName = account.name
            senderName = account.senderName ?? account.name
            sentPath = account.sentFolderPath ?? ""
            draftsPath = account.draftsFolderPath ?? ""
            trashPath = account.trashFolderPath ?? ""
            junkPath = account.junkFolderPath ?? ""
            archivePath = account.archiveRootPath ?? ""
            archiveSubdivision = account.archiveSubdivision
        }
    }

    @ViewBuilder private var identitySection: some View {
        Section("Identity") {
            TextField(String(localized: "Account name"), text: $accountName)
                .textFieldStyle(.roundedBorder)
            TextField(String(localized: "Sender name"), text: $senderName)
                .textFieldStyle(.roundedBorder)
            LabeledContent("Email") {
                Text(account.email).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var serverSection: some View {
        Section("Server") {
            LabeledContent("IMAP") {
                Text("\(account.imapHost):\(account.imapPort)").foregroundStyle(.secondary)
            }
            LabeledContent("SMTP") {
                Text("\(account.smtpHost):\(account.smtpPort)").foregroundStyle(.secondary)
            }
            LabeledContent("Auth") {
                Text(account.authType == .oauth2 ? "OAuth 2.0" : "Password").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var specialFoldersSection: some View {
        Section("Special Folders") {
            folderPicker("Sent", selection: $sentPath)
            folderPicker("Drafts", selection: $draftsPath)
            folderPicker("Trash", selection: $trashPath)
            folderPicker("Junk", selection: $junkPath)
        }
    }

    @ViewBuilder private var archiveSection: some View {
        Section("Archive") {
            if isGmail {
                Text("Gmail uses label removal for archiving — messages stay in All Mail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            folderPicker("Archive folder", selection: $archivePath)
            if !isGmail {
                Picker("Folder structure", selection: $archiveSubdivision) {
                    Text("Flat (Archive/)").tag(ArchiveSubdivision.flat)
                    Text("By year (Archive/2026/)").tag(ArchiveSubdivision.byYear)
                    Text("By month (Archive/2026/2026-04/)").tag(ArchiveSubdivision.byMonthThunderbird)
                }
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Text(String(localized: "Saved"))
                .font(.caption)
                .foregroundStyle(.green)
                .opacity(isSaved ? 1 : 0)
            Spacer()
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(accountName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    @ViewBuilder
    private func folderPicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            Text("Auto-detect").tag("")
            ForEach(folderEntries, id: \.path) { entry in
                Text(entry.displayPath).tag(entry.path)
            }
        }
    }

    private struct FolderPickEntry {
        let path: String
        let displayPath: String
        let depth: Int
    }

    private var folderEntries: [FolderPickEntry] {
        flatten(FolderTreeBuilder.build(from: folders), depth: 0, prefix: "")
    }

    private func flatten(_ nodes: [FolderNode], depth: Int, prefix: String) -> [FolderPickEntry] {
        var out: [FolderPickEntry] = []
        for node in nodes {
            let name = node.folder.displayName
            let full = prefix.isEmpty ? name : "\(prefix) › \(name)"
            out.append(FolderPickEntry(path: node.folder.path, displayPath: full, depth: depth))
            if let kids = node.children {
                out.append(contentsOf: flatten(kids, depth: depth + 1, prefix: full))
            }
        }
        return out
    }

    private func save() {
        var updated = account
        updated.name = accountName.trimmingCharacters(in: .whitespaces)
        let trimmedSender = senderName.trimmingCharacters(in: .whitespaces)
        updated.senderName = trimmedSender.isEmpty ? nil : trimmedSender
        updated.sentFolderPath = sentPath.isEmpty ? nil : sentPath
        updated.draftsFolderPath = draftsPath.isEmpty ? nil : draftsPath
        updated.trashFolderPath = trashPath.isEmpty ? nil : trashPath
        updated.junkFolderPath = junkPath.isEmpty ? nil : junkPath
        updated.archiveRootPath = archivePath.isEmpty ? nil : archivePath
        updated.archiveSubdivision = isGmail ? .flat : archiveSubdivision
        onSave(updated)
        isSaved = true
        Task { try? await Task.sleep(for: .seconds(2)); isSaved = false }
    }
}

// MARK: - Toolbar

// MARK: - Shared +/- toolbar for master-detail settings panes

struct AddRemoveToolbar: View {
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)

            Button(action: onRemove) {
                Image(systemName: "minus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
