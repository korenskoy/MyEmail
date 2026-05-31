//
//  MessageListNSTable.swift
//  MyEmail
//
//  AppKit NSTableView wrapped in NSViewRepresentable. Replaces SwiftUI
//  Table, which pushed NSHostingView into every header/row cell and
//  re-rendered on every @Observable tick — producing persistent visual
//  jiggle in the header row that KVO/CA-action suppression could not
//  fully eliminate.
//
//  Contract: same external API as the previous SwiftUI Table —
//  `items`, `selectedMessageIDs` binding, context menu, double-click,
//  pagination trigger, drag. Column order + width persist via
//  NSTableView.autosaveName.
//

import AppKit
import SwiftUI

// MARK: - Column identifiers

private extension NSUserInterfaceItemIdentifier {
    static let status     = NSUserInterfaceItemIdentifier("status")
    static let attachment = NSUserInterfaceItemIdentifier("attachment")
    static let fromTo     = NSUserInterfaceItemIdentifier("fromTo")
    static let subject    = NSUserInterfaceItemIdentifier("subject")
    static let date       = NSUserInterfaceItemIdentifier("date")
    static let size       = NSUserInterfaceItemIdentifier("size")
    static let account    = NSUserInterfaceItemIdentifier("account")
}

// MARK: - Representable

struct MessageListNSTable: NSViewRepresentable {
    let items: [MessageListItem]
    let threadCounts: [UUID: Int]
    @Binding var selectedMessageIDs: Set<UUID>
    let showAccountColumn: Bool
    let isSentOrDrafts: Bool
    let rowHeight: CGFloat
    let accountName: (UUID) -> String
    let sort: MessageSort

    // Actions
    let onDoubleClick: (UUID) -> Void
    let onPaginateIfLast: (UUID) -> Void
    let onToggleRead: ([UUID]) -> Void
    let onToggleFlag: ([UUID]) -> Void
    let onArchive: ([UUID]) -> Void
    let onDelete: ([UUID]) -> Void
    let onOpenInWindow: (UUID) -> Void
    let onViewSource: (UUID) -> Void
    let onSaveAs: (UUID) -> Void
    let onResync: (UUID) -> Void
    let onRunRules: ([UUID]) -> Void
    let onSortChange: (MessageSort) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let table = NSTableView()
        table.style = .fullWidth
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        // MailMate-style zebra: alternating row background colors,
        // no vertical grid lines (dense, readable).
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = []
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 4, height: 0)
        table.doubleAction = #selector(Coordinator.tableDoubleClicked(_:))
        table.target = coordinator
        table.registerForDraggedTypes([.string])

        // Columns MUST be added before `autosaveName` is set —
        // NSTableView applies saved widths/order/visibility at the moment
        // the autosave name is assigned, matching by column identifier.
        // If columns aren't present yet, restoration silently no-ops and
        // user resizing in one folder is lost when another instance is
        // created.  All MessageListTable instances (Classic, Wide,
        // Unified, any folder) share the same autosaveName so their
        // column layout is a single global preference.
        buildColumns(on: table)
        table.autosaveTableColumns = true
        table.autosaveName = "MessageListTable.v2"

        table.dataSource = coordinator
        table.delegate = coordinator

        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        // Header context menu — right-click on a column header shows a
        // checklist of columns to hide/show (Status column stays fixed).
        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        coordinator.headerMenu = headerMenu
        table.headerView?.menu = headerMenu

        scroll.documentView = table
        coordinator.tableView = table
        coordinator.items = items
        table.reloadData()

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard let table = coordinator.tableView else { return }

        // Row height / density
        if table.rowHeight != rowHeight {
            table.rowHeight = rowHeight
        }

        // Column header titles (From ↔ To) — localized.
        table.tableColumn(withIdentifier: .fromTo)?
            .headerCell.stringValue = isSentOrDrafts
                ? String(localized: "To")
                : String(localized: "From")

        // Account column is a parent-driven toggle (Unified Inbox / search
        // across accounts). User-driven hide/show for the remaining columns
        // is done via the header context menu.
        if let accountCol = table.tableColumn(withIdentifier: .account) {
            let shouldHide = !showAccountColumn
            if accountCol.isHidden != shouldHide {
                accountCol.isHidden = shouldHide
            }
        }

        // Reflect external sort state in the header indicator. Guarded by
        // isApplyingExternalSort so the sync doesn't loop back through
        // `sortDescriptorsDidChange`.
        let desiredDescriptor = NSSortDescriptor(
            key: sort.column.rawValue, ascending: sort.order.ascending
        )
        let currentDescriptor = table.sortDescriptors.first
        let sameKey = currentDescriptor?.key == desiredDescriptor.key
        let sameAsc = currentDescriptor?.ascending == desiredDescriptor.ascending
        if !sameKey || !sameAsc {
            coordinator.isApplyingExternalSort = true
            table.sortDescriptors = [desiredDescriptor]
            coordinator.isApplyingExternalSort = false
        }

        // Diff items: structural change (ids differ) → reloadData.
        // Value-only change (same ids) → reloadData on visible rows
        // without destroying NSTableRowView instances → no header reflow.
        let oldIDs = coordinator.items.map(\.id)
        let newIDs = items.map(\.id)
        coordinator.items = items

        if oldIDs != newIDs {
            table.reloadData()
        } else if !items.isEmpty {
            let visible = table.rows(in: scroll.contentView.bounds)
            if visible.length > 0 {
                let rowIndexes = IndexSet(integersIn: visible.location..<visible.location + visible.length)
                let colIndexes = IndexSet(integersIn: 0..<table.tableColumns.count)
                table.reloadData(forRowIndexes: rowIndexes, columnIndexes: colIndexes)
            }
        }

        // Sync selection (external → AppKit)
        let desiredRows = IndexSet(
            items.enumerated()
                .filter { selectedMessageIDs.contains($0.element.id) }
                .map(\.offset)
        )
        if table.selectedRowIndexes != desiredRows {
            coordinator.isApplyingExternalSelection = true
            table.selectRowIndexes(desiredRows, byExtendingSelection: false)
            coordinator.isApplyingExternalSelection = false
        }
    }

    private func buildColumns(on table: NSTableView) {
        struct Spec {
            let id: NSUserInterfaceItemIdentifier
            let title: String
            let width: CGFloat
            let min: CGFloat
            let max: CGFloat
            let hidden: Bool
            let alignment: NSTextAlignment
        }

        let specs: [Spec] = [
            .init(id: .status,     title: "",
                  width: 24,  min: 24,  max: 24,   hidden: false, alignment: .left),
            .init(id: .attachment, title: "",
                  width: 20,  min: 20,  max: 20,   hidden: false, alignment: .left),
            .init(id: .fromTo,
                  title: isSentOrDrafts ? String(localized: "To") : String(localized: "From"),
                  width: 180, min: 80,  max: 400,  hidden: false, alignment: .left),
            .init(id: .subject, title: String(localized: "Subject"),
                  width: 400, min: 200, max: 2000, hidden: false, alignment: .left),
            .init(id: .date,    title: String(localized: "Date"),
                  width: 150, min: 120, max: 200,  hidden: false, alignment: .left),
            .init(id: .size,    title: String(localized: "Size"),
                  width: 80,  min: 60,  max: 120,  hidden: true,  alignment: .right),
            .init(id: .account, title: String(localized: "Account"),
                  width: 140, min: 80,  max: 240,  hidden: !showAccountColumn, alignment: .left),
        ]

        for s in specs {
            let col = NSTableColumn(identifier: s.id)
            col.title = s.title
            col.width = s.width
            col.minWidth = s.min
            col.maxWidth = s.max
            col.isHidden = s.hidden
            col.resizingMask = (s.min == s.max) ? [] : [.userResizingMask]
            col.headerCell.alignment = s.alignment
            col.headerCell.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            // Sortable columns get a prototype — AppKit renders the up/down
            // arrow in the header and toggles ascending on repeat clicks.
            // Status/attachment/account have no prototype → not sortable.
            if let sortKey = Self.sortKey(for: s.id) {
                let defaultAscending = (sortKey != MessageSort.Column.date.rawValue)
                col.sortDescriptorPrototype = NSSortDescriptor(
                    key: sortKey, ascending: defaultAscending
                )
            }
            table.addTableColumn(col)
        }
    }

    /// Maps a column identifier to its sort key (`MessageSort.Column.rawValue`).
    /// Columns without a mapping are not sortable.
    private static func sortKey(for id: NSUserInterfaceItemIdentifier) -> String? {
        switch id {
        case .fromTo:  return MessageSort.Column.fromTo.rawValue
        case .subject: return MessageSort.Column.subject.rawValue
        case .date:    return MessageSort.Column.date.rawValue
        case .size:    return MessageSort.Column.size.rawValue
        default:       return nil
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: MessageListNSTable
        var items: [MessageListItem] = []
        weak var tableView: NSTableView?
        weak var headerMenu: NSMenu?
        var isApplyingExternalSelection = false
        var isApplyingExternalSort = false
        private var lastPaginationRowID: UUID?

        init(_ parent: MessageListNSTable) {
            self.parent = parent
        }

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .short
            f.timeStyle = .short
            return f
        }()

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let col = tableColumn, row >= 0, row < items.count else { return nil }
            let item = items[row]

            switch col.identifier {
            case .status:
                return statusCell(for: item, in: tableView)
            case .attachment:
                return attachmentCell(for: item, in: tableView)
            case .fromTo:
                return textCell(
                    in: tableView,
                    text: parent.isSentOrDrafts ? item.displayTo : item.displayFrom,
                    bold: !item.isRead, secondary: false,
                    alignment: .left, monospaced: false
                )
            case .subject:
                return subjectCell(for: item, in: tableView)
            case .date:
                return textCell(
                    in: tableView,
                    text: Self.dateFormatter.string(from: item.date),
                    bold: false, secondary: true,
                    alignment: .left, monospaced: false
                )
            case .size:
                return textCell(
                    in: tableView,
                    text: item.formattedSize,
                    bold: false, secondary: true,
                    alignment: .right, monospaced: true
                )
            case .account:
                return textCell(
                    in: tableView,
                    text: parent.accountName(item.accountID),
                    bold: false, secondary: true,
                    alignment: .left, monospaced: false
                )
            default:
                return nil
            }
        }

        func tableView(_ tableView: NSTableView,
                       pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0, row < items.count else { return nil }
            let pb = NSPasteboardItem()
            pb.setString(items[row].id.uuidString, forType: .string)
            return pb
        }

        // MARK: Delegate

        func tableView(_ tableView: NSTableView,
                       didAdd rowView: NSTableRowView, forRow row: Int) {
            guard row >= 0, row < items.count else { return }
            if row == items.count - 1 {
                let last = items[row].id
                guard lastPaginationRowID != last else { return }
                lastPaginationRowID = last
                parent.onPaginateIfLast(last)
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingExternalSelection, let table = tableView else { return }
            let rows = table.selectedRowIndexes
            let ids = Set(rows.compactMap { idx -> UUID? in
                guard items.indices.contains(idx) else { return nil }
                return items[idx].id
            })
            if ids != parent.selectedMessageIDs {
                let parentRef = parent
                DispatchQueue.main.async {
                    parentRef.selectedMessageIDs = ids
                }
            }
        }

        // MARK: Sorting

        func tableView(_ tableView: NSTableView,
                       sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplyingExternalSort else { return }
            guard let first = tableView.sortDescriptors.first,
                  let key = first.key,
                  let column = MessageSort.Column(rawValue: key) else { return }
            let newSort = MessageSort(
                column: column, order: first.ascending ? .asc : .desc
            )
            guard newSort != parent.sort else { return }
            let callback = parent.onSortChange
            DispatchQueue.main.async {
                callback(newSort)
            }
        }

        @objc func tableDoubleClicked(_ sender: Any?) {
            guard let table = tableView,
                  table.clickedRow >= 0,
                  table.clickedRow < items.count else { return }
            parent.onDoubleClick(items[table.clickedRow].id)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            // Header context menu: list columns with check marks for visible.
            if menu === headerMenu {
                populateHeaderMenu(menu)
                return
            }
            populateRowMenu(menu)
        }

        private func populateHeaderMenu(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView else { return }
            for column in table.tableColumns {
                // Status + attachment columns are fixed — no toggle.
                if column.identifier == .status { continue }
                if column.identifier == .attachment { continue }
                // Account column is driven externally.
                if column.identifier == .account { continue }
                let title = column.headerCell.stringValue
                guard !title.isEmpty else { continue }
                let colID = column.identifier
                let item = ClosureMenuItem(title: title) { [weak self] in
                    guard let table = self?.tableView,
                          let col = table.tableColumn(withIdentifier: colID) else { return }
                    col.isHidden.toggle()
                }
                item.state = column.isHidden ? .off : .on
                menu.addItem(item)
            }
        }

        private func populateRowMenu(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView else { return }

            let targets: [Int] = {
                if table.clickedRow >= 0,
                   !table.selectedRowIndexes.contains(table.clickedRow) {
                    return [table.clickedRow]
                }
                return Array(table.selectedRowIndexes)
            }()

            let ids = targets.compactMap { idx -> UUID? in
                guard items.indices.contains(idx) else { return nil }
                return items[idx].id
            }
            guard !ids.isEmpty else { return }

            let anyUnread = ids.contains(where: { id in
                items.first(where: { $0.id == id })?.isRead == false
            })
            let anyUnflagged = ids.contains(where: { id in
                items.first(where: { $0.id == id })?.isFlagged == false
            })

            let readTitle = anyUnread
                ? String(localized: "Mark as Read")
                : String(localized: "Mark as Unread")
            menu.addMenuItem(readTitle) {
                [weak self] in self?.parent.onToggleRead(ids)
            }
            let flagTitle = anyUnflagged
                ? String(localized: "Flag")
                : String(localized: "Unflag")
            menu.addMenuItem(flagTitle) {
                [weak self] in self?.parent.onToggleFlag(ids)
            }
            menu.addMenuItem(String(localized: "Archive")) {
                [weak self] in self?.parent.onArchive(ids)
            }
            menu.addItem(.separator())
            menu.addMenuItem(String(localized: "Run filters on selected messages")) {
                [weak self] in self?.parent.onRunRules(ids)
            }
            menu.addItem(.separator())
            menu.addMenuItem(String(localized: "Delete")) {
                [weak self] in self?.parent.onDelete(ids)
            }
            if ids.count == 1, let first = ids.first {
                menu.addItem(.separator())
                menu.addMenuItem(String(localized: "Open in New Window")) {
                    [weak self] in self?.parent.onOpenInWindow(first)
                }
                menu.addMenuItem(String(localized: "View Source")) {
                    [weak self] in self?.parent.onViewSource(first)
                }
                menu.addMenuItem(String(localized: "Save to Downloads")) {
                    [weak self] in self?.parent.onSaveAs(first)
                }
                menu.addItem(.separator())
                menu.addMenuItem(String(localized: "Re-sync message")) {
                    [weak self] in self?.parent.onResync(first)
                }
            }
        }

        // MARK: Cell builders

        private func statusCell(for item: MessageListItem, in table: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("statusCell")
            let view = (table.makeView(withIdentifier: id, owner: nil) as? StatusCellView)
                ?? StatusCellView(identifier: id)
            if let count = parent.threadCounts[item.id], count > 1 {
                view.configure(text: "\(count)", showStar: false)
            } else if item.isFlagged {
                view.configure(text: nil, showStar: true)
            } else {
                view.configure(text: nil, showStar: false)
            }
            return view
        }

        private func subjectCell(for item: MessageListItem, in table: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("subjectCell")
            let view = (table.makeView(withIdentifier: id, owner: nil) as? SubjectCellView)
                ?? SubjectCellView(identifier: id)
            view.configure(
                subject: item.subject,
                isUnread: !item.isRead
            )
            return view
        }

        private func attachmentCell(for item: MessageListItem, in table: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("attachmentCell")
            let view = (table.makeView(withIdentifier: id, owner: nil) as? AttachmentCellView)
                ?? AttachmentCellView(identifier: id)
            view.configure(hasAttachment: item.hasAttachments)
            return view
        }

        private func textCell(in table: NSTableView,
                              text: String,
                              bold: Bool,
                              secondary: Bool,
                              alignment: NSTextAlignment,
                              monospaced: Bool) -> NSView {
            let id = NSUserInterfaceItemIdentifier("textCell")
            let view = (table.makeView(withIdentifier: id, owner: nil) as? PlainTextCellView)
                ?? PlainTextCellView(identifier: id)
            view.configure(
                text: text, bold: bold, secondary: secondary,
                alignment: alignment, monospaced: monospaced
            )
            return view
        }
    }
}

// MARK: - NSMenu closure helper

private final class ClosureMenuItem: NSMenuItem {
    let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { handler() }
}

private extension NSMenu {
    func addMenuItem(_ title: String, handler: @escaping () -> Void) {
        addItem(ClosureMenuItem(title: title, handler: handler))
    }
}
