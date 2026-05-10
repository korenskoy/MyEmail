//
//  ContactsService.swift
//  MyEmail
//
//  CNContactStore + RecipientHistory ranking for autocomplete (§6.5).
//  Sources: #1 RecipientHistory (by useCount + recency), #2 system Contacts.
//  Cap: 500 history entries, dedup by email.
//

import Contacts
import Foundation
import GRDB

struct RecipientSuggestion: Identifiable, Hashable, Sendable {
    let id: String // email
    let email: String
    let name: String?
}

@MainActor
final class ContactsService {
    static let shared = ContactsService()

    private let store = CNContactStore()
    private let pool = DatabaseService.shared.pool

    private init() {}

    // MARK: - Autocomplete

    /// Returns up to `limit` suggestions matching `query` (prefix match on email or name).
    func suggestions(for query: String, limit: Int = 10) -> [RecipientSuggestion] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }

        var seen = Set<String>()
        var results: [RecipientSuggestion] = []

        // Source #1: RecipientHistory (ranked by useCount DESC, lastUsed DESC)
        let history: [RecipientHistory] = (try? pool.read { db in
            try RecipientHistory
                .order(Column("use_count").desc, Column("last_used").desc)
                .limit(500)
                .fetchAll(db)
        }) ?? []

        for entry in history {
            let email = entry.email.lowercased()
            let name = entry.name?.lowercased() ?? ""
            if email.contains(needle) || name.contains(needle) {
                if seen.insert(entry.email.lowercased()).inserted {
                    results.append(RecipientSuggestion(
                        id: entry.email, email: entry.email, name: entry.name
                    ))
                }
            }
            if results.count >= limit { return results }
        }

        // Source #2: CNContactStore (system contacts)
        if results.count < limit {
            let contacts = fetchContacts(matching: query)
            for contact in contacts {
                for emailValue in contact.emailAddresses {
                    let email = emailValue.value as String
                    if seen.insert(email.lowercased()).inserted {
                        let fullName = CNContactFormatter.string(from: contact, style: .fullName)
                        results.append(RecipientSuggestion(
                            id: email, email: email, name: fullName
                        ))
                    }
                    if results.count >= limit { return results }
                }
            }
        }

        return results
    }

    // MARK: - CNContacts

    private func fetchContacts(matching query: String) -> [CNContact] {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return [] }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]

        let predicate = CNContact.predicateForContacts(matchingName: query)
        return (try? store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)) ?? []
    }
}
