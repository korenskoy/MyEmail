//
//  MultiSelectFolderField.swift
//  MyEmail
//
//  Compact multi-select control for folder scope. Button shows the summary
//  of selected folders (comma-joined, truncated), click opens a popover with
//  "Select all" toggle + scrollable checklist indented by folder depth.
//  Empty selection → placeholder "All Inbox folders" (legacy scope semantics).
//

import SwiftUI

struct MultiSelectFolderField: View {
    let folders: [Folder]
    @Binding var scope: [String]

    @State private var isPresented = false

    private struct FlatEntry: Hashable {
        let folder: Folder
        let depth: Int
    }

    private var flattened: [FlatEntry] {
        let tree = FolderTreeBuilder.build(from: folders)
        var result: [FlatEntry] = []
        func walk(_ nodes: [FolderNode], depth: Int) {
            for node in nodes {
                result.append(FlatEntry(folder: node.folder, depth: depth))
                if let children = node.children {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(tree, depth: 0)
        return result
    }

    private var summaryText: String {
        guard !scope.isEmpty else {
            return String(localized: "All Inbox folders")
        }
        let names = scope.compactMap { path in
            folders.first { $0.path == path }?.displayName
        }
        return names.isEmpty ? String(localized: "All Inbox folders")
                             : names.joined(separator: ", ")
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(summaryText)
                    .foregroundStyle(scope.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverBody
        }
    }

    @ViewBuilder
    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: selectAllBinding) {
                Text(String(localized: "Select all"))
                    .font(.callout).bold()
            }
            .toggleStyle(.checkbox)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(flattened, id: \.folder.id) { entry in
                        Toggle(isOn: binding(for: entry.folder.path)) {
                            Text(String(repeating: "  ", count: entry.depth)
                                 + entry.folder.displayName)
                                .font(.callout)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)
        }
        .padding(10)
        .frame(width: 260)
    }

    private var selectAllBinding: Binding<Bool> {
        Binding(
            get: { !folders.isEmpty && scope.count >= folders.count },
            set: { on in
                scope = on ? folders.map(\.path) : []
            }
        )
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { scope.contains(path) },
            set: { isOn in
                if isOn {
                    if !scope.contains(path) { scope.append(path) }
                } else {
                    scope.removeAll { $0 == path }
                }
            }
        )
    }
}
