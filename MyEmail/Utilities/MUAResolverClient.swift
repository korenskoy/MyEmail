//
//  MUAResolverClient.swift
//  MyEmail
//
//  Thin NSXPCConnection wrapper + per-process cache. The actual detection
//  and icon data live in the GPL-3.0-isolated MUAResolver.xpc bundle —
//  this client only sees the chin wire-protocol.
//

import Foundation

actor MUAResolverClient {
    static let shared = MUAResolverClient()

    struct Resolved: Sendable, Hashable {
        let pngData: Data
        let displayName: String?
        let iconName: String
    }

    // Matches PRODUCT_BUNDLE_IDENTIFIER of the MUAResolver target.
    private let serviceName = "ru.korenskoy.MUAResolver"
    private var connection: NSXPCConnection?
    private var cache: [String: Resolved?] = [:]

    private init() {}

    /// Returns nil when the mail client is unknown or XPC failed.
    /// Result is memoized by UA — subsequent calls with the same UA don't hit XPC.
    func resolve(userAgent: String) async -> Resolved? {
        if let cached = cache[userAgent] { return cached }
        let result = await callXPC(userAgent: userAgent)
        cache[userAgent] = result
        return result
    }

    // MARK: - Private

    private func callXPC(userAgent: String) async -> Resolved? {
        let conn = ensureConnection()
        return await withCheckedContinuation { (cont: CheckedContinuation<Resolved?, Never>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
                Task { await self?.tearDownConnection() }
                cont.resume(returning: nil)
            } as? MUAResolverProtocol
            guard let proxy else {
                cont.resume(returning: nil)
                return
            }
            proxy.resolve(userAgent: userAgent) { data, display, icon in
                guard let data, !data.isEmpty, let icon else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: Resolved(
                    pngData: data,
                    displayName: display,
                    iconName: icon
                ))
            }
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let existing = connection { return existing }
        let conn = NSXPCConnection(serviceName: serviceName)
        conn.remoteObjectInterface = NSXPCInterface(with: MUAResolverProtocol.self)
        conn.interruptionHandler = { [weak self] in
            Task { await self?.tearDownConnection() }
        }
        conn.invalidationHandler = { [weak self] in
            Task { await self?.tearDownConnection() }
        }
        conn.resume()
        connection = conn
        return conn
    }

    private func tearDownConnection() {
        connection?.invalidate()
        connection = nil
    }
}
