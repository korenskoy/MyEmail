//
//  MessageMatcher.swift
//  MyEmail
//
//  Client-side residual filters for search. SQL/FTS handles most work;
//  this catches what SQL cannot express precisely:
//    - multi-value OR semantics on from/to/cc/bcc with substring match
//      across BOTH display name and address
//    - phrase match across multi-value address arrays
//    - explicit excludes that can't be safely NOT'ed in FTS (e.g. operator
//      exclusions stored as "key:value" tokens)
//
//  Nonisolated value type (§8.1). Accepts MessageListItem — no body access.
//

import Foundation

enum MessageMatcher {

    nonisolated static func matches(
        _ item: MessageListItem,
        query: LoweredSearchQuery
    ) -> Bool {
        // --- Address-list operators (OR across values, substring match) ---
        // Haystacks built lazily — skip work when no address-list filter exists.
        let needsFromHaystack = !query.from.isEmpty || !query.excludeFrom.isEmpty
        let needsToHaystack = !query.to.isEmpty || !query.excludeTo.isEmpty

        if needsFromHaystack {
            let fromHaystack = ((item.fromName ?? "") + " " + item.fromAddress).lowercased()
            if !query.from.isEmpty,
               !query.from.contains(where: fromHaystack.contains) { return false }
            if query.excludeFrom.contains(where: fromHaystack.contains) { return false }
        }
        if needsToHaystack {
            let toHaystack = item.toAddresses.joined(separator: " ").lowercased()
            if !query.to.isEmpty,
               !query.to.contains(where: toHaystack.contains) { return false }
            if query.excludeTo.contains(where: toHaystack.contains) { return false }
        }
        // cc/bcc not in MessageListItem projection — FTS MATCH already filtered.

        // --- Subject substring ---
        let loweredSubject = item.subject.lowercased()
        if let subject = query.subject {
            if !loweredSubject.contains(subject) { return false }
        }
        // --- Negated subject (exclude) ---
        if query.excludeSubject.contains(where: loweredSubject.contains) { return false }

        // --- Phrase match: require each phrase in subject OR from OR to ---
        if !query.phrases.isEmpty || !query.excludes.isEmpty {
            let fromName = item.fromName ?? ""
            let toJoined = item.toAddresses.joined(separator: " ")
            let combined = [
                item.subject, fromName, item.fromAddress, toJoined,
            ].joined(separator: " ").lowercased()

            for phrase in query.phrases where !combined.contains(phrase) {
                return false
            }
            for token in query.excludes where combined.contains(token) {
                return false
            }
        }

        // --- Flags ---
        if let isFilter = query.isFilter {
            switch isFilter {
            case .unread:    if item.isRead { return false }
            case .read:      if !item.isRead { return false }
            case .flagged:   if !item.isFlagged { return false }
            case .unflagged: if item.isFlagged { return false }
            }
        }
        if let hasFilter = query.hasFilter {
            switch hasFilter {
            case .attachment:   if !item.hasAttachments { return false }
            case .noattachment: if item.hasAttachments { return false }
            }
        }

        // --- Date range (SQL-level check is authoritative; duplicate defense) ---
        if let before = query.before, item.date >= before { return false }
        if let after = query.after, item.date < after { return false }

        // --- Size (same — defense in depth) ---
        if let larger = query.largerThan, item.size <= larger { return false }
        if let smaller = query.smallerThan, item.size >= smaller { return false }

        return true
    }
}
