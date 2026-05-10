//
//  LogService.swift
//  MyEmail
//
//  In-app log buffer. Единственная точка логирования (см. §6.10 требований).
//  Никаких print() в проекте — всё идёт через LogService.shared.log(...).
//  Просмотр логов — DebugLogPanelView (⌥⌘Y).
//

import Foundation
import Observation

// MARK: - Public types

enum LogLevel: String, CaseIterable, Codable, Sendable, Comparable {
    case debug
    case info
    case warning
    case error

    var rank: Int {
        switch self {
        case .debug:   return 0
        case .info:    return 1
        case .warning: return 2
        case .error:   return 3
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum LogCategory: String, CaseIterable, Codable, Sendable {
    case imap
    case smtp
    case auth
    case sync
    case search
    case rules
    case cache
    case notifications
    case uiDebug
    case db
}

struct LogEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    let detail: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        category: LogCategory,
        message: String,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.detail = detail
    }
}

// MARK: - LogService

/// Ring-buffer log store. MainActor-isolated because `DebugLogPanelView` observes
/// `entries` directly via `@Observable`. Logging from non-main contexts hops to
/// main via a small `nonisolated` trampoline (`log(_:_:_:detail:)`) which dispatches
/// with `Task { @MainActor in ... }`.
@Observable
@MainActor
final class LogService {
    static let shared = LogService()

    /// Maximum number of entries kept in memory. Older entries are evicted FIFO.
    private let capacity: Int

    /// Live view consumed by `DebugLogPanelView`.
    private(set) var entries: [LogEntry] = []

    private init(capacity: Int = 5_000) {
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    // MARK: Append

    /// Main-actor entry point — call directly from any `@MainActor` context.
    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    // MARK: Convenience

    /// Synchronous convenience when already on MainActor.
    func log(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: String,
        detail: String? = nil
    ) {
        append(LogEntry(
            level: level,
            category: category,
            message: message,
            detail: detail
        ))
    }
}

// MARK: - Non-isolated trampoline

extension LogService {
    /// Called from any isolation domain (actors, Sendable closures, detached tasks).
    /// Schedules the append on MainActor.
    nonisolated static func log(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: String,
        detail: String? = nil
    ) {
        let entry = LogEntry(
            level: level,
            category: category,
            message: message,
            detail: detail
        )
        Task { @MainActor in
            LogService.shared.append(entry)
        }
    }
}
