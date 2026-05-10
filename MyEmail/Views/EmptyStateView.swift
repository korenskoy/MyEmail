//
//  EmptyStateView.swift
//  MyEmail
//
//  Reusable empty state: centered icon + message + optional action.
//  Minimal style per reference_1 (no aggressive text, just icon + label).
//  DESIGN.md §12.2.
//

import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let message: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
