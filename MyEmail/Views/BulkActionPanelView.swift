//
//  BulkActionPanelView.swift
//  MyEmail
//
//  Shown in the reading pane when 2+ messages are selected.
//  Displays selection count and bulk action buttons.
//

import SwiftUI

struct BulkActionPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppEnvironment.self) private var env
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "envelope.stack")
                    .font(.system(size: 40, weight: .ultraLight))
                    .foregroundStyle(.secondary)

                Text(selectionLabel(appState.selectedMessageIDs.count))
                    .font(.title3.weight(.medium))
            }

            HStack(spacing: 20) {
                BulkButton(icon: "archivebox", label: String(localized: "Archive")) {
                    perform { ids in
                        await env.undoService.archiveMessages(ids, undoManager: undoManager)
                    }
                }
                BulkButton(icon: "trash", label: String(localized: "Delete"), isDestructive: true) {
                    perform { ids in
                        await env.undoService.deleteMessages(ids, undoManager: undoManager)
                    }
                }
                BulkButton(icon: "exclamationmark.octagon", label: String(localized: "Mark as Spam"), isDestructive: true) {
                    perform { ids in
                        await env.syncService.markAsJunk(ids)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // Russian plural: 1 → письмо, 2–4 → письма, 5+ → писем (with 11–19 exception)
    private nonisolated func selectionLabel(_ n: Int) -> String {
        let isRu = Locale.current.language.languageCode?.identifier == "ru"
        if isRu {
            let rem10 = n % 10
            let rem100 = n % 100
            let noun: String
            if rem10 == 1 && rem100 != 11 {
                noun = "письмо выбрано"
            } else if rem10 >= 2 && rem10 <= 4 && (rem100 < 10 || rem100 >= 20) {
                noun = "письма выбрано"
            } else {
                noun = "писем выбрано"
            }
            return "\(n) \(noun)"
        }
        return n == 1
            ? "1 message selected"
            : "\(n) messages selected"
    }

    private func perform(op: @escaping ([UUID]) async -> Void) {
        let ids = Array(appState.selectedMessageIDs)
        appState.selectedMessageIDs = []
        Task { await op(ids) }
    }
}

private struct BulkButton: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.caption)
            }
            .frame(width: 80)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isDestructive ? Color.red : Color.primary)
    }
}
