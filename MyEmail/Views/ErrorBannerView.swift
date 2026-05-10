//
//  ErrorBannerView.swift
//  MyEmail
//
//  Dismissable error banners. Auto-dismiss after 8 seconds.
//  Re-auth errors show a persistent banner with a reconnect button.
//

import SwiftUI

struct ErrorBannerView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 4) {
            // Re-auth banners (persistent, one per account)
            ForEach(accountsNeedingReauth) { account in
                ReauthBanner(account: account) {
                    Task { try? await env.authService.refreshViaOAuth(
                        accountID: account.id, email: account.email
                    ) }
                }
            }

            // Transient error banners
            ForEach(appState.errors) { error in
                TransientErrorBanner(error: error) {
                    appState.errors.removeAll { $0.id == error.id }
                }
            }
        }
    }

    private var accountsNeedingReauth: [Account] {
        appState.accounts.filter { $0.authState == .needsReauth }
    }
}

// MARK: - Re-auth banner

private struct ReauthBanner: View {
    let account: Account
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text("\(account.email) — authentication expired")
                .font(.callout)
                .foregroundStyle(.white)
            Spacer()
            Button("Reconnect") { onReconnect() }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange)
    }
}

// MARK: - Transient error banner

private struct TransientErrorBanner: View {
    let error: AppError
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(error.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                if let detail = error.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.85))
        .task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}
