//
//  RemoteContentBanner.swift
//  MyEmail
//
//  Banner for blocked remote content with load/trust actions.
//

import SwiftUI
import SwiftMail

struct RemoteContentBanner: View {
    let senderEmail: String
    let onAllow: () -> Void
    let onTrustSender: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.orange)
                Text(String(localized: "Remote images blocked"))
                    .font(.callout)
                Spacer()
                Menu {
                    Button(String(localized: "Load remote content")) {
                        onAllow()
                    }
                    Divider()
                    Button(String(localized: "Always load from \(EmailAddress.emailOnly(from: senderEmail))")) {
                        onTrustSender()
                    }
                } label: {
                    Text(String(localized: "Load remote content"))
                } primaryAction: {
                    onAllow()
                }
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background)
            Divider()
        }
    }

    // Sandy-beige in light mode, system control background in dark.
    private var background: Color {
        colorScheme == .light
            ? Color(red: 0xFD / 255.0, green: 0xF8 / 255.0, blue: 0xF0 / 255.0)
            : Color(nsColor: .controlBackgroundColor)
    }
}
