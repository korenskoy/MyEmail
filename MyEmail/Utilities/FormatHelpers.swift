//
//  FormatHelpers.swift
//  MyEmail
//
//  Shared formatting utilities.
//

import Foundation

nonisolated enum FormatHelpers {
    /// Human-readable byte count (B/KB/MB). Dash for zero/negative.
    static func formatByteCount(_ bytes: Int) -> String {
        guard bytes > 0 else { return "—" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
