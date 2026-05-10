//
//  SyncService+ResilientFetch.swift
//  MyEmail
//
//  Resilient header fetch with per-UID fallback when NIOIMAPCore parser fails.
//

import Foundation
import NIO // TEMP-REVERT: only needed for ParserError buffer dump
import SwiftMail
import SwiftEmailParser

extension SyncService {

    /// Try batch fetch; on parser error, fall back to per-UID fetches.
    /// - scopeUIDs: If provided, fallback only fetches these UIDs.
    ///   If nil, discovers UIDs via SEARCH ALL (use only for initial fetch).
    ///
    /// Thunderbird parity (`nsImapGenericParser::skip_to_CRLF`): parse
    /// errors do NOT trigger a reconnect. The session stays authenticated;
    /// we just re-SELECT (no-op if still selected) and retry the failing
    /// UIDs individually. Previously we called
    /// `imap.disconnect()` + `imap.connect()` here, which cascaded into
    /// "Login failed: Unknown command" when a concurrent sync had already
    /// taken over the reconnect path. Per-account serial lock in
    /// `SyncService.runSerializedPerAccount` is now the primary guard
    /// against concurrent use of the socket.
    func resilientFetchHeaders(
        imap: IMAPService,
        folderPath: String,
        account: Account,
        scopeUIDs: [UInt32]? = nil,
        fetch: () async throws -> [MessageInfo]
    ) async throws -> [MessageInfo] {
        do {
            return try await fetch()
        } catch {
            let desc = "\(error)"
            guard Self.isParserError(desc) else { throw error }

            LogService.log(.warning, .sync,
                           "Batch fetch parser error, retrying per-UID on live connection",
                           detail: desc.prefix(200).description)

            // Stay on the authenticated session. `ensureFolderSelected` is
            // a no-op when the folder is already current — matches Thunderbird
            // retrying the URL on the same nsImapProtocol instance.
            _ = try await imap.ensureFolderSelected(folderPath)

            let uidsToFetch: [UInt32]
            if let scope = scopeUIDs {
                uidsToFetch = scope.sorted()
            } else {
                uidsToFetch = try await imap.listAllUIDs().sorted()
            }
            var results: [MessageInfo] = []
            var rawFailStreak = 0
            let maxRawFails = 5

            // ANY FETCH error (parser or transport) poisons the SwiftMail
            // channel: the parser does not drain the rest of the untagged
            // response to a CRLF boundary, so subsequent commands get
            // interpreted as continuation (`[CLIENTBUG] Unrecognised
            // command`). Uniform recovery: on any error, reset the socket
            // BEFORE attempting the raw-RFC822 fallback on the same UID.
            for uid in uidsToFetch {
                var envelopeFailed = false
                do {
                    let infos = try await imap.fetchHeadersBySet([uid])
                    if !infos.isEmpty {
                        results.append(contentsOf: infos)
                        rawFailStreak = 0
                        continue
                    }
                } catch {
                    envelopeFailed = true
                    let desc = "\(error)"
                    let typeName = String(describing: type(of: error))
                    LogService.log(.warning, .sync,
                        "ENVELOPE failed for UID \(uid) (type=\(typeName)), resetting socket before raw fallback",
                        detail: desc)
                    await resetPoisonedConnection(imap: imap, folderPath: folderPath)
                }

                // Raw fallback only makes sense on a freshly-reset socket.
                // If ENVELOPE succeeded but returned no rows (weird edge
                // case), still try raw fallback without reset.
                if let info = await rawHeaderFallback(uid: uid, imap: imap) {
                    results.append(info)
                    rawFailStreak = 0
                } else {
                    rawFailStreak += 1
                    if rawFailStreak >= maxRawFails {
                        LogService.log(.warning, .sync,
                            "Too many raw fallback failures in a row, stopping at UID \(uid)",
                            detail: envelopeFailed ? "last cause: ENVELOPE parse" : "no data")
                        break
                    }
                }
            }
            LogService.log(.info, .sync,
                           "Resilient fetch: \(results.count)/\(uidsToFetch.count) recovered")
            return results
        }
    }

    static func isParserError(_ desc: String) -> Bool {
        desc.contains("ParserError") || desc.contains("DecoderError")
    }

    /// True for errors where the IMAP socket is in an undefined state and
    /// must be torn down before any next command. Two classes:
    ///   1. Transport-level: timeout, NIO channel failure, connection closed.
    ///   2. Server BAD responses — Thunderbird parity: any `BAD` reply means
    ///      the server rejected the command at the protocol level (session
    ///      confused, stream misaligned, state lost). SwiftMail encodes this
    ///      as `IMAPError.fetchFailed("bad(...)")`. Like nsImapProtocol.cpp
    ///      we treat all BAD as unrecoverable on the current socket; the only
    ///      safe action is disconnect + reconnect (NO responses are semantic
    ///      errors and do not require reconnect).
    /// Either way the only safe recovery is disconnect + reconnect.
    static func isTransportError(_ desc: String) -> Bool {
        desc.contains("timed out")
            || desc.contains("Operation timed out")
            || desc.contains("ChannelError")
            || desc.contains("IOError")
            || desc.contains("NIOConnectionError")
            || desc.contains("connection closed")
            || desc.contains("Connection closed")
            || desc.contains("Broken pipe")
            || desc.contains("bad(")
    }

    // TEMP-REVERT: dump raw IMAPDecoderError buffer to disk for diagnosing
    // Gmail CONDSTORE FETCH parse failures. Remove helper + call sites once
    // root cause is understood.
    @discardableResult
    static func dumpParserErrorBuffer(_ error: Error, context: String) -> URL? {
        let mirror = Mirror(reflecting: error)
        guard let bufferChild = mirror.children.first(where: { $0.label == "buffer" }),
              let buf = bufferChild.value as? ByteBuffer
        else { return nil }
        let data = Data(buf.readableBytesView)

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("MyEmail", isDirectory: true)
            .appendingPathComponent("parser-errors", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let safeContext = context.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent("\(stamp)-\(safeContext).bin")
        do {
            try data.write(to: url)
            LogService.log(.warning, .sync,
                "ParserError buffer dumped (\(data.count) bytes)", detail: url.path)
            return url
        } catch {
            LogService.log(.error, .sync, "ParserError dump failed", detail: "\(error)")
            return nil
        }
    }

    /// Force-reset a poisoned IMAP socket: close TCP, reconnect, re-select
    /// folder. Caller holds the per-account serial lock, so reset is atomic
    /// w.r.t. other ops on the same socket.
    func resetPoisonedConnection(imap: IMAPService, folderPath: String) async {
        await imap.disconnect()
        do {
            try await imap.connect()
            try await imap.ensureFolderSelected(folderPath)
            LogService.log(.info, .sync, "Reset poisoned IMAP socket", detail: folderPath)
        } catch {
            LogService.log(.warning, .sync,
                "Reset-reconnect failed",
                detail: "\(folderPath): \(error)")
        }
    }

    /// Fallback: fetch raw RFC 5322 message, parse headers with SwiftEmailParser.
    func rawHeaderFallback(uid: UInt32, imap: IMAPService) async -> MessageInfo? {
        do {
            let rawData = try await imap.fetchRawMessage(uid: uid)
            let email = try EmailMessage(data: rawData)

            let fromAddr = email.from.first
            let fromStr = fromAddr.map { addr in
                if let name = addr.name, !name.isEmpty {
                    return "\"\(name)\" <\(addr.address)>"
                }
                return addr.address
            } ?? ""

            var info = MessageInfo(sequenceNumber: SequenceNumber(0))
            info.uid = UID(uid)
            info.subject = email.subject
            info.from = fromStr
            info.to = email.to.map(\.formatted)
            info.cc = email.cc.map(\.formatted)
            info.bcc = email.bcc.map(\.formatted)
            info.date = email.date
            if let msgID = email.messageId {
                info.messageId = MessageID(msgID)
            }
            if let replyTo = email.inReplyTo {
                info.inReplyTo = MessageID(replyTo)
            }
            let refs = email.references.compactMap { MessageID($0) }
            info.references = refs.isEmpty ? nil : refs

            if let flagInfo = try? await imap.fetchSingleMessageInfo(uid: uid) {
                info.flags = flagInfo.flags
            }

            LogService.log(.info, .sync, "Raw header fallback OK for UID \(uid)")
            return info
        } catch {
            LogService.log(.error, .sync,
                           "Raw header fallback failed for UID \(uid)",
                           detail: "\(error)")
            return nil
        }
    }
}
