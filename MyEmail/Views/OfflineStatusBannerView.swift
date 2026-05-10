//
//  OfflineStatusBannerView.swift
//  MyEmail
//
//  Floating overlay banner: offline / syncing / failed.
//  Overlaid on content — never shifts layout (sacred rule #9).
//

import SwiftUI

struct OfflineStatusBannerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let sync = env.syncService
        let queue = env.offlineQueue

        if !sync.isOnline {
            banner(
                icon: "wifi.slash",
                text: String(localized: "Offline — \(queue.pendingCount) pending"),
                color: .red
            )
            .transition(.opacity)
        } else if sync.isSyncing {
            banner(
                icon: "arrow.triangle.2.circlepath",
                text: String(localized: "Syncing…"),
                color: .orange
            )
            .transition(.opacity)
        } else if queue.failedCount > 0 {
            Menu {
                Button {
                    Task {
                        await queue.retryFailed()
                        await env.syncService.drainOfflineQueueIfNeeded()
                    }
                } label: {
                    Label(String(localized: "Retry failed actions"), systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    Task { await queue.discardFailed() }
                } label: {
                    Label(String(localized: "Discard failed actions"), systemImage: "trash")
                }
            } label: {
                bannerContent(
                    icon: "exclamationmark.triangle",
                    text: String(localized: "\(queue.failedCount) failed actions"),
                    color: .orange
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help(String(localized: "Click to retry or discard failed actions"))
            .transition(.opacity)
        }
    }

    private func banner(icon: String, text: String, color: Color) -> some View {
        bannerContent(icon: icon, text: text, color: color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(.bar)
            .animation(.easeInOut(duration: 0.25), value: text)
    }

    private func bannerContent(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(.bar)
        .contentShape(Rectangle())
    }
}
