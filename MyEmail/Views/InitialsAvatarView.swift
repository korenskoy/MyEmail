//
//  InitialsAvatarView.swift
//  MyEmail
//
//  Circular avatar with sender initial. Default placeholder for reading pane
//  header (DESIGN.md §4.5). Gravatar overlays this when enabled.
//

import SwiftUI

struct InitialsAvatarView: View {
    let name: String?
    let email: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)

            Text(initial)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initial: String {
        if let name, let first = name.first, first.isLetter {
            return String(first).uppercased()
        }
        if let first = email.first, first.isLetter {
            return String(first).uppercased()
        }
        return "?"
    }
}
