//
//  RuleSettingsView.swift
//  MyEmail
//
//  CRUD for mail rules with conditions and actions.
//

import SwiftUI
import GRDB

struct RuleSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var rules: [MailRule] = []
    @State private var accounts: [Account] = []
    @State private var folders: [Folder] = []
    @State private var selectedID: UUID?

    private var pool: DatabasePool { DatabaseService.shared.pool }

    var body: some View {
        HStack(spacing: 0) {
            // Rule list — fixed width, no competing split
            VStack(spacing: 0) {
                List(rules, selection: $selectedID) { rule in
                    HStack {
                        Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(rule.isEnabled ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                                .font(.callout)
                            Text(accountLabel(for: rule.accountID))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(rule.id)
                }
                Divider()
                AddRemoveToolbar(
                    canRemove: selectedID != nil,
                    onAdd: addRule,
                    onRemove: removeSelected
                )
            }
            .frame(width: 240)

            Divider()

            // Stable right pane regardless of selection (rule #9).
            ZStack {
                if let idx = rules.firstIndex(where: { $0.id == selectedID }) {
                    RuleDetailPane(
                        rule: $rules[idx],
                        accounts: accounts,
                        folders: foldersForRule(rules[idx]),
                        onSave: { save(rules[idx]) },
                        onApply: { applyToInbox(rules[idx]) }
                    )
                } else {
                    Text("Select a rule")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { load() }
    }

    private func load() {
        rules = (try? pool.read { db in
            try MailRule.order(Column("sort_order")).fetchAll(db)
        }) ?? []
        accounts = (try? pool.read { db in
            try Account.order(Column("sort_order")).fetchAll(db)
        }) ?? []
        folders = (try? pool.read { db in
            try Folder.order(Column("account_id"), Column("path")).fetchAll(db)
        }) ?? []
    }

    private func accountLabel(for id: UUID?) -> String {
        guard let id else { return "—" }
        return accounts.first { $0.id == id }?.email ?? ""
    }

    private func foldersForRule(_ rule: MailRule) -> [Folder] {
        guard let accountID = rule.accountID else { return [] }
        return folders.filter { $0.accountID == accountID }
    }

    private func addRule() {
        guard let firstAccount = accounts.first else { return }
        var rule = MailRule.makeEmpty()
        rule.accountID = firstAccount.id
        try? pool.write { db in try rule.insert(db) }
        rules.append(rule)
        selectedID = rule.id
    }

    private func removeSelected() {
        guard let id = selectedID else { return }
        try? pool.write { db in
            try MailRule.filter(Column("id") == id).deleteAll(db)
        }
        rules.removeAll { $0.id == id }
        selectedID = rules.first?.id
    }

    private func save(_ rule: MailRule) {
        try? pool.write { db in try rule.update(db) }
    }

    /// "Apply now" button: run just this rule across its scope (or all inbox
    /// folders if scope is empty). Uses matches() directly so it runs even if
    /// the user unchecked "Allow manual runs" — this IS a manual run from UI
    /// but scoped to a single rule for convenience.
    private func applyToInbox(_ rule: MailRule) {
        guard let accountID = rule.accountID else { return }
        Task {
            let targetFolders: [Folder] = {
                if rule.folderPaths.isEmpty {
                    return folders.filter {
                        $0.accountID == accountID && $0.specialUse == .inbox
                    }
                } else {
                    return folders.filter {
                        $0.accountID == accountID && rule.folderPaths.contains($0.path)
                    }
                }
            }()

            let engine = RuleEngine()
            var applied = 0
            for folder in targetFolders {
                let items: [MessageListItem] = (try? await pool.read { db in
                    let sql = MessageListItem.listSQL + " WHERE m.folder_id = ?"
                    return try MessageListItem.fetchAll(db, sql: sql, arguments: [folder.id])
                }) ?? []

                for item in items {
                    if engine.matches(rule: rule, item: item, bodyText: nil) {
                        await env.syncService.executeRuleActions(
                            rule.actions, for: item, accountID: accountID
                        )
                        applied += 1
                    }
                }
            }
            LogService.log(.info, .rules, "Applied rule \"\(rule.name)\" to \(applied) messages")
        }
    }
}

// MARK: - Rule detail pane

private struct RuleDetailPane: View {
    @Binding var rule: MailRule
    let accounts: [Account]
    let folders: [Folder]
    let onSave: () -> Void
    let onApply: () -> Void

    @State private var isDirty = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ruleHeaderSection
                triggersSection
                scopeSection
                conditionsSection
                actionsSection
            }
            .formStyle(.grouped)
            .onChange(of: rule) { isDirty = true }

            Divider()
            footerBar
        }
    }

    @ViewBuilder private var ruleHeaderSection: some View {
        TextField("Name", text: $rule.name)
        Toggle("Enabled", isOn: $rule.isEnabled)
        Picker("Account", selection: $rule.accountID) {
            ForEach(accounts) { account in
                Text(account.email).tag(Optional(account.id))
            }
        }
        Picker("Match", selection: $rule.matchAll) {
            Text("All conditions (AND)").tag(true)
            Text("Any condition (OR)").tag(false)
        }
    }

    @ViewBuilder private var triggersSection: some View {
        Section(String(localized: "Triggers")) {
            Toggle(String(localized: "Apply to incoming mail"), isOn: $rule.runOnIncoming)
            Toggle(String(localized: "Allow manual runs"), isOn: $rule.runOnManual)
        }
    }

    /// Folder scope: empty set = legacy "all inbox folders" behavior; otherwise
    /// the rule only fires for the listed folder paths (matches TB filter scope).
    @ViewBuilder private var scopeSection: some View {
        Section(String(localized: "Apply to folders")) {
            MultiSelectFolderField(folders: folders, scope: $rule.folderPaths)
                .disabled(folders.isEmpty)
        }
    }

    @ViewBuilder private var conditionsSection: some View {
        Section("Conditions") {
            ForEach(rule.conditions.indices, id: \.self) { i in
                HStack {
                    ConditionRow(condition: $rule.conditions[i])
                    Button {
                        rule.conditions.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add Condition") {
                rule.conditions.append(
                    RuleCondition(field: .from, predicate: .contains, value: "")
                )
            }
        }
    }

    @ViewBuilder private var actionsSection: some View {
        Section("Actions") {
            ForEach(rule.actions.indices, id: \.self) { i in
                HStack {
                    ActionRow(action: $rule.actions[i], folders: folders)
                    Button {
                        rule.actions.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add Action") {
                rule.actions.append(RuleAction(type: .markRead, value: nil))
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button("Apply to Inbox") { onApply() }
            Spacer()
            Button("Save") { onSave(); isDirty = false }
                .keyboardShortcut(.defaultAction)
                .disabled(!isDirty)
        }
        .padding(12)
    }
}

// MARK: - Condition row

private struct ConditionRow: View {
    @Binding var condition: RuleCondition

    var body: some View {
        HStack {
            Picker("Field", selection: $condition.field) {
                ForEach(RuleCondition.RuleField.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .labelsHidden()
            .frame(width: 100)

            Picker("Predicate", selection: $condition.predicate) {
                ForEach(RuleCondition.RulePredicate.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            TextField("Value", text: $condition.value)
        }
    }
}

// MARK: - Action row

private struct ActionRow: View {
    @Binding var action: RuleAction
    let folders: [Folder]

    private struct FlatEntry {
        let folder: Folder
        let depth: Int
    }

    private var flattenedFolders: [FlatEntry] {
        let tree = FolderTreeBuilder.build(from: folders)
        var result: [FlatEntry] = []
        func walk(_ nodes: [FolderNode], depth: Int) {
            for node in nodes {
                result.append(FlatEntry(folder: node.folder, depth: depth))
                if let children = node.children {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(tree, depth: 0)
        return result
    }

    var body: some View {
        HStack {
            Picker("Action", selection: $action.type) {
                ForEach(RuleAction.RuleActionType.allCases, id: \.self) { t in
                    Text(t.label).tag(t)
                }
            }
            .labelsHidden()
            .frame(width: 180)

            if action.type == .moveToFolder {
                Picker("Folder", selection: Binding(
                    get: { action.value ?? "" },
                    set: { action.value = $0 }
                )) {
                    Text("—").tag("")
                    ForEach(flattenedFolders, id: \.folder.id) { entry in
                        Text(String(repeating: "    ", count: entry.depth) + entry.folder.displayName)
                            .tag(entry.folder.path)
                    }
                }
                .labelsHidden()
            } else if action.type == .rewriteSubject {
                TextField("Pattern (regex)", text: Binding(
                    get: { action.value ?? "" },
                    set: { action.value = $0 }
                ))
                TextField("Replacement", text: Binding(
                    get: { action.replacement ?? "" },
                    set: { action.replacement = $0.isEmpty ? nil : $0 }
                ))
            }
        }
    }
}


