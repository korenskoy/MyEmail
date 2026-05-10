//
//  Signature.swift
//  MyEmail
//
//  GRDB record для `signatures`. Signature swap при смене `From` в compose
//  (см. M7).
//

import Foundation
import GRDB

struct Signature: Identifiable, Codable, Hashable, Sendable,
                  FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "signatures"

    var id: UUID
    var accountID: UUID
    var name: String
    var body: String
    var isHTML: Bool
    var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case name
        case body
        case isHTML = "is_html"
        case isDefault = "is_default"
    }
}
