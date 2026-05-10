//
//  RecentSearchesStore.swift
//  MyEmail
//
//  Persist last N raw search strings in UserDefaults. Dedupes and re-orders
//  on save (most recent first). Empty strings are ignored.
//

import Foundation

@MainActor
final class RecentSearchesStore {
    static let shared = RecentSearchesStore()

    private let key = "MyEmail.RecentSearches"
    private let maxEntries = 10

    private init() {}

    func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func save(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        var list = load()
        // Dedupe case-insensitively, then push to front.
        list.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > maxEntries { list = Array(list.prefix(maxEntries)) }
        UserDefaults.standard.set(list, forKey: key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
