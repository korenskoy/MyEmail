//
//  DebugLogPanelView.swift
//  MyEmail
//
//  Сворачиваемая bottom panel главного окна в стиле VS Code terminal.
//  Единственный способ для пользователя увидеть логи (§6.10, 8.7).
//
//  Разбита на мелкие sub-structs (hard rule: Views ≤ 300 строк,
//  dedicated `struct View`-субкомпоненты).
//

import AppKit
import SwiftUI

// MARK: - Host panel

struct DebugLogPanelView: View {
    @Environment(LogService.self) private var log
    @AppStorage("debugLogPanelHeight") private var height: Double = 220
    @AppStorage("debugLogFilterLevel") private var filterLevelRaw: String = LogLevel.debug.rawValue
    @AppStorage("debugLogFilterCategory") private var filterCategoryRaw: String = ""
    @AppStorage("debugLogAutoScroll") private var autoScroll: Bool = true
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            DebugLogHeaderBar(
                filterLevelRaw: $filterLevelRaw,
                filterCategoryRaw: $filterCategoryRaw,
                searchText: $searchText,
                autoScroll: $autoScroll,
                filteredEntriesProvider: { filteredEntries }
            )
            Divider()
            DebugLogList(
                entries: filteredEntries,
                autoScroll: autoScroll
            )
                .frame(height: max(120, height - 36))
        }
    }

    // MARK: - Filtering

    private var filteredEntries: [LogEntry] {
        let level = LogLevel(rawValue: filterLevelRaw) ?? .debug
        let category = LogCategory(rawValue: filterCategoryRaw)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return log.entries.filter { entry in
            guard entry.level >= level else { return false }
            if let category, entry.category != category { return false }
            if !needle.isEmpty {
                let haystack = entry.message.lowercased()
                    + " " + (entry.detail?.lowercased() ?? "")
                if !haystack.contains(needle) { return false }
            }
            return true
        }
    }

    // MARK: - Resize handle

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(height: 4)
            .overlay(alignment: .top) { Divider() }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        height = max(120, min(600, height - value.translation.height))
                    }
            )
    }
}

// MARK: - Header bar

struct DebugLogHeaderBar: View {
    @Binding var filterLevelRaw: String
    @Binding var filterCategoryRaw: String
    @Binding var searchText: String
    @Binding var autoScroll: Bool
    let filteredEntriesProvider: () -> [LogEntry]

    @Environment(LogService.self) private var log

    var body: some View {
        HStack(spacing: 8) {
            Text("Debug Log")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Divider().frame(height: 14)

            Picker(selection: $filterLevelRaw) {
                ForEach(LogLevel.allCases, id: \.self) { lvl in
                    Text(lvl.rawValue.capitalized).tag(lvl.rawValue)
                }
            } label: {
                Text("Level")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            Picker(selection: $filterCategoryRaw) {
                Text("All").tag("")
                ForEach(LogCategory.allCases, id: \.self) { cat in
                    Text(cat.rawValue).tag(cat.rawValue)
                }
            } label: {
                Text("Category")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            TextField("Search logs", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer(minLength: 0)

            Toggle(isOn: $autoScroll) {
                Image(systemName: autoScroll ? "arrow.down.to.line" : "pin.slash")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Auto-scroll to bottom")

            Button {
                let text = DebugLogFormatter.plainText(for: filteredEntriesProvider())
                DebugLogFormatter.copyToClipboard(text)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy log")

            Button {
                log.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear log")
        }
        .font(.system(.callout))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Log list

struct DebugLogList: View {
    let entries: [LogEntry]
    let autoScroll: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        DebugLogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: entries.count) { _, _ in
                guard autoScroll, let last = entries.last else { return }
                withAnimation(.none) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Single row

struct DebugLogRow: View {
    let entry: LogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            Text(entry.level.rawValue.uppercased())
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(levelColor)
                .frame(width: 56, alignment: .leading)

            Text(entry.category.rawValue)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(localized: "Copy")) {
                DebugLogFormatter.copyToClipboard(
                    DebugLogFormatter.plainText(for: entry)
                )
            }
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug:   return .secondary
        case .info:    return .primary
        case .warning: return Color.orange
        case .error:   return Color.red
        }
    }
}

// MARK: - Plain-text formatter for clipboard

nonisolated enum DebugLogFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    nonisolated static func plainText(for entry: LogEntry) -> String {
        let time = formatter.string(from: entry.timestamp)
        let level = entry.level.rawValue.uppercased()
            .padding(toLength: 7, withPad: " ", startingAt: 0)
        let category = entry.category.rawValue
            .padding(toLength: 14, withPad: " ", startingAt: 0)

        var line = "\(time)  \(level) \(category)  \(entry.message)"
        if let detail = entry.detail, !detail.isEmpty {
            // Indent multi-line detail so pasted blocks stay readable.
            let indented = detail
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    \($0)" }
                .joined(separator: "\n")
            line += "\n\(indented)"
        }
        return line
    }

    nonisolated static func plainText(for entries: [LogEntry]) -> String {
        entries.map(plainText(for:)).joined(separator: "\n")
    }

    nonisolated static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
