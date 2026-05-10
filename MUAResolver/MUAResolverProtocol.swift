//
//  MUAResolverProtocol.swift
//  MUAResolver (XPC Service)
//
//  IMPORTANT: this protocol is intentionally duplicated in the main app at
//  MyEmail/Shared/MUAResolverProtocol.swift. Both files MUST stay in sync
//  — they describe the same XPC wire contract from opposite sides.
//  Keeping a copy on each side avoids having to wrestle Xcode 16's
//  synchronized folder Target Membership across targets.
//

import Foundation

@objc public protocol MUAResolverProtocol {
    func resolve(
        userAgent: String,
        withReply reply: @escaping (Data?, String?, String?) -> Void
    )
}
