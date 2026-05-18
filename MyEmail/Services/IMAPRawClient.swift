//
//  IMAPRawClient.swift
//  MyEmail
//
//  Lightweight raw IMAP client for commands SwiftMail doesn't expose:
//  DELETE, RENAME, EXAMINE. Uses NWConnection (TLS) + raw text protocol.
//  One-shot: connect → auth → command → logout. Not for general use.
//

import Foundation
import Network

actor IMAPRawClient {
    private let host: String
    private let port: UInt16
    private let security: ConnectionSecurity
    private var connection: NWConnection?
    private var tagCounter = 0
    private var buffer = Data()

    init(host: String, port: UInt16, security: ConnectionSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }

    // MARK: - Connection

    func connect() async throws {
        // NWConnection doesn't support mid-stream TLS upgrade (STARTTLS).
        // For .starttls accounts, use TLS directly — works on most servers.
        let useTLS = security != .none

        // TCP keepalive (Thunderbird parity: mail.imap.tcp_keepalive.*).
        // Detects dead one-shot raw sockets within ~60s, matching SwiftMail's
        // primary IMAP socket policy.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveCount = 3
        tcpOptions.keepaliveInterval = 10

        let params = NWParameters(
            tls: useTLS ? NWProtocolTLS.Options() : nil,
            tcp: tcpOptions
        )

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw IMAPRawError.invalidPort
        }

        let conn = NWConnection(host: nwHost, port: nwPort, using: params)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let error):
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                case .cancelled:
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: IMAPRawError.connectionCancelled)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        // Read server greeting
        let greeting = try await readLine()
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            throw IMAPRawError.badGreeting(greeting)
        }
    }

    // MARK: - Authentication

    func login(user: String, password: String) async throws {
        let escaped = password.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let resp = try await sendCommand("LOGIN \"\(user)\" \"\(escaped)\"")
        guard resp.status == .ok else {
            throw IMAPRawError.authFailed(resp.text)
        }
    }

    func authenticateXOAUTH2(email: String, accessToken: String) async throws {
        let authString = "user=\(email)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        let base64 = Data(authString.utf8).base64EncodedString()
        let resp = try await sendCommand("AUTHENTICATE XOAUTH2 \(base64)")
        guard resp.status == .ok else {
            throw IMAPRawError.authFailed(resp.text)
        }
    }

    // MARK: - Mailbox commands

    /// IMAP DELETE — RFC 3501 §6.3.4
    func deleteMailbox(_ path: String) async throws {
        let resp = try await sendCommand("DELETE \(quoteMailbox(path))")
        guard resp.status == .ok else {
            throw IMAPRawError.commandFailed("DELETE", resp.text)
        }
    }

    /// IMAP RENAME — RFC 3501 §6.3.5
    func renameMailbox(from oldPath: String, to newPath: String) async throws {
        let resp = try await sendCommand("RENAME \(quoteMailbox(oldPath)) \(quoteMailbox(newPath))")
        guard resp.status == .ok else {
            throw IMAPRawError.commandFailed("RENAME", resp.text)
        }
    }

    /// IMAP EXAMINE — RFC 3501 §6.3.2 (read-only SELECT)
    func examine(_ path: String) async throws -> ExamineResult {
        let resp = try await sendCommand("EXAMINE \(quoteMailbox(path))")
        guard resp.status == .ok else {
            throw IMAPRawError.commandFailed("EXAMINE", resp.text)
        }
        return ExamineResult(
            exists: parseUntaggedInt("EXISTS", from: resp.untagged),
            recent: parseUntaggedInt("RECENT", from: resp.untagged),
            uidValidity: parseResponseCode("UIDVALIDITY", from: resp.untagged),
            uidNext: parseResponseCode("UIDNEXT", from: resp.untagged)
        )
    }

    // MARK: - Disconnect

    func logout() async {
        _ = try? await sendCommand("LOGOUT")
        connection?.cancel()
        connection = nil
    }

    // MARK: - Raw protocol I/O

    private func nextTag() -> String {
        tagCounter += 1
        return "R\(tagCounter)"
    }

    private func sendCommand(_ command: String) async throws -> TaggedResponse {
        let tag = nextTag()
        try await send("\(tag) \(command)\r\n")

        var untagged: [String] = []
        while true {
            let line = try await readLine()

            // Continuation request (e.g. AUTHENTICATE challenge)
            if line.hasPrefix("+") {
                // For XOAUTH2 error, send empty continuation
                try await send("\r\n")
                continue
            }

            // Tagged response — our command completed
            if line.hasPrefix(tag) {
                let remainder = String(line.dropFirst(tag.count + 1))
                let status = parseStatus(remainder)
                return TaggedResponse(tag: tag, status: status, text: remainder, untagged: untagged)
            }

            // Untagged response
            untagged.append(line)
        }
    }

    private func send(_ text: String) async throws {
        guard let conn = connection else { throw IMAPRawError.notConnected }
        let data = Data(text.utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private func readLine() async throws -> String {
        // Check buffer for complete line
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer[buffer.startIndex..<range.lowerBound]
                buffer.removeSubrange(buffer.startIndex...range.upperBound - 1)
                return String(data: lineData, encoding: .utf8) ?? ""
            }

            // Read more data
            guard let conn = connection else { throw IMAPRawError.notConnected }
            let chunk = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(throwing: IMAPRawError.connectionClosed)
                    }
                }
            }
            buffer.append(chunk)
        }
    }

    // MARK: - Parsing helpers

    private func quoteMailbox(_ path: String) -> String {
        let encoded = IMAPUTF7.encode(path)
        let escaped = encoded.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func parseStatus(_ line: String) -> ResponseStatus {
        let upper = line.uppercased()
        if upper.hasPrefix("OK") { return .ok }
        if upper.hasPrefix("NO") { return .no }
        if upper.hasPrefix("BAD") { return .bad }
        return .unknown
    }

    private func parseUntaggedInt(_ keyword: String, from lines: [String]) -> Int? {
        // e.g. "* 42 EXISTS"
        for line in lines {
            if line.hasSuffix(keyword) || line.contains(" \(keyword)") {
                let parts = line.dropFirst(2).components(separatedBy: " ")
                if let num = parts.first.flatMap({ Int($0) }) { return num }
            }
        }
        return nil
    }

    private func parseResponseCode(_ code: String, from lines: [String]) -> UInt32? {
        // e.g. "* OK [UIDVALIDITY 1234]" or in tagged response
        let pattern = "[\(code) "
        for line in lines {
            if let range = line.range(of: pattern) {
                let rest = line[range.upperBound...]
                if let end = rest.firstIndex(of: "]") {
                    return UInt32(rest[..<end])
                }
            }
        }
        return nil
    }
}

// MARK: - Types

struct TaggedResponse: Sendable {
    let tag: String
    let status: ResponseStatus
    let text: String
    let untagged: [String]
}

enum ResponseStatus: Sendable {
    case ok, no, bad, unknown
}

struct ExamineResult: Sendable {
    let exists: Int?
    let recent: Int?
    let uidValidity: UInt32?
    let uidNext: UInt32?
}

enum IMAPRawError: Error, Sendable {
    case invalidPort
    case notConnected
    case connectionClosed
    case connectionCancelled
    case badGreeting(String)
    case starttlsFailed(String)
    case authFailed(String)
    case commandFailed(String, String)
}
