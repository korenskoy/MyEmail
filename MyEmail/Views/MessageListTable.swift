//
//  MessageListTable.swift
//  MyEmail
//
//  Thin SwiftUI wrapper around `MessageListNSTable` (AppKit). Owns
//  threading cache + context actions; delegates rendering entirely
//  to an `NSTableView`-backed representable so @Observable data
//  ticks can't cause header/cell jiggle.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MessageListTable: View {
    // MARK: - Environment
    @Environment(AppState.self) private var appState
    @Environment(AppEnvironment.self) private var env
    @Environment(\.undoManager) private var undoManager
    @AppStorage("messageDensity") private var density: String = "compact"

    // MARK: - Inputs
    let items: [MessageListItem]
    let folderID: UUID?
    @Binding var selectedMessageIDs: Set<UUID>
    var showAccountColumn: Bool = false
    var isSentOrDrafts: Bool = false

    // MARK: - State
    @State private var expandedThreadIDs: Set<UUID> = []
    @State private var sourceSheet: SourceSheet?

    // Display-order cache: recomputed only when structural inputs change
    // (count / first-last id / isThreaded / expanded set / sort). Cell-level
    // updates (size, flags, read state) reuse the cached order — the byID
    // lookup in `body` resolves to whichever live MessageListItem just
    // arrived from the observation, so flag/read flips render immediately.
    //
    // Materializing the sort here (instead of in body) is what removes the
    // per-render hit on huge folders: threading + sorting 135k UIDs is
    // ~80 ms work which used to happen every body render.
    @State private var cachedOrder: [UUID] = []
    @State private var cachedCounts: [UUID: Int] = [:]
    @State private var cachedSignature: DisplaySignature = .empty

    private struct DisplaySignature: Equatable {
        let count: Int
        let firstID: UUID?
        let lastID: UUID?
        let isThreaded: Bool
        let expanded: Set<UUID>
        let sortColumn: MessageSort.Column
        let sortAscending: Bool
        static let empty = DisplaySignature(
            count: -1, firstID: nil, lastID: nil, isThreaded: false, expanded: [],
            sortColumn: .date, sortAscending: false
        )
    }

    private var currentSignature: DisplaySignature {
        DisplaySignature(
            count: items.count,
            firstID: items.first?.id,
            lastID: items.last?.id,
            isThreaded: appState.isThreaded,
            expanded: expandedThreadIDs,
            sortColumn: appState.messageSort.column,
            sortAscending: appState.messageSort.order.ascending
        )
    }

    /// Row height mapped from density setting (DESIGN.md §4.4).
    private var rowHeight: CGFloat {
        switch density {
        case "compact": return 22
        case "normal":  return 26
        case "wide":    return 34
        default:        return 22
        }
    }

    private var itemByID: [UUID: MessageListItem] {
        Dictionary(items.lazy.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    }

    private func recomputeDisplayOrder() {
        // Step 1: threading collapse → flat UUID order.
        let threadedItems: [MessageListItem]
        if appState.isThreaded {
            let groups = ThreadingService.group(items)
            var collected: [MessageListItem] = []
            collected.reserveCapacity(items.count)
            var counts: [UUID: Int] = [:]
            for group in groups {
                if group.count == 1 {
                    collected.append(group.latest)
                } else {
                    counts[group.latest.id] = group.count
                    if expandedThreadIDs.contains(group.id) {
                        collected.append(contentsOf: group.messages)
                    } else {
                        collected.append(group.latest)
                    }
                }
            }
            threadedItems = collected
            cachedCounts = counts
        } else {
            threadedItems = items
            cachedCounts = [:]
        }
        // Step 2: sort once here (was previously per-body render — the hot
        // path on 135k-row folders). Trade-off: in threaded mode with a
        // non-date sort, expanded-thread children may interleave with
        // unrelated rows — same as before, just materialized once.
        let sorted = threadedItems.sorted(
            by: appState.messageSort, isSentOrDrafts: isSentOrDrafts
        )
        cachedOrder = sorted.map(\.id)
        cachedSignature = currentSignature
    }

    var body: some View {
        // Resolve UUIDs through a fresh byID lookup so flag/read updates
        // that arrive in `items` without changing the structural signature
        // still render immediately. The Dictionary build is O(N) but cheap
        // compared to the old per-render threading + sort.
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let displayItems = cachedOrder.compactMap { byID[$0] }
        let threadCounts = cachedCounts

        return MessageListNSTable(
            items: displayItems,
            threadCounts: threadCounts,
            selectedMessageIDs: $selectedMessageIDs,
            showAccountColumn: showAccountColumn,
            isSentOrDrafts: isSentOrDrafts,
            rowHeight: rowHeight,
            accountName: { appState.accountNameByID[$0] ?? "" },
            sort: appState.messageSort,
            onDoubleClick: openMessageWindow,
            onPaginateIfLast: { id in
                // Pagination trigger matches previous SwiftUI behaviour:
                // only fire when we're at the last row AND state is not
                // "known no more" AND we're not already loading.
                guard id == displayItems.last?.id,
                      appState.hasMoreMessages != false,
                      !appState.isLoadingMore else { return }
                triggerLoadMore()
            },
            onToggleRead: toggleReadState,
            onToggleFlag: toggleFlagged,
            onArchive: archiveMessages,
            onDelete: deleteMessages,
            onOpenInWindow: openMessageWindow,
            onViewSource: { id in Task { await fetchAndShowSource(id) } },
            onSaveAs: { id in Task { await saveMessageToDownloads(id) } },
            onResync: { id in Task { await env.syncService.resyncMessage(id: id) } },
            onRunRules: runRulesOnSelection,
            onSortChange: { appState.messageSort = $0 }
        )
        .overlay {
            if appState.isSearchActive
                && !appState.isSearching
                && displayItems.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    message: String(localized: "No results")
                )
            }
        }
        .sheet(item: $sourceSheet) { sheet in
            RawSourceView(source: sheet.source, onDismiss: { sourceSheet = nil })
        }
        .onAppear {
            if cachedSignature != currentSignature { recomputeDisplayOrder() }
        }
        .onChange(of: currentSignature) { _, _ in recomputeDisplayOrder() }
    }

    private func openMessageWindow(_ id: UUID) {
        (NSApp.delegate as? AppDelegate)?.openMessage(id: id)
    }

    // MARK: - Actions

    private func toggleReadState(_ ids: [UUID]) {
        Task {
            if anyUnread(in: ids) {
                await env.undoService.markAsRead(ids, undoManager: undoManager)
            } else {
                await env.undoService.markAsUnread(ids, undoManager: undoManager)
            }
        }
    }

    private func toggleFlagged(_ ids: [UUID]) {
        Task {
            await env.undoService.setFlagged(ids, flagged: anyUnflagged(in: ids),
                                             undoManager: undoManager)
        }
    }

    private func deleteMessages(_ ids: [UUID]) {
        Task { await env.undoService.deleteMessages(ids, undoManager: undoManager) }
    }

    private func archiveMessages(_ ids: [UUID]) {
        Task { await env.undoService.archiveMessages(ids, undoManager: undoManager) }
    }

    /// Run manual rules on the selected messages. When the list spans folders
    /// (Unified Inbox), group IDs by their source folder so each batch uses
    /// the correct accountID + scope. `accountID` is resolved from the
    /// message's folder (Folder.accountID).
    private func runRulesOnSelection(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let byFolder = Dictionary(grouping: ids) { id in
            itemByID[id]?.folderID
        }
        for (maybeFolderID, group) in byFolder {
            guard let fid = maybeFolderID,
                  let folder = appState.folders.first(where: { $0.id == fid }) else { continue }
            let accountID = folder.accountID
            Task {
                await env.syncService.runRulesManually(
                    in: fid, accountID: accountID, messageIDs: group
                )
            }
        }
    }

    private func anyUnread(in ids: [UUID]) -> Bool {
        ids.contains { itemByID[$0]?.isRead == false }
    }

    private func anyUnflagged(in ids: [UUID]) -> Bool {
        ids.contains { itemByID[$0]?.isFlagged == false }
    }

    private func fetchAndShowSource(_ messageID: UUID) async {
        do {
            let src = try await env.syncService.fetchRawSource(messageID: messageID)
            sourceSheet = SourceSheet(source: src)
        } catch {
            sourceSheet = SourceSheet(source: nil)
            LogService.log(.error, .sync, "View Source failed", detail: "\(error)")
        }
    }

    /// Save raw RFC822 source to disk. Streams bytes directly, avoiding the
    /// String conversion / large-window UI cost of View Source.
    /// Synchronous path mirrors `AttachmentStripView.saveAs` — `runModal()`
    /// must be on the main thread, NOT inside an awaited Task started from
    /// an NSMenu handler (where the panel is silently swallowed).
    /// Save raw RFC822 source straight to ~/Downloads + reveal in Finder.
    /// NSSavePanel is unusable in this app on macOS 26 (NSHostingView host
    /// silently swallows the panel), so we skip the dialog entirely.
    private func saveMessageToDownloads(_ messageID: UUID) async {
        do {
            guard let data = try await env.syncService
                .fetchRawSourceData(messageID: messageID) else { return }
            let dest = uniqueDownloadURL(for: messageID)
            try data.write(to: dest, options: .atomic)
            LogService.log(.info, .sync, "Saved message to Downloads",
                           detail: "\(dest.path) (\(data.count) bytes)")
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            LogService.log(.error, .sync, "Save failed", detail: "\(error)")
        }
    }

    /// `~/Downloads/{subject}.eml` — appends ` (2)`, ` (3)`… on collision.
    private func uniqueDownloadURL(for messageID: UUID) -> URL {
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let base = suggestedFilename(for: messageID)
            .replacingOccurrences(of: ".eml", with: "")
        var url = downloads.appendingPathComponent("\(base).eml")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloads.appendingPathComponent("\(base) (\(counter)).eml")
            counter += 1
        }
        return url
    }

    private func suggestedFilename(for messageID: UUID) -> String {
        let raw = itemByID[messageID]?.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (raw?.isEmpty == false ? raw! : "Untitled")
        let illegal: Set<Character> = ["/", ":", "\\", "?", "*", "|", "\"", "<", ">"]
        var sanitized = String(base.map { illegal.contains($0) ? "_" : $0 })
        if sanitized.count > 120 { sanitized = String(sanitized.prefix(120)) }
        return "\(sanitized).eml"
    }

    // MARK: - Pagination

    private func triggerLoadMore() {
        guard !appState.isLoadingMore, let fid = folderID else { return }
        appState.isLoadingMore = true
        Task {
            _ = await env.syncService.loadOlderMessages(folderID: fid)
            appState.isLoadingMore = false
        }
    }
}
