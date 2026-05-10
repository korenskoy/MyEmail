//
//  AddGmailAccountView.swift
//  MyEmail
//
//  Шаг 2a в Add Account flow: кнопка «Войти через Google» → OAuth →
//  аккаунт в GRDB + tokens в Keychain.
//
//  UX principle (hard rule "No flicker, no jump"): фиксированная высота у
//  message-зоны и у кнопочной строки. Состояние меняет ТЕКСТ кнопки и
//  прогресс-индикатор внутри неё, а не подменяет всю HStack на другую.
//

import SwiftUI

struct AddGmailAccountView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppState.self) private var appState
    let onBack: () -> Void
    let onFinished: () -> Void

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var successEmail: String?

    var body: some View {
        VStack(spacing: 16) {
            headerBar

            Spacer(minLength: 8)

            Image(systemName: "envelope.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Sign in with Google")
                .font(.title3.weight(.semibold))

            Text("You will be asked to authorize MyEmail to read and send mail for your Gmail account. MyEmail never requests access to your contacts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            messageStrip

            Spacer(minLength: 8)

            actionBar
        }
    }

    // MARK: - Header

    private var headerBar: some View {
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
            .disabled(isWorking)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Message strip (reserved height — no layout jumps)

    private var messageStrip: some View {
        Group {
            if let successEmail {
                Label(successEmail, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            } else {
                // Invisible placeholder so the frame height is stable.
                Text(" ")
                    .font(.caption)
            }
        }
        .frame(minHeight: 32)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack {
            Spacer()
            if successEmail == nil {
                signInButton
            } else {
                Button("Done") {
                    onFinished()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(16)
    }

    private var signInButton: some View {
        Button {
            Task { await startOAuth() }
        } label: {
            // HStack с фиксированными слотами: progress всегда присутствует,
            // меняет только opacity → нет реflow'а.
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .opacity(isWorking ? 1 : 0)
                Image(systemName: "person.badge.key")
                Text(isWorking ? "Waiting for browser…" : "Sign in with Google")
            }
            .frame(minWidth: 220)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(isWorking)
    }

    // MARK: - Actions

    private func startOAuth() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let account = try await env.authService.addGmailAccount()
            successEmail = account.email

            // Trigger sync immediately
            appState.accounts = (try? env.accountRepository.all()) ?? []
            appState.rebuildAccountLookup()
            appState.observeFolders()
            if let inbox = await env.syncService.syncAccount(account) {
                appState.selectedSidebarItem = .folder(inbox.id)
            }
        } catch AuthError.userCancelled {
            errorMessage = "Sign in was cancelled."
        } catch AuthError.secretsMissing {
            errorMessage = "OAuth client not configured. Fill Secrets.swift with Google client ID and redirect URI."
        } catch AuthError.accountAlreadyExists(let email) {
            errorMessage = "Account \(email) is already added."
        } catch AuthError.stateMismatch {
            errorMessage = "Security check failed (state mismatch). Try again."
        } catch AuthError.tokenExchangeFailed(let reason) {
            errorMessage = "Token exchange failed: \(reason)"
        } catch AuthError.userInfoFetchFailed(let reason) {
            errorMessage = "Could not load profile: \(reason)"
        } catch AuthError.invalidCallback(let detail) {
            errorMessage = "Invalid OAuth callback: \(detail)"
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
