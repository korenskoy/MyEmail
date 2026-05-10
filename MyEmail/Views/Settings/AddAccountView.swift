//
//  AddAccountView.swift
//  MyEmail
//
//  Sheet-корень для добавления аккаунта. Три шага:
//    1. Chooser: Gmail / Generic IMAP
//    2a. Gmail: кнопка "Sign in with Google" → OAuth flow → finish
//    2b. Generic: form с IMAP/SMTP настройками → save → finish
//

import SwiftUI

// MARK: - Flow state

private enum AddAccountStep: Equatable {
    case chooseProvider
    case gmail
    case generic
}

// MARK: - Root sheet

struct AddAccountView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var step: AddAccountStep = .chooseProvider

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .chooseProvider:
                ProviderChooserView(
                    onChooseGmail: { step = .gmail },
                    onChooseGeneric: { step = .generic },
                    onCancel: { dismiss() }
                )
            case .gmail:
                AddGmailAccountView(
                    onBack: { step = .chooseProvider },
                    onFinished: { dismiss() }
                )
            case .generic:
                AddGenericAccountView(
                    onBack: { step = .chooseProvider },
                    onFinished: { dismiss() }
                )
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}

// MARK: - Provider chooser

struct ProviderChooserView: View {
    let onChooseGmail: () -> Void
    let onChooseGeneric: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Add account")
                .font(.title2.weight(.semibold))
                .padding(.top, 16)

            Text("Choose an account type")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ProviderRow(
                    icon: "envelope.circle.fill",
                    title: "Gmail",
                    subtitle: "Sign in with Google (OAuth)",
                    action: onChooseGmail
                )
                ProviderRow(
                    icon: "at.circle.fill",
                    title: "Other IMAP Server",
                    subtitle: "Host, port, username and password",
                    action: onChooseGeneric
                )
            }
            .padding(.horizontal, 24)

            Spacer()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.escape)
            }
            .padding(16)
        }
    }
}

private struct ProviderRow: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
