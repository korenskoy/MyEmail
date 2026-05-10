//
//  PrivacySettingsView.swift
//  MyEmail
//
//  Privacy settings: remote content, Gravatar, trusted senders.
//

import SwiftUI
import SwiftMail

struct PrivacySettingsView: View {
    @AppStorage("blockRemoteContent") private var blockRemoteContent = true
    @AppStorage("enableGravatar") private var enableGravatar = false
    @State private var trustedSenders: [TrustedSender] = []
    @State private var newSenderEmail = ""

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section("Remote Content") {
                Toggle("Block remote images by default", isOn: $blockRemoteContent)
                Text("Remote images can be loaded per-message via the banner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gravatar") {
                Toggle("Show Gravatar avatars", isOn: $enableGravatar)
                Text("Sender email hashes are sent to gravatar.com to fetch avatars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Trusted Senders") {
                Text("Remote content is always loaded for trusted senders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List {
                    ForEach(trustedSenders) { sender in
                        HStack {
                            Text(EmailAddress.emailOnly(from: sender.email))
                            Spacer()
                            Button {
                                removeSender(sender)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 80)

                HStack {
                    TextField("Add email", text: $newSenderEmail)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { addSender() }
                        .disabled(newSenderEmail.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { loadSenders() }
    }

    private func loadSenders() {
        trustedSenders = env.trustedSenderService.allTrusted()
    }

    private func addSender() {
        let email = EmailAddress.emailOnly(
            from: newSenderEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        ).lowercased()
        guard !email.isEmpty else { return }
        env.trustedSenderService.addTrusted(email)
        trustedSenders = env.trustedSenderService.allTrusted()
        newSenderEmail = ""
    }

    private func removeSender(_ sender: TrustedSender) {
        env.trustedSenderService.removeTrusted(sender.id)
        trustedSenders.removeAll { $0.id == sender.id }
    }
}
