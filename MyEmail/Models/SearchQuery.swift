//
//  SearchQuery.swift
//  MyEmail
//
//  Parsed search query. Value type, Sendable, nonisolated (§8.1).
//  Supported operators:
//    from:   multi-value (repeat or comma-separated)
//    to:     multi-value
//    cc:     multi-value
//    bcc:    multi-value
//    subject:
//    body:
//    list:   mailing-list id substring
//    in:     folder name (local-only filter)
//    before: date  (YYYY-MM-DD, YYYY/MM/DD, or relative d/w/m/y like 7d)
//    after:  date
//    larger: size (supports K/M/G suffix — 5M = 5 MiB)
//    smaller:size
//    is:     unread|read|flagged|unflagged
//    has:    attachment|noattachment
//    -term   exclude term from freetext
//    "exact phrase"  phrase match
//

import Foundation

struct SearchQuery: Sendable, Equatable {
    // Freetext tokens and their modifiers
    nonisolated var freetext: [String]        // required AND tokens
    nonisolated var phrases: [String]          // exact-phrase match
    nonisolated var excludes: [String]         // NOT-tokens (plain words)

    // Field operators (multi-value where applicable)
    nonisolated var from: [String]
    nonisolated var to: [String]
    nonisolated var cc: [String]
    nonisolated var bcc: [String]
    nonisolated var subject: String?
    nonisolated var body: String?
    nonisolated var listID: String?
    nonisolated var folderName: String?

    // Negated field operators: -from:spam, -subject:foo
    nonisolated var excludeFrom: [String]
    nonisolated var excludeTo: [String]
    nonisolated var excludeCc: [String]
    nonisolated var excludeBcc: [String]
    nonisolated var excludeSubject: [String]
    nonisolated var excludeBody: [String]

    // Date / size
    nonisolated var before: Date?
    nonisolated var after: Date?
    nonisolated var largerThan: Int?
    nonisolated var smallerThan: Int?

    // Flag / attachment
    nonisolated var isFilter: IsFilter?
    nonisolated var hasFilter: HasFilter?

    nonisolated var isEmpty: Bool {
        freetext.isEmpty && phrases.isEmpty && excludes.isEmpty
            && from.isEmpty && to.isEmpty && cc.isEmpty && bcc.isEmpty
            && subject == nil && body == nil && listID == nil && folderName == nil
            && before == nil && after == nil
            && largerThan == nil && smallerThan == nil
            && isFilter == nil && hasFilter == nil
            && excludeFrom.isEmpty && excludeTo.isEmpty
            && excludeCc.isEmpty && excludeBcc.isEmpty
            && excludeSubject.isEmpty && excludeBody.isEmpty
    }

    /// Single freetext string joined by space (for IMAP SEARCH TEXT).
    nonisolated var freetextJoined: String? {
        let all = freetext + phrases
        guard !all.isEmpty else { return nil }
        return all.joined(separator: " ")
    }

    nonisolated init(
        freetext: [String] = [],
        phrases: [String] = [],
        excludes: [String] = [],
        from: [String] = [],
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String? = nil,
        body: String? = nil,
        listID: String? = nil,
        folderName: String? = nil,
        before: Date? = nil,
        after: Date? = nil,
        largerThan: Int? = nil,
        smallerThan: Int? = nil,
        isFilter: IsFilter? = nil,
        hasFilter: HasFilter? = nil,
        excludeFrom: [String] = [],
        excludeTo: [String] = [],
        excludeCc: [String] = [],
        excludeBcc: [String] = [],
        excludeSubject: [String] = [],
        excludeBody: [String] = []
    ) {
        self.freetext = freetext
        self.phrases = phrases
        self.excludes = excludes
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.listID = listID
        self.folderName = folderName
        self.before = before
        self.after = after
        self.largerThan = largerThan
        self.smallerThan = smallerThan
        self.isFilter = isFilter
        self.hasFilter = hasFilter
        self.excludeFrom = excludeFrom
        self.excludeTo = excludeTo
        self.excludeCc = excludeCc
        self.excludeBcc = excludeBcc
        self.excludeSubject = excludeSubject
        self.excludeBody = excludeBody
    }

    enum IsFilter: String, Sendable, Equatable {
        case unread, read, flagged, unflagged
    }

    enum HasFilter: String, Sendable, Equatable {
        case attachment, noattachment
    }
}

// MARK: - Pre-lowered variant for client-side matching (§9.4)

struct LoweredSearchQuery: Sendable {
    nonisolated let from: [String]
    nonisolated let to: [String]
    nonisolated let cc: [String]
    nonisolated let bcc: [String]
    nonisolated let subject: String?
    nonisolated let body: String?
    nonisolated let listID: String?
    nonisolated let phrases: [String]
    nonisolated let excludes: [String]
    nonisolated let excludeFrom: [String]
    nonisolated let excludeTo: [String]
    nonisolated let excludeCc: [String]
    nonisolated let excludeBcc: [String]
    nonisolated let excludeSubject: [String]
    nonisolated let excludeBody: [String]
    nonisolated let before: Date?
    nonisolated let after: Date?
    nonisolated let largerThan: Int?
    nonisolated let smallerThan: Int?
    nonisolated let isFilter: SearchQuery.IsFilter?
    nonisolated let hasFilter: SearchQuery.HasFilter?

    nonisolated init(_ query: SearchQuery) {
        self.from = query.from.map { $0.lowercased() }
        self.to = query.to.map { $0.lowercased() }
        self.cc = query.cc.map { $0.lowercased() }
        self.bcc = query.bcc.map { $0.lowercased() }
        self.subject = query.subject?.lowercased()
        self.body = query.body?.lowercased()
        self.listID = query.listID?.lowercased()
        self.phrases = query.phrases.map { $0.lowercased() }
        self.excludes = query.excludes.map { $0.lowercased() }
        self.excludeFrom = query.excludeFrom.map { $0.lowercased() }
        self.excludeTo = query.excludeTo.map { $0.lowercased() }
        self.excludeCc = query.excludeCc.map { $0.lowercased() }
        self.excludeBcc = query.excludeBcc.map { $0.lowercased() }
        self.excludeSubject = query.excludeSubject.map { $0.lowercased() }
        self.excludeBody = query.excludeBody.map { $0.lowercased() }
        self.before = query.before
        self.after = query.after
        self.largerThan = query.largerThan
        self.smallerThan = query.smallerThan
        self.isFilter = query.isFilter
        self.hasFilter = query.hasFilter
    }

    nonisolated var hasAnyClientFilter: Bool {
        !from.isEmpty || !to.isEmpty || !cc.isEmpty || !bcc.isEmpty
            || subject != nil || body != nil || listID != nil
            || !phrases.isEmpty || !excludes.isEmpty
            || !excludeFrom.isEmpty || !excludeTo.isEmpty
            || !excludeCc.isEmpty || !excludeBcc.isEmpty
            || !excludeSubject.isEmpty || !excludeBody.isEmpty
            || before != nil || after != nil
            || largerThan != nil || smallerThan != nil
            || isFilter != nil || hasFilter != nil
    }
}

// MARK: - SearchScope

enum SearchScope: Sendable, Equatable, Hashable, Identifiable {
    case currentFolder
    case currentAccount
    case allAccounts

    nonisolated var id: String {
        switch self {
        case .currentFolder: "folder"
        case .currentAccount: "account"
        case .allAccounts: "all"
        }
    }
}
