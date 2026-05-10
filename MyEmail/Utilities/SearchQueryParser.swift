//
//  SearchQueryParser.swift
//  MyEmail
//
//  Tokenizer + state-machine parser for search bar input.
//  Grammar:
//    term            := word | quoted | negation | operator_expr
//    negation        := "-" word | "-" quoted | "-" operator_expr
//    quoted          := "\"" .* "\""
//    operator_expr   := key ":" value
//    key             := from|to|cc|bcc|subject|body|list|in|before|after|
//                       larger|smaller|is|has
//    value           := word | quoted
//
//  Multi-value operators (from/to/cc/bcc) accept repetition and
//  comma-separated lists. `from:alice,bob from:carol` → [alice, bob, carol].
//

import Foundation

enum SearchQueryParser {

    nonisolated static let knownOperators: Set<String> = [
        "from", "to", "cc", "bcc",
        "subject", "body", "list", "in",
        "before", "after", "larger", "smaller",
        "is", "has",
    ]

    /// Parse raw search text into a structured SearchQuery.
    nonisolated static func parse(_ raw: String) -> SearchQuery {
        let tokens = tokenize(raw)
        var q = SearchQuery()

        for token in tokens {
            switch token {
            case .word(let value, let negated):
                if negated { q.excludes.append(value) }
                else { q.freetext.append(value) }
            case .phrase(let value, let negated):
                if negated { q.excludes.append(value) }
                else { q.phrases.append(value) }
            case .op(let key, let value, let negated):
                apply(key: key, value: value, negated: negated, to: &q)
            }
        }

        return q
    }

    // MARK: - Apply operator

    nonisolated private static func apply(
        key: String, value: String, negated: Bool, to q: inout SearchQuery
    ) {
        if negated {
            // Negated field operators map to typed exclude lists so we can emit
            // proper `NOT col:value` in FTS5 MATCH and `.not(.from(...))` on the
            // server. Unknown keys drop into plain excludes for safety.
            switch key {
            case "from": q.excludeFrom.append(contentsOf: splitCSV(value))
            case "to": q.excludeTo.append(contentsOf: splitCSV(value))
            case "cc": q.excludeCc.append(contentsOf: splitCSV(value))
            case "bcc": q.excludeBcc.append(contentsOf: splitCSV(value))
            case "subject": q.excludeSubject.append(value)
            case "body": q.excludeBody.append(value)
            default: q.excludes.append("\(key):\(value)")
            }
            return
        }

        let lowered = value.lowercased()
        switch key {
        case "from": q.from.append(contentsOf: splitCSV(value))
        case "to": q.to.append(contentsOf: splitCSV(value))
        case "cc": q.cc.append(contentsOf: splitCSV(value))
        case "bcc": q.bcc.append(contentsOf: splitCSV(value))
        case "subject": q.subject = value
        case "body": q.body = value
        case "list": q.listID = lowered
        case "in": q.folderName = value
        case "before": q.before = parseDate(value)
        case "after": q.after = parseDate(value)
        case "larger": q.largerThan = parseSize(value)
        case "smaller": q.smallerThan = parseSize(value)
        case "is": q.isFilter = SearchQuery.IsFilter(rawValue: lowered)
        case "has": q.hasFilter = SearchQuery.HasFilter(rawValue: lowered)
        default: break
        }
    }

    nonisolated private static func splitCSV(_ value: String) -> [String] {
        value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    // MARK: - Date parsing

    /// Parse absolute `YYYY-MM-DD` / `YYYY/MM/DD` or relative `7d`/`2w`/`3m`/`1y`.
    nonisolated static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Relative: "Nd", "Nw", "Nm", "Ny"
        if let last = trimmed.last,
           "dwmy".contains(last),
           let n = Int(trimmed.dropLast()), n > 0 {
            let cal = Calendar(identifier: .gregorian)
            let component: Calendar.Component = switch last {
            case "d": .day
            case "w": .weekOfYear
            case "m": .month
            default: .year
            }
            return cal.date(byAdding: component, value: -n, to: Date())
        }

        // Absolute formats.
        let formats = ["yyyy-MM-dd", "yyyy/MM/dd", "dd.MM.yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for fmt in formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: trimmed) { return d }
        }
        return nil
    }

    // MARK: - Size parsing

    /// Parse `5M`, `100k`, `2G`, `1024` (bytes). Case-insensitive.
    nonisolated static func parseSize(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        guard let last = s.last else { return nil }

        let multiplier: Int
        let digitsPart: String

        switch last {
        case "k": multiplier = 1024; digitsPart = String(s.dropLast())
        case "m": multiplier = 1024 * 1024; digitsPart = String(s.dropLast())
        case "g": multiplier = 1024 * 1024 * 1024; digitsPart = String(s.dropLast())
        default: multiplier = 1; digitsPart = s
        }

        guard let n = Double(digitsPart), n >= 0 else { return nil }
        return Int(n * Double(multiplier))
    }

    // MARK: - Tokenizer

    private enum Token {
        case word(String, negated: Bool)
        case phrase(String, negated: Bool)
        case op(key: String, value: String, negated: Bool)
    }

    /// Split input respecting quotes. `from:"Anton K" -spam "hello world"` →
    ///  [.op("from", "Anton K", false), .word("spam", true), .phrase("hello world", false)]
    nonisolated private static func tokenize(_ raw: String) -> [Token] {
        var tokens: [Token] = []
        var cursor = raw.startIndex
        let end = raw.endIndex

        while cursor < end {
            // Skip leading whitespace.
            while cursor < end, raw[cursor].isWhitespace {
                cursor = raw.index(after: cursor)
            }
            guard cursor < end else { break }

            // Negation prefix.
            var negated = false
            if raw[cursor] == "-" {
                let next = raw.index(after: cursor)
                if next < end, !raw[next].isWhitespace {
                    negated = true
                    cursor = next
                }
            }

            // Try operator: read until ':' within a contiguous non-whitespace run,
            // but only commit to operator-parse if the colon appears before any quote.
            let runStart = cursor
            var colonIdx: String.Index?
            var runCursor = cursor
            while runCursor < end, !raw[runCursor].isWhitespace {
                if raw[runCursor] == ":" && colonIdx == nil {
                    colonIdx = runCursor
                    break
                }
                if raw[runCursor] == "\"" { break }
                runCursor = raw.index(after: runCursor)
            }

            if let colon = colonIdx {
                let key = String(raw[runStart..<colon]).lowercased()
                if knownOperators.contains(key) {
                    cursor = raw.index(after: colon)
                    let (value, advance) = readValue(raw, from: cursor, end: end)
                    cursor = advance
                    if !value.isEmpty {
                        tokens.append(.op(key: key, value: value, negated: negated))
                    }
                    continue
                }
            }

            // Not a recognized operator — read as phrase or word.
            if cursor < end, raw[cursor] == "\"" {
                let (value, advance) = readQuoted(raw, from: cursor, end: end)
                cursor = advance
                if !value.isEmpty {
                    tokens.append(.phrase(value, negated: negated))
                }
            } else {
                let (value, advance) = readWord(raw, from: cursor, end: end)
                cursor = advance
                if !value.isEmpty {
                    tokens.append(.word(value, negated: negated))
                }
            }
        }

        return tokens
    }

    /// Read operator value: may be quoted or plain word.
    nonisolated private static func readValue(
        _ raw: String, from start: String.Index, end: String.Index
    ) -> (String, String.Index) {
        guard start < end else { return ("", start) }
        if raw[start] == "\"" {
            return readQuoted(raw, from: start, end: end)
        }
        return readWord(raw, from: start, end: end)
    }

    nonisolated private static func readQuoted(
        _ raw: String, from start: String.Index, end: String.Index
    ) -> (String, String.Index) {
        // Expect raw[start] == "\""
        guard start < end, raw[start] == "\"" else { return ("", start) }
        var i = raw.index(after: start)
        let valueStart = i
        while i < end, raw[i] != "\"" {
            i = raw.index(after: i)
        }
        let value = String(raw[valueStart..<i])
        let next = i < end ? raw.index(after: i) : end
        return (value, next)
    }

    nonisolated private static func readWord(
        _ raw: String, from start: String.Index, end: String.Index
    ) -> (String, String.Index) {
        var i = start
        while i < end, !raw[i].isWhitespace {
            i = raw.index(after: i)
        }
        return (String(raw[start..<i]), i)
    }
}
