//
//  AddGenericAccountView.swift
//  MyEmail
//
//  Шаг 2b в Add Account flow: плoш form с IMAP/SMTP параметрами.
//  Test Connection в M2 — stub (пишет в LogService, не коннектится).
//  Real IMAP test — M5.
//

import SwiftUI

struct AddGenericAccountView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppState.self) private var appState
    let onBack: () -> Void
    let onFinished: () -> Void

    @State private var form = GenericAccountForm()
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    AccountFormGeneralSection(form: $form)
                    Divider()
                    AccountFormIMAPSection(form: $form)
                    Divider()
                    AccountFormSMTPSection(form: $form)
                }
                .padding(16)
            }
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                onBack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
            }
            .buttonStyle(.borderless)
            .disabled(isSaving)

            Spacer()

            Text("Other IMAP Server")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Spacer()

            Button("Test Connection") {
                testConnection()
            }
            .disabled(isSaving || !form.isValid)

            Button("Save") {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || !form.isValid)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func testConnection() {
        // M2 stub: real IMAP connect — в M5.
        LogService.shared.log(
            .info,
            .auth,
            "Test Connection stub (M5 will implement real IMAP)",
            detail: "host=\(form.imapHost):\(form.imapPort) security=\(form.imapSecurity.rawValue)"
        )
        errorMessage = nil
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let draft = form.toDraft()
            let account = try await env.authService.addGenericAccount(draft: draft)

            // Push new account into live AppState so the main window exits
            // empty-state immediately — otherwise nothing renders until
            // next app launch.
            appState.accounts = (try? env.accountRepository.all()) ?? []
            appState.rebuildAccountLookup()
            appState.observeFolders()
            if let inbox = await env.syncService.syncAccount(account) {
                appState.selectedSidebarItem = .folder(inbox.id)
            }

            onFinished()
        } catch AuthError.accountAlreadyExists(let email) {
            errorMessage = "Account \(email) is already added."
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

// MARK: - Form state

struct GenericAccountForm {
    /// Label shown in sidebar / account picker (e.g. "Personal", "Work").
    /// Defaults to email if user leaves empty.
    var accountName: String = ""
    /// Sender name used in outgoing "From" header (RFC 5322 display-name).
    var name: String = ""
    var email: String = ""
    var password: String = ""

    var imapHost: String = ""
    var imapPort: Int = 993
    var imapSecurity: ConnectionSecurity = .ssl

    var smtpHost: String = ""
    var smtpPort: Int = 587
    var smtpSecurity: ConnectionSecurity = .starttls

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && email.contains("@")
        && !password.isEmpty
        && !imapHost.isEmpty
        && !smtpHost.isEmpty
        && imapPort > 0
        && smtpPort > 0
    }

    func toDraft() -> GenericAccountDraft {
        let label = accountName.trimmingCharacters(in: .whitespaces)
        return GenericAccountDraft(
            accountName: label.isEmpty ? email : label,
            name: name,
            email: email,
            password: password,
            imapHost: imapHost,
            imapPort: imapPort,
            imapSecurity: imapSecurity,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpSecurity: smtpSecurity
        )
    }
}

// MARK: - Default ports per ConnectionSecurity

enum DefaultPorts {
    static func imap(for security: ConnectionSecurity) -> Int {
        switch security {
        case .ssl: return 993
        case .starttls, .none: return 143
        }
    }

    static func smtp(for security: ConnectionSecurity) -> Int {
        switch security {
        case .ssl: return 465
        case .starttls: return 587
        case .none: return 25
        }
    }

    static let allIMAP: Set<Int> = [993, 143]
    static let allSMTP: Set<Int> = [465, 587, 25]
}

// MARK: - Sections

struct AccountFormGeneralSection: View {
    @Binding var form: GenericAccountForm

    var body: some View {
        Section {
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Account name")
                    TextField("Personal, Work, …", text: $form.accountName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Display name")
                    TextField("Your name", text: $form.name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Email")
                    TextField("user@example.com", text: $form.email)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Password")
                    SecureField("Password", text: $form.password)
                        .textFieldStyle(.roundedBorder)
                }
            }
        } header: {
            Text("General")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct AccountFormIMAPSection: View {
    @Binding var form: GenericAccountForm

    var body: some View {
        Section {
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Server")
                    TextField("imap.example.com", text: $form.imapHost)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Port")
                    TextField(
                        "993",
                        value: $form.imapPort,
                        format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100, alignment: .leading)
                }
                GridRow {
                    Text("Security")
                    Picker("", selection: $form.imapSecurity) {
                        Text("SSL/TLS").tag(ConnectionSecurity.ssl)
                        Text("STARTTLS").tag(ConnectionSecurity.starttls)
                        Text("None").tag(ConnectionSecurity.none)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: form.imapSecurity) { _, newSecurity in
                        // Auto-update port only when current value matches a
                        // known default — preserves user's custom port choice.
                        if DefaultPorts.allIMAP.contains(form.imapPort) {
                            form.imapPort = DefaultPorts.imap(for: newSecurity)
                        }
                    }
                }
            }
        } header: {
            Text("IMAP (incoming)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct AccountFormSMTPSection: View {
    @Binding var form: GenericAccountForm

    var body: some View {
        Section {
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Server")
                    TextField("smtp.example.com", text: $form.smtpHost)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Port")
                    TextField(
                        "587",
                        value: $form.smtpPort,
                        format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100, alignment: .leading)
                }
                GridRow {
                    Text("Security")
                    Picker("", selection: $form.smtpSecurity) {
                        Text("SSL/TLS").tag(ConnectionSecurity.ssl)
                        Text("STARTTLS").tag(ConnectionSecurity.starttls)
                        Text("None").tag(ConnectionSecurity.none)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: form.smtpSecurity) { _, newSecurity in
                        if DefaultPorts.allSMTP.contains(form.smtpPort) {
                            form.smtpPort = DefaultPorts.smtp(for: newSecurity)
                        }
                    }
                }
            }
        } header: {
            Text("SMTP (outgoing)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
