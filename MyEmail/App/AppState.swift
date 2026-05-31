//
//  AppState.swift
//  MyEmail
//
//  @Observable, @MainActor. UI reads via `@Environment(AppState.self)`.
//  No ViewModels (§3.3).
//

import Foundation
import GRDB
import Observation

// MARK: - SidebarItem

enum SidebarItem: Hashable {
    case unifiedInbox
    case folder(UUID)
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {
    // MARK: - Selection

    var selectedFolder: Folder?
    var selectedMessageIDs: Set<UUID> = []

    /// First selected message — used for detail pane display.
    var selectedMessageID: UUID? { selectedMessageIDs.first }
    var selectedSidebarItem: SidebarItem? {
        didSet { sidebarSelectionChanged() }
    }

    // MARK: - Lists (MessageListItem projection — §5.4, bug 9.4)

    var messageItems: [MessageListItem] = [] {
        didSet { pruneSelection() }
    }
    var folders: [Folder] = []
    var accounts: [Account] = []

    var isUnifiedInbox: Bool { selectedSidebarItem == .unifiedInbox }

    // MARK: - Pagination

    /// Ternary has-more state derived from `Folder.moreMessages` (Thunderbird §7.4).
    /// Source of truth is the persisted folder row — ValueObservation on
    /// `folders` keeps `selectedFolder` fresh, so this recomputes on every
    /// pagination tick without mutable state.
    ///   nil  → unknown (pre-sync or no info yet)
    ///   true → server has more messages below the current UID floor
    ///   false → local already covers UID=1 / server returned empty page
    var hasMoreMessages: Bool? {
        switch selectedFolder?.moreMessages {
        case .true: return true
        case .false: return false
        case .unknown, .none: return nil
        }
    }
    /// Legacy binary accessor retained for existing call-sites. Treats `nil`
    /// as true so infinite-scroll keeps firing until we learn otherwise.
    var hasMoreOnServer: Bool { hasMoreMessages ?? true }
    var isLoadingMore = false

    // MARK: - Threading

    var isThreaded: Bool = UserDefaults.standard.object(forKey: "isThreaded") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isThreaded, forKey: "isThreaded") }
    }

    // MARK: - Sort

    /// Session-scoped message list sort. Reset to `.default` on sidebar
    /// selection change (see `sidebarSelectionChanged`).
    var messageSort: MessageSort = .default

    // MARK: - Search

    var searchText: String = ""
    var searchScope: SearchScope = .currentFolder
    var searchResults: [MessageListItem] = [] {
        didSet {
            guard !isApplyingSearchObservation else { return }
            let newIDs = Set(searchResults.map(\.id))
            let oldIDs = Set(oldValue.map(\.id))
            if newIDs != oldIDs {
                rebindSearchResultsObservation()
            }
        }
    }
    var isSearching = false
    var isSearchActive: Bool { !searchText.isEmpty }
    var serverSearchTask: Task<Void, Never>?
    /// Guards observation-driven updates from retriggering the observation.
    private var isApplyingSearchObservation = false
    var searchResultsCancellable: AnyDatabaseCancellable?
    /// Set to true by ⌘F command; SearchBarView observes and takes focus.
    var focusSearchField = false

    /// Pre-built lookup for O(1) account name by ID (used in MessageListTable).
    var accountNameByID: [UUID: String] = [:]

    // MARK: - Error surface

    var errors: [AppError] = []

    func surfaceError(_ title: String, detail: String? = nil) {
        errors.append(AppError(title: title, detail: detail))
    }

    // MARK: - Cancellables

    var messagesCancellable: AnyDatabaseCancellable?
    var foldersCancellable: AnyDatabaseCancellable?
    var accountsCancellable: AnyDatabaseCancellable?

    private var pool: DatabasePool { DatabaseService.shared.pool }

    init() {}

    /// Drop selected IDs that are no longer visible in the list.
    /// When search is active the visible list is `searchResults` — pruning
    /// against `messageItems` would drop cross-folder/cross-account hits and
    /// collapse the reading pane mid-open (CancellationError in loadBody).
    private func pruneSelection() {
        guard !selectedMessageIDs.isEmpty else { return }
        if isSearchActive { return }
        let visibleIDs = Set(messageItems.map(\.id))
        selectedMessageIDs.formIntersection(visibleIDs)
    }

    // MARK: - Sidebar selection → observation switch

    private func sidebarSelectionChanged() {
        guard let item = selectedSidebarItem else {
            stopObservingMessages()
            selectedFolder = nil
            return
        }

        selectedMessageIDs = []
        isLoadingMore = false
        // Folder switch clears session-scoped sort so each folder opens
        // in its natural date-DESC order (MailMate behavior).
        messageSort = .default
        // Clear synchronously so the Table remount (.id switch) does not
        // flash stale rows before the new observation delivers.
        messageItems = []

        switch item {
        case .unifiedInbox:
            selectedFolder = nil
            // IN-subquery (vs JOIN) lets SQLite walk `messages_folder_date`
            // per resolved inbox folder_id instead of scanning the full
            // `messages` table (degraded badly once Archive/All Mail grew
            // past tens of thousands of rows). LIMIT 500 caps the initial
            // synchronous fetch on MainActor — visually we never show more.
            observeMessages(
                whereClause: """
                WHERE m.folder_id IN (
                    SELECT f.id FROM folders f
                    JOIN accounts a ON a.id = f.account_id
                    WHERE f.special_use = 'inbox' AND a.is_enabled = 1
                )
                """,
                limit: 500
            )

        case .folder(let id):
            selectedFolder = folders.first { $0.id == id }
            observeMessages(
                whereClause: "WHERE m.folder_id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Shared message observation (§5.4 projection)

    private static let messageListColumns = """
        m.id, m.uid, m.subject, m.from_name, m.from_address,
        m.to_addresses, m.date, m.preview,
        m.is_read, m.is_flagged, m.is_answered,
        m.has_attachments,
        m.thread_id, m.folder_id, m.account_id, m.size, m.interaction_score,
        m.message_id, m.in_reply_to, m."references"
        """

    private func observeMessages(
        whereClause: String,
        arguments: StatementArguments = StatementArguments(),
        limit: Int? = nil
    ) {
        // Eager model: per-folder queries hit `messages_folder_date` and stay
        // fast even on huge folders — projection + NSTableView keep memory
        // bounded. Cross-folder views (Unified Inbox) pass an explicit `limit`
        // because the initial fetch runs synchronously on MainActor.
        var sql = """
            SELECT \(Self.messageListColumns)
            FROM messages m
            \(whereClause)
            ORDER BY m.date DESC
            """
        if let limit {
            sql += "\nLIMIT \(limit)"
        }

        LogService.log(.debug, .db, "Observing messages", detail: whereClause.prefix(60).description)

        messagesCancellable?.cancel()

        messagesCancellable = ValueObservation
            .tracking { db in
                try MessageListItem.fetchAll(db, sql: sql, arguments: arguments)
            }
            .start(in: pool, scheduling: .async(onQueue: .global(qos: .userInitiated))) { error in
                LogService.log(.error, .db, "Messages observation error", detail: "\(error)")
            } onChange: { [weak self] items in
                // Async scheduling: the initial fetch runs on a background
                // queue, so opening a huge folder (e.g. Gmail All Mail with
                // 135k rows) no longer blocks MainActor on the SELECT and the
                // 135k MessageListItem allocations. UI stays responsive; rows
                // appear once the fetch completes (~100-300 ms on SSD).
                //
                // `messageItems = []` is already set synchronously in
                // `sidebarSelectionChanged` before this binds, so there is no
                // stale-row flash — only a brief empty list during the fetch.
                Task { @MainActor [weak self] in
                    self?.messageItems = items
                }
            }
    }

    func stopObservingMessages() {
        messagesCancellable?.cancel()
        messagesCancellable = nil
        messageItems = []
    }

    // MARK: - Search results observation

    /// (Re)bind DB observation to the current `searchResults` id set so
    /// in-DB mutations (body fetch updates size / has_attachments, flag
    /// changes, etc.) reflect in the list immediately — matching the
    /// reactive behaviour of the main `messageItems` observation.
    private func rebindSearchResultsObservation() {
        searchResultsCancellable?.cancel()
        searchResultsCancellable = nil

        let ids = searchResults.map(\.id)
        guard !ids.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT \(Self.messageListColumns)
            FROM messages m
            WHERE m.id IN (\(placeholders))
            """
        let args = StatementArguments(ids)

        searchResultsCancellable = ValueObservation
            .tracking { db in
                try MessageListItem.fetchAll(db, sql: sql, arguments: args)
            }
            .start(in: pool, scheduling: .immediate) { error in
                LogService.log(.error, .db, "Search observation error", detail: "\(error)")
            } onChange: { [weak self] items in
                MainActor.assumeIsolated {
                    self?.applySearchObservationUpdate(items)
                }
            }
    }

    /// Re-key fresh rows into the current `searchResults` order so ranking
    /// from the search pipeline is preserved; drop any id no longer in DB.
    private func applySearchObservationUpdate(_ items: [MessageListItem]) {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let reordered = searchResults.compactMap { byID[$0.id] }
        isApplyingSearchObservation = true
        searchResults = reordered
        isApplyingSearchObservation = false
    }

    // MARK: - Observe folders

    func observeFolders() {
        foldersCancellable = ValueObservation
            .tracking { db in
                try Folder
                    .order(Column("account_id").asc, Column("path").asc)
                    .fetchAll(db)
            }
            .start(in: pool, scheduling: .immediate) { error in
                LogService.log(.error, .db, "Folders observation error", detail: "\(error)")
            } onChange: { folders in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.folders = folders
                    // Keep selectedFolder in sync with DB state (moreMessages, unreadCount, etc.)
                    if let sf = self.selectedFolder {
                        self.selectedFolder = folders.first { $0.id == sf.id }
                    }
                }
            }
    }

    // MARK: - Observe accounts

    /// Track accounts table changes so `auth_state` flips (→ needsReauth)
    /// surface in the orange Reconnect banner without an app restart.
    func observeAccounts() {
        accountsCancellable = ValueObservation
            .tracking { db in
                // Match AccountRepository.all() so sidebar order == Settings order.
                try Account
                    .order(Column("sort_order").asc, Column("name").asc)
                    .fetchAll(db)
            }
            .start(in: pool, scheduling: .immediate) { error in
                LogService.log(.error, .db, "Accounts observation error", detail: "\(error)")
            } onChange: { accounts in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.accounts = accounts
                    self.rebuildAccountLookup()
                }
            }
    }

    // MARK: - Rebuild account lookup

    func rebuildAccountLookup() {
        accountNameByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0.name) }
        )
    }
}

// MARK: - AppError

struct AppError: Identifiable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let title: String
    let detail: String?

    init(title: String, detail: String? = nil) {
        self.id = UUID()
        self.date = Date()
        self.title = title
        self.detail = detail
    }
}
