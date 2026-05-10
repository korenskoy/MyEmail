//
//  GravatarService.swift
//  MyEmail
//
//  Gravatar avatar fetch + disk cache (DESIGN.md §4.5).
//  SHA-256 hash of lowercased trimmed email.
//  URL: https://www.gravatar.com/avatar/<hash>?d=404&s=48
//  Default = Off (privacy-by-default). 30-day disk cache.
//

import AppKit
import CryptoKit
import Foundation

@Observable
@MainActor
final class GravatarService {
    private let memoryCache = NSCache<NSString, NSImage>()
    // Remember 404/error responses so `avatar(for:)` doesn't respawn fetches
    // forever on every SwiftUI body re-eval for addresses without a Gravatar.
    private let negativeCache = NSCache<NSString, NSNumber>()
    private var inFlight: Set<String> = []
    private let cacheDirURL: URL?

    init() {
        memoryCache.countLimit = 200
        negativeCache.countLimit = 2000
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        cacheDirURL = caches?.appendingPathComponent("MyEmail/gravatar")
    }

    // MARK: - Public

    /// Returns memory-cached image or nil. Disk/network fetch is async via .task.
    func avatar(for email: String) -> NSImage? {
        let key = normalizedEmail(email)
        let nsKey = key as NSString

        if let cached = memoryCache.object(forKey: nsKey) { return cached }
        // Negative hit — gravatar known to be missing; don't refetch.
        if negativeCache.object(forKey: nsKey) != nil { return nil }

        if !inFlight.contains(key) {
            inFlight.insert(key)
            Task { await fetchAndCache(key: key) }
        }

        return nil
    }

    // MARK: - Private

    private func fetchAndCache(key: String) async {
        defer { inFlight.remove(key) }

        // Compute hash once — used for both disk path and URL.
        let hash = sha256(key)
        let cacheDir = cacheDirURL
        let diskURL = cacheDir?.appendingPathComponent(hash + ".png")
        let nsKey = key as NSString

        // Disk probe + PNG decode are synchronous — offload from MainActor.
        let loadTask = Task.detached(priority: .utility) {
            Self.loadFromDiskSync(diskURL: diskURL)
        }
        if let disk = await loadTask.value {
            memoryCache.setObject(disk, forKey: nsKey)
            return
        }

        let urlString = "https://www.gravatar.com/avatar/\(hash)?d=404&s=48"
        guard let url = URL(string: urlString) else {
            negativeCache.setObject(NSNumber(value: 1), forKey: nsKey)
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else {
                negativeCache.setObject(NSNumber(value: 1), forKey: nsKey)
                return
            }

            memoryCache.setObject(image, forKey: nsKey)
            let saveTask = Task.detached(priority: .utility) {
                Self.saveToDiskSync(dir: cacheDir, path: diskURL, data: data)
            }
            _ = await saveTask.value
        } catch {
            // Network failure / cancelled — treat as missing for the session.
            negativeCache.setObject(NSNumber(value: 1), forKey: nsKey)
        }
    }

    nonisolated private static func loadFromDiskSync(diskURL: URL?) -> NSImage? {
        guard let path = diskURL else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return nil }
        if let attrs = try? fm.attributesOfItem(atPath: path.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 30 * 24 * 3600 {
            try? fm.removeItem(at: path)
            return nil
        }
        return NSImage(contentsOf: path)
    }

    nonisolated private static func saveToDiskSync(dir: URL?, path: URL?, data: Data) {
        guard let dir, let path else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: path, options: .atomic)
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Fast hex-encoded SHA-256. Avoids `String(format:)` which allocates a
    /// CFString per byte (profiled as a hot-spot when Gravatar is enabled).
    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        let lut: [Character] = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in hash {
            result.append(lut[Int(byte >> 4)])
            result.append(lut[Int(byte & 0x0F)])
        }
        return result
    }
}
