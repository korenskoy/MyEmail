//
//  MessageSort.swift
//  MyEmail
//
//  Session-scoped sort descriptor for the message list. Persists only
//  while a folder is selected — sidebar selection change resets to
//  `.default` (date DESC) so each folder opens in its natural order.
//

import Foundation

struct MessageSort: Equatable, Sendable {
    enum Column: String, Sendable {
        case fromTo
        case subject
        case date
        case size
    }

    enum Order: Sendable {
        case asc
        case desc

        var ascending: Bool { self == .asc }

        mutating func toggle() { self = (self == .asc) ? .desc : .asc }
    }

    var column: Column
    var order: Order

    static let `default` = MessageSort(column: .date, order: .desc)
}

extension Array where Element == MessageListItem {
    /// Sort messages by the given descriptor. `isSentOrDrafts` switches the
    /// fromTo column between `displayFrom` and `displayTo`. Secondary key is
    /// always date DESC, then UUID — guarantees stable order on ties.
    func sorted(by sort: MessageSort, isSentOrDrafts: Bool) -> [MessageListItem] {
        let ascending = sort.order.ascending
        return sorted { lhs, rhs in
            let primary: ComparisonResult
            switch sort.column {
            case .fromTo:
                let a = isSentOrDrafts ? lhs.displayTo : lhs.displayFrom
                let b = isSentOrDrafts ? rhs.displayTo : rhs.displayFrom
                primary = a.localizedCaseInsensitiveCompare(b)
            case .subject:
                primary = lhs.subject.localizedCaseInsensitiveCompare(rhs.subject)
            case .date:
                primary = compareValues(lhs.date, rhs.date)
            case .size:
                primary = compareValues(lhs.size, rhs.size)
            }

            if primary != .orderedSame {
                return ascending
                    ? primary == .orderedAscending
                    : primary == .orderedDescending
            }

            // Stable tiebreaker: always most-recent first, then id.
            let byDate = compareValues(rhs.date, lhs.date)
            if byDate != .orderedSame {
                return byDate == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

private func compareValues<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    if a < b { return .orderedAscending }
    if a > b { return .orderedDescending }
    return .orderedSame
}
