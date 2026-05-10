//
//  ComposeHeaderFields.swift
//  MyEmail
//
//  Header field grid (From/To/Cc/Bcc/Reply-To/Subject) and the recipient
//  text field with inline autocomplete. Extracted from ComposeView to
//  keep that file under the 500-line structural limit.
//

import SwiftUI

// MARK: - Header fields

struct ComposeHeaderFields: View {
    let accounts: [Account]
    @Binding var selectedAccountID: UUID
    @Binding var to: String
    @Binding var cc: String
    @Binding var bcc: String
    @Binding var replyTo: String
    @Binding var subject: String
    @Binding var showExtraFields: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("From:").foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                fromPicker
            }
            GridRow {
                Text("To:").foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                HStack(spacing: 4) {
                    RecipientTextField(text: $to, placeholder: "Recipients")
                    Button {
                        showExtraFields.toggle()
                    } label: {
                        Image(systemName: showExtraFields ? "minus.circle" : "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(showExtraFields ? "Hide Cc/Bcc" : "Show Cc/Bcc")
                }
            }

            if showExtraFields {
                GridRow {
                    Text("Cc:").foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                    RecipientTextField(text: $cc, placeholder: "Cc")
                }
                GridRow {
                    Text("Bcc:").foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                    RecipientTextField(text: $bcc, placeholder: "Bcc")
                }
                GridRow {
                    Text("Reply-To:").foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                    TextField("Reply-To", text: $replyTo)
                        .textFieldStyle(.roundedBorder)
                }
            }

            GridRow {
                Text("Subject:").foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                TextField("Subject", text: $subject)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
    }

    // MARK: - From picker

    @ViewBuilder
    private var fromPicker: some View {
        let enabled = accounts.filter(\.isEnabled)
        if enabled.count <= 1 {
            Text(displayName(for: enabled.first))
                .foregroundStyle(.primary)
        } else {
            Picker("", selection: $selectedAccountID) {
                ForEach(enabled) { account in
                    Text(displayName(for: account)).tag(account.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func displayName(for account: Account?) -> String {
        guard let account else { return "—" }
        let sender = account.senderName ?? account.name
        if sender == account.email {
            return account.email
        }
        return "\(sender) <\(account.email)>"
    }
}

// MARK: - Recipient field with autocomplete

struct RecipientTextField: View {
    @Binding var text: String
    let placeholder: String

    @State private var suggestions: [RecipientSuggestion] = []
    @State private var showSuggestions = false

    /// The portion of text after the last comma — used for autocomplete query.
    private var currentToken: String {
        let parts = text.components(separatedBy: ",")
        return parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { _, _ in updateSuggestions() }

            if showSuggestions {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            commitSuggestion(suggestion)
                        } label: {
                            HStack(spacing: 6) {
                                if let name = suggestion.name {
                                    Text(name).font(.caption).lineLimit(1)
                                }
                                Text(suggestion.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
        }
    }

    private func updateSuggestions() {
        let token = currentToken
        guard token.count >= 2 else {
            suggestions = []
            showSuggestions = false
            return
        }
        suggestions = ContactsService.shared.suggestions(for: token, limit: 8)
        showSuggestions = !suggestions.isEmpty
    }

    private func commitSuggestion(_ suggestion: RecipientSuggestion) {
        var parts = text.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(suggestion.email)
        text = parts.joined(separator: ", ") + ", "
        suggestions = []
        showSuggestions = false
    }
}
