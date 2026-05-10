//
//  SignatureSettingsView.swift
//  MyEmail
//
//  CRUD for email signatures per account.
//

import SwiftUI
import GRDB

struct SignatureSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var signatures: [Signature] = []
    @State private var accounts: [Account] = []
    @State private var selectedID: UUID?

    private var pool: DatabasePool { DatabaseService.shared.pool }

    var body: some View {
        HStack(spacing: 0) {
            // Signature list
            VStack(spacing: 0) {
                List(signatures, selection: $selectedID) { sig in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sig.name)
                            .font(.callout)
                        Text(accountName(for: sig.accountID))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(sig.id)
                }
                Divider()
                AddRemoveToolbar(
                    canRemove: selectedID != nil,
                    onAdd: addSignature,
                    onRemove: removeSelected
                )
            }
            .frame(width: 240)

            Divider()

            // Stable right pane regardless of selection (rule #9).
            ZStack {
                if let idx = signatures.firstIndex(where: { $0.id == selectedID }) {
                    SignatureDetailPane(
                        signature: $signatures[idx],
                        accounts: accounts,
                        onSave: { save(signatures[idx]) }
                    )
                } else {
                    Text("Select a signature")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { load() }
    }

    private func load() {
        signatures = (try? pool.read { db in
            try Signature.order(Column("account_id"), Column("name")).fetchAll(db)
        }) ?? []
        accounts = (try? pool.read { db in
            try Account.order(Column("sort_order")).fetchAll(db)
        }) ?? []
    }

    private func addSignature() {
        guard let account = accounts.first else { return }
        var sig = Signature(
            id: UUID(), accountID: account.id,
            name: "New Signature", body: "",
            isHTML: false, isDefault: signatures.isEmpty
        )
        try? pool.write { db in try sig.insert(db) }
        signatures.append(sig)
        selectedID = sig.id
    }

    private func removeSelected() {
        guard let id = selectedID else { return }
        try? pool.write { db in
            try Signature.filter(Column("id") == id).deleteAll(db)
        }
        signatures.removeAll { $0.id == id }
        selectedID = signatures.first?.id
    }

    private func save(_ signature: Signature) {
        try? pool.write { db in try signature.update(db) }
    }

    private func accountName(for id: UUID) -> String {
        accounts.first { $0.id == id }?.name ?? ""
    }
}

// MARK: - Detail pane

private struct SignatureDetailPane: View {
    @Binding var signature: Signature
    let accounts: [Account]
    let onSave: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $signature.name)
                .onChange(of: signature.name) { onSave() }

            Picker("Account", selection: $signature.accountID) {
                ForEach(accounts) { account in
                    Text(account.email).tag(account.id)
                }
            }
            .onChange(of: signature.accountID) { onSave() }

            Toggle("Default signature", isOn: $signature.isDefault)
                .onChange(of: signature.isDefault) { onSave() }

            Section("Body") {
                TextEditor(text: $signature.body)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .onChange(of: signature.body) { onSave() }
            }
        }
        .formStyle(.grouped)
    }
}
