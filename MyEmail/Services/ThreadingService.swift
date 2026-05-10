//
//  ThreadingService.swift
//  MyEmail
//
//  JWZ threading algorithm (RFC 5256 THREAD=REFERENCES).
//  Builds thread trees from References + In-Reply-To headers,
//  falls back to threadID grouping when headers are absent.
//  Pure value-type computation — no actor, no state.
//

import Foundation

// MARK: - Thread group

struct ThreadGroup: Identifiable, Sendable {
    /// ID of the thread root (earliest message).
    let id: UUID
    /// All messages in the thread, ordered by date ascending.
    let messages: [MessageListItem]
    /// Latest message (shown in collapsed mode).
    var latest: MessageListItem { messages.last! }
    var count: Int { messages.count }
    var date: Date { latest.date }
}

// MARK: - ThreadingService

enum ThreadingService {

    // MARK: - JWZ container

    /// Mutable container used during tree construction. Each container
    /// corresponds to a Message-ID (real or placeholder for unseen refs).
    private final class Container {
        var messageID: String
        var item: MessageListItem?
        var parent: Container?
        var children: [Container] = []

        init(messageID: String, item: MessageListItem? = nil) {
            self.messageID = messageID
            self.item = item
        }
    }

    /// Group flat message list into threads using JWZ algorithm.
    /// Falls back to threadID grouping for messages without References/In-Reply-To.
    /// Returns threads sorted by latest message date descending.
    nonisolated static func group(_ items: [MessageListItem]) -> [ThreadGroup] {
        guard !items.isEmpty else { return [] }

        // Step 1: Build ID table — one Container per unique Message-ID
        var idTable: [String: Container] = [:]

        func findOrCreate(_ mid: String) -> Container {
            if let existing = idTable[mid] { return existing }
            let container = Container(messageID: mid)
            idTable[mid] = container
            return container
        }

        // Step 2: For each message, populate container and link References chain
        for item in items {
            let mid = item.messageID ?? item.id.uuidString
            let container = findOrCreate(mid)
            container.item = item

            // Build References chain (includes In-Reply-To as last element if not already present)
            var refIDs = item.references
            if let irt = item.inReplyTo, !irt.isEmpty, !refIDs.contains(irt) {
                refIDs.append(irt)
            }

            // Link parent→child along the References chain
            var prev: Container?
            for refID in refIDs {
                let refContainer = findOrCreate(refID)
                if let prevContainer = prev,
                   refContainer.parent == nil,
                   !isAncestor(refContainer, of: prevContainer) {
                    refContainer.parent = prevContainer
                    prevContainer.children.append(refContainer)
                }
                prev = refContainer
            }

            // Link the message itself as child of the last reference
            if let lastRef = prev, lastRef !== container {
                if container.parent == nil && !isAncestor(container, of: lastRef) {
                    container.parent = lastRef
                    lastRef.children.append(container)
                }
            }
        }

        // Step 3: Fall back to threadID grouping for orphans without References
        var threadIDGroups: [String: [Container]] = [:]
        for (_, container) in idTable {
            guard container.item != nil else { continue }
            if container.parent == nil,
               let tid = container.item?.threadID, !tid.isEmpty {
                threadIDGroups[tid, default: []].append(container)
            }
        }

        // Link threadID siblings under a common root
        for (_, group) in threadIDGroups where group.count > 1 {
            let sorted = group.sorted {
                ($0.item?.date ?? .distantPast) < ($1.item?.date ?? .distantPast)
            }
            let root = sorted[0]
            for i in 1..<sorted.count {
                let child = sorted[i]
                if child.parent == nil && !isAncestor(child, of: root) {
                    child.parent = root
                    root.children.append(child)
                }
            }
        }

        // Step 4: Find root set (containers with no parent)
        // Phase 1: Promote children of empty placeholder containers.
        // Must be a separate pass — mutating child.parent during
        // dictionary iteration causes duplicates (non-deterministic order).
        for (_, container) in idTable where container.parent == nil && container.item == nil {
            for child in container.children {
                child.parent = nil
            }
        }
        // Phase 2: Collect actual roots (has item, no parent)
        var roots: [Container] = []
        for (_, container) in idTable where container.parent == nil && container.item != nil {
            roots.append(container)
        }

        // Step 5: Flatten each root into a ThreadGroup
        var result: [ThreadGroup] = []

        for root in roots {
            var flat: [MessageListItem] = []
            collectItems(root, into: &flat)
            guard !flat.isEmpty else { continue }
            flat.sort { $0.date < $1.date }
            result.append(ThreadGroup(id: flat.first!.id, messages: flat))
        }

        result.sort { $0.date > $1.date }
        return result
    }

    // MARK: - Helpers

    /// Cycle detection: returns true if `candidate` is an ancestor of `node`.
    private static func isAncestor(_ candidate: Container, of node: Container) -> Bool {
        var cursor: Container? = node.parent
        while let ancestor = cursor {
            if ancestor === candidate { return true }
            cursor = ancestor.parent
        }
        return false
    }

    /// Depth-first traversal collecting all items from a container subtree.
    private static func collectItems(_ container: Container, into result: inout [MessageListItem]) {
        if let item = container.item {
            result.append(item)
        }
        for child in container.children {
            collectItems(child, into: &result)
        }
    }
}
