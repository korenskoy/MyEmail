//
//  MailRule.swift
//  MyEmail
//
//  GRDB record for `mail_rules`. Conditions/actions stored as JSON text.
//  Evaluated by RuleEngine against incoming messages.
//

import Foundation
import GRDB

// MARK: - MailRule

struct MailRule: Identifiable, Codable, Hashable, Sendable,
                 FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "mail_rules"

    var id: UUID
    var accountID: UUID?
    var name: String
    var isEnabled: Bool

    /// JSON-encoded `[RuleCondition]`. Decoded/encoded в property-level
    /// init(from:)/encode(to:) через `Self.codingJSONArray`.
    var conditions: [RuleCondition]

    /// JSON-encoded `[RuleAction]`.
    var actions: [RuleAction]

    /// `true` = все conditions должны совпасть (AND), `false` = любое (OR).
    var matchAll: Bool

    var sortOrder: Int

    // MARK: - Thunderbird-aligned triggers + scope (§6.7.1 extension)

    /// Fire when a new message arrives during sync. Default `true`.
    var runOnIncoming: Bool

    /// Allow explicit manual invocation from UI. Default `true`.
    var runOnManual: Bool

    /// Folder paths this rule is scoped to. Empty = "all inbox folders"
    /// (matches legacy behavior — back-compat for rules without scope).
    /// JSON-encoded `[String]`.
    var folderPaths: [String]

    init(
        id: UUID, accountID: UUID?, name: String, isEnabled: Bool,
        conditions: [RuleCondition], actions: [RuleAction],
        matchAll: Bool, sortOrder: Int,
        runOnIncoming: Bool = true, runOnManual: Bool = true,
        folderPaths: [String] = []
    ) {
        self.id = id; self.accountID = accountID; self.name = name
        self.isEnabled = isEnabled; self.conditions = conditions
        self.actions = actions; self.matchAll = matchAll; self.sortOrder = sortOrder
        self.runOnIncoming = runOnIncoming
        self.runOnManual = runOnManual
        self.folderPaths = folderPaths
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case name
        case isEnabled = "is_enabled"
        case conditions
        case actions
        case matchAll = "match_all"
        case sortOrder = "sort_order"
        case runOnIncoming = "run_on_incoming"
        case runOnManual = "run_on_manual"
        case folderPaths = "folder_paths"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID)
        self.name = try c.decode(String.self, forKey: .name)
        self.isEnabled = try c.decode(Bool.self, forKey: .isEnabled)

        let conditionsJSON = try c.decode(String.self, forKey: .conditions)
        self.conditions = Self.decodeJSONArray(conditionsJSON) ?? []

        let actionsJSON = try c.decode(String.self, forKey: .actions)
        self.actions = Self.decodeJSONArray(actionsJSON) ?? []

        self.matchAll = try c.decode(Bool.self, forKey: .matchAll)
        self.sortOrder = try c.decode(Int.self, forKey: .sortOrder)

        // Back-compat defaults: missing columns → true/true/[] so existing
        // rules behave exactly as they did before the trigger/scope model.
        self.runOnIncoming = (try? c.decodeIfPresent(Bool.self, forKey: .runOnIncoming)) ?? true
        self.runOnManual = (try? c.decodeIfPresent(Bool.self, forKey: .runOnManual)) ?? true

        if let json = try? c.decodeIfPresent(String.self, forKey: .folderPaths) {
            self.folderPaths = Self.decodeJSONArray(json) ?? []
        } else {
            self.folderPaths = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(accountID, forKey: .accountID)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(Self.encodeJSONArray(conditions), forKey: .conditions)
        try c.encode(Self.encodeJSONArray(actions), forKey: .actions)
        try c.encode(matchAll, forKey: .matchAll)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(runOnIncoming, forKey: .runOnIncoming)
        try c.encode(runOnManual, forKey: .runOnManual)
        try c.encode(Self.encodeJSONArray(folderPaths), forKey: .folderPaths)
    }

    private static func decodeJSONArray<T: Decodable>(_ raw: String) -> [T]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([T].self, from: data)
    }

    private static func encodeJSONArray<T: Encodable>(_ value: [T]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }
}

// MARK: - RuleCondition

struct RuleCondition: Codable, Hashable, Sendable {
    var field: RuleField
    var predicate: RulePredicate
    var value: String

    enum RuleField: String, Codable, Hashable, Sendable, CaseIterable {
        case from, to, subject, body

        var label: String {
            switch self {
            case .from:    return String(localized: "From")
            case .to:      return String(localized: "To")
            case .subject: return String(localized: "Subject")
            case .body:    return String(localized: "Body")
            }
        }
    }

    enum RulePredicate: String, Codable, Hashable, Sendable, CaseIterable {
        case contains, notContains, equals, startsWith, endsWith

        var label: String {
            switch self {
            case .contains:    return String(localized: "contains")
            case .notContains: return String(localized: "not contains")
            case .equals:      return String(localized: "equals")
            case .startsWith:  return String(localized: "starts with")
            case .endsWith:    return String(localized: "ends with")
            }
        }
    }
}

// MARK: - RuleAction

struct RuleAction: Codable, Hashable, Sendable {
    var type: RuleActionType
    /// For `.rewriteSubject`: regex pattern.
    /// For `.moveToFolder`: target folder path.
    var value: String?
    /// For `.rewriteSubject` only: replacement template (NSRegularExpression
    /// template syntax — `$1`, `$2`, etc.). `nil` = empty string = regex-remove.
    var replacement: String?

    enum RuleActionType: String, Codable, Hashable, Sendable, CaseIterable {
        case moveToFolder, markRead, markFlagged, delete, markJunk, rewriteSubject

        var label: String {
            switch self {
            case .moveToFolder:    return String(localized: "Move to folder")
            case .markRead:        return String(localized: "Mark as read")
            case .markFlagged:     return String(localized: "Mark as flagged")
            case .delete:          return String(localized: "Delete")
            case .markJunk:        return String(localized: "Mark as junk")
            case .rewriteSubject:  return String(localized: "Rewrite subject")
            }
        }
    }
}

// MARK: - Factory

extension MailRule {
    static func makeEmpty() -> MailRule {
        MailRule(
            id: UUID(), accountID: nil, name: String(localized: "New Rule"),
            isEnabled: true,
            conditions: [RuleCondition(field: .from, predicate: .contains, value: "")],
            actions: [RuleAction(type: .markRead, value: nil)],
            matchAll: true, sortOrder: 0
        )
    }
}
