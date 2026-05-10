//
//  MUAResolverProtocol.swift
//  Shared — main app + MUAResolver XPC target.
//
//  Wire contract between MyEmail host and the GPL-isolated
//  MUAResolver.xpc service. Contains no implementation — interface
//  specification only. Safe to include in both targets.
//

import Foundation

/// NSXPCConnection-compatible protocol. ObjC runtime requires @objc.
/// Reply-handler carries the result because XPC methods cannot throw
/// and cannot return values directly.
///
/// Reply tuple: (pngData, displayName, iconName).
/// All three nil ⇒ user agent not recognised.
@objc public protocol MUAResolverProtocol {
    func resolve(
        userAgent: String,
        withReply reply: @escaping (Data?, String?, String?) -> Void
    )
}
