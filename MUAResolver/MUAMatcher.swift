//
//  MUAMatcher.swift
//  MUAResolver (XPC Service)
//
//  Swift port of `scripts/dispmua-common.js` from the dispmua Thunderbird
//  extension (https://github.com/Toshi-CMCC/display-mail-user-agent-t).
//
//  Copyright (C) 2007       Jürgen Ernst
//  Copyright (C) 2020-2024  Toshi_ <dispmua@outlook.com>
//  Copyright (C) 2025       MyEmail project (Swift port)
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0>.
//

import Foundation

struct MUAInfo {
    let iconName: String
    let displayName: String?
}

enum MUAMatcher {

    /// Resolve an icon for a mail-client `User-Agent` / `X-Mailer` value.
    /// Returns nil when the client is unknown — caller keeps the UI slot empty.
    static func match(userAgent raw: String) -> MUAInfo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Yahoo! Mail prefix noise — "WebService/1.2.3 Foo/1.0" → strip leading WebService.
        let normalized = Self.stripWebServicePrefix(trimmed)
        let lower = normalized.lowercased()

        // 0) Own client: "MyEmail/1.0 (macOS/Silicon)" — not in upstream DB.
        if lower.hasPrefix("myemail/") {
            return MUAInfo(iconName: "mymail.png", displayName: "MyEmail")
        }

        let db = Self.database
        // 1) fullmatch — exact string equality.
        if let hit = db.fullmatch[lower] {
            return info(from: hit)
        }
        // 2) presearch — substring match (upstream: indexOf > -1).
        for (needle, hit) in db.presearch where lower.contains(needle) {
            return info(from: hit)
        }
        // 3) letter section — prefix match by first character of UA.
        if let first = lower.first, let section = db.sections[first] {
            for (needle, hit) in section where lower.hasPrefix(needle) {
                return info(from: hit)
            }
        }
        // 4) postsearch — substring match, last resort.
        for (needle, hit) in db.postsearch where lower.contains(needle) {
            return info(from: hit)
        }
        return nil
    }

    // MARK: - Private

    private static func info(from entry: [String]) -> MUAInfo? {
        guard let icon = entry.first, !icon.isEmpty else { return nil }
        // entry = [iconName, homepageURL, displayName?]
        let display = entry.count > 2 ? entry[2] : nil
        return MUAInfo(iconName: icon, displayName: display)
    }

    private static func stripWebServicePrefix(_ s: String) -> String {
        // Matches "WebService/1.2.3 " at the start (case-insensitive).
        let pattern = #"^[Ww]eb[Ss]ervice/[0-9. ]+"#
        guard let range = s.range(of: pattern, options: .regularExpression) else { return s }
        return String(s[range.upperBound...])
    }

    // MARK: - Database (lazy, loaded once per XPC process)

    fileprivate static let database: MUADatabase = MUADatabase.loadBundled()
}

// MARK: - Database

struct MUADatabase {
    /// Exact string match. Order doesn't matter.
    let fullmatch: [String: [String]]
    /// Substring search. Sorted by key length DESC so specific rules beat generic ones.
    let presearch: [(String, [String])]
    /// Prefix match by first character of UA. Same ordering as presearch.
    let sections: [Character: [(String, [String])]]
    /// Substring search, last resort.
    let postsearch: [(String, [String])]

    static func loadBundled() -> MUADatabase {
        guard let url = Bundle.main.url(forResource: "mua-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return MUADatabase(fullmatch: [:], presearch: [], sections: [:], postsearch: [])
        }
        do {
            return try JSONDecoder().decode(MUADatabase.self, from: data)
        } catch {
            // XPC process has no host logger; stderr is captured by launchd.
            FileHandle.standardError.write(Data("MUADatabase decode failed: \(error)\n".utf8))
            return MUADatabase(fullmatch: [:], presearch: [], sections: [:], postsearch: [])
        }
    }
}

// Top-level JSON has mixed keys (fullmatch / presearch / postsearch + a..z + symbol
// and header-fallback keys). Decode manually via AnyCodingKey.
extension MUADatabase: Decodable {
    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var fullmatch: [String: [String]] = [:]
        var presearch: [(String, [String])] = []
        var postsearch: [(String, [String])] = []
        var sections: [Character: [(String, [String])]] = [:]

        // Header-fallback sections (used when UA is empty in the upstream extension).
        // Out of scope for V1 — skip explicitly to avoid treating them as char sections.
        let headerFallbackKeys: Set<String> = [
            "dkim-signature", "message-id", "organization",
            "x-clientproxiedby", "x-mimeole",
        ]

        for key in container.allKeys {
            let name = key.stringValue
            if headerFallbackKeys.contains(name) { continue }

            let dict: [String: [String]]
            do {
                dict = try container.decode([String: [String]].self, forKey: key)
            } catch {
                continue  // Skip malformed sections.
            }

            switch name {
            case "fullmatch":
                fullmatch = dict
            case "presearch":
                presearch = Self.sortedByLengthDesc(dict)
            case "postsearch":
                postsearch = Self.sortedByLengthDesc(dict)
            default:
                // Single-character section — letter or symbol.
                if let first = name.first, name.count == 1 {
                    sections[first] = Self.sortedByLengthDesc(dict)
                }
            }
        }

        self.fullmatch = fullmatch
        self.presearch = presearch
        self.postsearch = postsearch
        self.sections = sections
    }

    /// Longest keys first — a "thunderbird/128.0" rule must beat the broader "thunderbird".
    private static func sortedByLengthDesc(_ dict: [String: [String]]) -> [(String, [String])] {
        dict.sorted { lhs, rhs in lhs.key.count > rhs.key.count }
            .map { ($0.key, $0.value) }
    }
}
