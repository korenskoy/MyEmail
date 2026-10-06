//
//  UnsubscribeButton.swift
//  MyEmail
//
//  List-Unsubscribe action in MessageHeaderBar, gated by a confirmation dialog.
//

import SwiftUI

struct UnsubscribeButton: View {
    let method: UnsubscribeMethod
    let sender: String
    let accountID: UUID

    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var isConfirming = false
    @State private var isWorking = false
    @State private var isDone = false
    @State private var errorText: String?

    var body: some View {
        Button { isConfirming = true } label: {
            Image(systemName: isDone ? "checkmark" : "bell.slash")
                .font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .disabled(isWorking || isDone)
        .help(isDone ? String(localized: "Unsubscribed") : String(localized: "Unsubscribe"))
        .confirmationDialog(
            String(localized: "Unsubscribe from \(sender)?"),
            isPresented: $isConfirming
        ) {
            Button(String(localized: "Unsubscribe")) { Task { await perform() } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(explanation)
        }
        .alert(
            String(localized: "Unsubscribe failed"),
            isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
        ) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var explanation: String {
        switch method {
        case .oneClick:
            String(localized: "An unsubscribe request will be sent to \(method.target).")
        case .mail:
            String(localized: "An unsubscribe email will be sent to \(method.target) from your account.")
        case .web:
            String(localized: "The unsubscribe page on \(method.target) will open in your browser.")
        }
    }

    private func perform() async {
        if case .web(let url) = method {
            openURL(url)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await env.syncService.unsubscribe(method, accountID: accountID)
            isDone = true
        } catch {
            errorText = error.localizedDescription
        }
    }
}
