//
//  GeneralSettingsView.swift
//  MyEmail
//
//  General preferences: check interval, default account, start behavior.
//

import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("checkIntervalMinutes") private var checkInterval: Int = 5
    @AppStorage("markAsReadOnSelect") private var markAsReadOnSelect = true
    @AppStorage("showUnifiedInbox") private var showUnifiedInbox = true
    @AppStorage("confirmDelete") private var confirmDelete = false
    @AppStorage("windowLayout") private var layout: String = "wide"

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Window layout", selection: $layout) {
                    Text("Wide").tag("wide")
                    Text("Classic").tag("classic")
                }
            }

            Section("Sync") {
                Picker("Check for new mail every", selection: $checkInterval) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            }

            Section("Reading") {
                Toggle("Mark messages as read when selected", isOn: $markAsReadOnSelect)
            }

            Section("Sidebar") {
                Toggle("Show Unified Inbox", isOn: $showUnifiedInbox)
            }

            Section("Safety") {
                Toggle("Confirm before deleting messages", isOn: $confirmDelete)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
