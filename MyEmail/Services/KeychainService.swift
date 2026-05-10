//
//  KeychainService.swift
//  MyEmail
//
//  Wrapper over Security framework for OAuth tokens and account passwords.
//
//  ВАЖНО (§8, hard rule 17): `kSecAttrAccessibleAfterFirstUnlock`, не
//  `WhenUnlocked` — иначе IDLE на залоченной машине умрёт, поскольку Keychain
//  станет недоступен и фоновой refresh токенов сломается.
//
//  Всё здесь `nonisolated`: сервис зовётся и с MainActor, и из actor-изолированных
//  `IMAPService`/`SMTPService`/`AuthService`. Никаких main-hops.
//

import Foundation
import Security

enum KeychainError: Error, Sendable {
    case itemNotFound
    case duplicateItem
    case invalidData
    case unexpectedStatus(OSStatus)
}

/// Thin CRUD over `SecItem*` with a fixed service prefix.
struct KeychainService: Sendable {
    static let shared = KeychainService(service: "ru.korenskoy.MyEmail")

    let service: String

    // MARK: - Set

    nonisolated func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        try set(data, for: account)
    }

    nonisolated func set(_ data: Data, for account: String) throws {
        let base = baseQuery(for: account)

        // Update path first — if the item exists we atomically replace the value.
        let attrsToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attrsToUpdate as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            // Fall through to add.
            break
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = base
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw KeychainError.duplicateItem
        default:
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    // MARK: - Get

    nonisolated func getString(for account: String) throws -> String {
        let data = try getData(for: account)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return string
    }

    nonisolated func getData(for account: String) throws -> Data {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.invalidData
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Delete

    nonisolated func delete(for account: String) throws {
        let query = baseQuery(for: account)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Private

    private nonisolated func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
