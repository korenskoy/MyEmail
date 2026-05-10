//
//  MUAResolver.swift
//  MUAResolver (XPC Service, GPL-3.0)
//
//  Exported NSXPCConnection object. Thin wrapper around MUAMatcher —
//  the real detection logic lives there. Icon data is read from this
//  bundle's Resources and passed back to the host app as raw PNG bytes.
//

import Foundation

// NSXPCConnection invokes exported methods from a background queue —
// the conformance MUST be nonisolated for Swift 6 strict concurrency.
final class MUAResolver: NSObject, MUAResolverProtocol, @unchecked Sendable {
    nonisolated func resolve(
        userAgent: String,
        withReply reply: @escaping (Data?, String?, String?) -> Void
    ) {
        guard let info = MUAMatcher.match(userAgent: userAgent) else {
            reply(nil, nil, nil)
            return
        }
        let data = Self.loadIcon(named: info.iconName)
        reply(data, info.displayName, info.iconName)
    }

    /// Icons may end up either under a "MUAIcons" subdirectory (if added as
    /// a folder reference) or flattened into the bundle root (if Xcode's
    /// synchronized folders treated the directory as a group). Try both.
    nonisolated private static func loadIcon(named iconName: String) -> Data? {
        if let url = Bundle.main.url(
            forResource: iconName, withExtension: nil, subdirectory: "MUAIcons"
        ), let data = try? Data(contentsOf: url) {
            return data
        }
        if let url = Bundle.main.url(forResource: iconName, withExtension: nil),
           let data = try? Data(contentsOf: url) {
            return data
        }
        // Final fallback: walk resourceURL manually.
        if let resources = Bundle.main.resourceURL {
            let nested = resources.appendingPathComponent("MUAIcons/\(iconName)")
            if FileManager.default.fileExists(atPath: nested.path) {
                return try? Data(contentsOf: nested)
            }
            let flat = resources.appendingPathComponent(iconName)
            if FileManager.default.fileExists(atPath: flat.path) {
                return try? Data(contentsOf: flat)
            }
        }
        return nil
    }
}
