//
//  SettingsSplitView.swift
//  MyEmail
//
//  MailMate-style sidebar settings: category list on the left, form on the right.
//  Hosted inside SettingsWindowController's NSHostingView (no toolbar).
//

import SwiftUI

enum SettingsCategory: String, Hashable, CaseIterable, Identifiable {
    case general, accounts, signatures, rules, privacy, appearance, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general:    return String(localized: "General")
        case .accounts:   return String(localized: "Accounts")
        case .signatures: return String(localized: "Signatures")
        case .rules:      return String(localized: "Rules")
        case .privacy:    return String(localized: "Privacy")
        case .appearance: return String(localized: "Appearance")
        case .advanced:   return String(localized: "Advanced")
        }
    }

    var icon: String {
        switch self {
        case .general:    return "gearshape"
        case .accounts:   return "at"
        case .signatures: return "signature"
        case .rules:      return "line.3.horizontal.decrease.circle"
        case .privacy:    return "hand.raised"
        case .appearance: return "paintbrush"
        case .advanced:   return "gearshape.2"
        }
    }
}

struct SettingsSplitView: View {
    @State private var selection: SettingsCategory = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { cat in
                Label(cat.title, systemImage: cat.icon).tag(cat)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            detailView(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 560)
    }

    @ViewBuilder
    private func detailView(for cat: SettingsCategory) -> some View {
        switch cat {
        case .general:    GeneralSettingsView()
        case .accounts:   AccountSettingsView()
        case .signatures: SignatureSettingsView()
        case .rules:      RuleSettingsView()
        case .privacy:    PrivacySettingsView()
        case .appearance: AppearanceSettingsView()
        case .advanced:   AdvancedSettingsView()
        }
    }
}
