//
//  RuleEngine.swift
//  MyEmail
//
//  Evaluates mail rules against messages.
//  Supports two triggers (incoming / manual) and per-folder scope, aligned
//  with Thunderbird's filter model.
//

import Foundation
import GRDB

/// Context in which a rule is being evaluated. Mirrors TB filter types.
enum RuleTrigger: Sendable {
    /// Fired by sync when a new message arrives.
    case incoming
    /// Fired explicitly by the user (Run Filters on Folder / Selection).
    case manual
}

struct RuleEngine: Sendable {
    let pool: DatabasePool

    nonisolated init(pool: DatabasePool = DatabaseService.shared.pool) {
        self.pool = pool
    }

    // MARK: - Evaluate rules for a message

    /// Filter ordered, enabled rules for a given message + folder + trigger.
    /// Folder scope rules:
    ///   - `folderPaths.isEmpty` → legacy "all inbox folders" (back-compat).
    ///   - otherwise → `folder.path` must be in `folderPaths`.
    /// Trigger rules:
    ///   - `.incoming` → rule.runOnIncoming
    ///   - `.manual`   → rule.runOnManual
    nonisolated func matchingRules(
        for item: MessageListItem,
        bodyText: String?,
        folder: Folder,
        accountID: UUID,
        trigger: RuleTrigger
    ) -> [MailRule] {
        let rules: [MailRule] = (try? pool.read { db in
            try MailRule
                .filter(Column("is_enabled") == true)
                .filter(Column("account_id") == accountID || Column("account_id") == nil)
                .order(Column("sort_order"))
                .fetchAll(db)
        }) ?? []

        return rules.filter { rule in
            triggerAllowed(rule, trigger: trigger)
                && scopeMatches(rule, folder: folder)
                && matches(rule: rule, item: item, bodyText: bodyText)
        }
    }

    // MARK: - Match logic

    nonisolated func matches(
        rule: MailRule,
        item: MessageListItem,
        bodyText: String?
    ) -> Bool {
        let results = rule.conditions.map { condition in
            evaluateCondition(condition, item: item, bodyText: bodyText)
        }
        return rule.matchAll
            ? results.allSatisfy { $0 }
            : results.contains { $0 }
    }

    // MARK: - Trigger / scope predicates

    private nonisolated func triggerAllowed(_ rule: MailRule, trigger: RuleTrigger) -> Bool {
        switch trigger {
        case .incoming: return rule.runOnIncoming
        case .manual:   return rule.runOnManual
        }
    }

    /// Empty scope = "all inbox folders" (legacy behavior).
    /// Non-empty scope = exact path match against this folder.
    private nonisolated func scopeMatches(_ rule: MailRule, folder: Folder) -> Bool {
        if rule.folderPaths.isEmpty {
            return folder.specialUse == .inbox
        }
        return rule.folderPaths.contains(folder.path)
    }

    private nonisolated func evaluateCondition(
        _ condition: RuleCondition,
        item: MessageListItem,
        bodyText: String?
    ) -> Bool {
        let fieldValue: String
        switch condition.field {
        case .from:
            fieldValue = item.fromAddress
        case .to:
            fieldValue = item.toAddresses.joined(separator: " ")
        case .subject:
            fieldValue = item.subject
        case .body:
            fieldValue = bodyText ?? ""
        }

        let needle = condition.value.lowercased()
        let haystack = fieldValue.lowercased()

        switch condition.predicate {
        case .contains:
            return haystack.contains(needle)
        case .notContains:
            return !haystack.contains(needle)
        case .equals:
            return haystack == needle
        case .startsWith:
            return haystack.hasPrefix(needle)
        case .endsWith:
            return haystack.hasSuffix(needle)
        }
    }
}
