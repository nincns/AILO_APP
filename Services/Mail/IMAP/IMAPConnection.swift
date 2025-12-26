// AILO_APP/Configuration/Services/Mail/IMAPConnection.swift
// Low-level IMAP TCP/TLS transport layer (connect, send, receive, close).
// Handles SNI, literal block reading, timeouts, NWError mapping, and connection lifecycle.
// Used exclusively by IMAPCommands; stateless beyond current session.
// Threading: NOT thread-safe. Use only from a single serial context per instance.

import Foundation
import Network

// MARK: - Types

public struct IMAPConnectionConfig: Sendable {
    public let host: String
    public let port: Int
    /// When true, create a direct TLS session (IMAPS 993). STARTTLS is not handled here.
    public let tls: Bool
    /// Optional Server Name Indication for TLS
    public let sniHost: String?
    /// Connect timeout in seconds
    public let connectionTimeoutSec: Int
    /// Command / read idle timeout in seconds (per step)
    public let commandTimeoutSec: Int
    /// Optional idle timeout for long reads (e.g., LIST responses)
    public let idleTimeoutSec: Int

    public init(
        host: String,
        port: Int,
        tls: Bool = true,
        sniHost: String? = nil,
        connectionTimeoutSec: Int = 15,
        commandTimeoutSec: Int = 10,
        idleTimeoutSec: Int = 10
    ) {
        self.host = host
        self.port = port
        self.tls = tls
        self.sniHost = sniHost
        self.connectionTimeoutSec = connectionTimeoutSec
        self.commandTimeoutSec = commandTimeoutSec
        self.idleTimeoutSec = idleTimeoutSec
    }
}

public enum IMAPError: LocalizedError {
    case invalidState(String)
    case connectTimeout(String)
    case connectFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case networkUnreachable(String)
    case protocolError(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .invalidState(let s): return s
        case .connectTimeout(let s): return s
        case .connectFailed(let s): return s
        case .sendFailed(let s): return s
        case .receiveFailed(let s): return s
        case .networkUnreachable(let s): return s
        case .protocolError(let s): return s
        case .closed: return "Connection closed"
        }
    }
}

// MARK: - IMAPConnection

public final class IMAPConnection {
    private var conn: NWConnection?
    private let queue: DispatchQueue
    private var config: IMAPConnectionConfig?

    public init(label suffix: String = UUID().uuidString) {
        self.queue = DispatchQueue(label: "imap.connection.\(suffix)")
    }

    public var isOpen: Bool {
        if case .ready = conn?.state { return true }
        return false
    }

    public var peerDescription: String {
        guard let cfg = config else { return "imap://(closed)" }
        return "\(cfg.host):\(cfg.port)"
    }

    // MARK: Lifecycle

    public func open(_ cfg: IMAPConnectionConfig) async throws {
        guard conn == nil else {
            throw IMAPError.invalidState("Connection already open")
        }
        self.config = cfg

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(cfg.host),
            port: NWEndpoint.Port(rawValue: UInt16(cfg.port))!
        )

        let tcp = NWProtocolTCP.Options()
        var parameters: NWParameters
        if cfg.tls {
            let tls = NWProtocolTLS.Options()
            let sni = cfg.sniHost ?? cfg.host
            if !sni.isEmpty {
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sni)
            }
            // Enforce conservative TLS versions for better interoperability
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        parameters.preferNoProxies = true
        parameters.allowLocalEndpointReuse = true

        let c = NWConnection(to: endpoint, using: parameters)
        self.conn = c

        try await awaitReady(c, queue: queue, timeout: TimeInterval(Double(max(3, cfg.connectionTimeoutSec))))
    }

    public func close() {
        conn?.cancel()
        conn = nil
        config = nil
    }

    /// Upgrades the current plain connection to TLS (for STARTTLS flow).
    /// Call this AFTER receiving "OK Begin TLS" from STARTTLS command.
    public func upgradeToTLS() async throws {
        guard let cfg = config else { throw IMAPError.invalidState("No config for TLS upgrade") }
        // Close existing plain connection
        conn?.cancel()
        conn = nil
        // Reopen with TLS enabled using the same host/port/timeouts
        let tlsCfg = IMAPConnectionConfig(
            host: cfg.host,
            port: cfg.port,
            tls: true,
            sniHost: cfg.sniHost ?? cfg.host,
            connectionTimeoutSec: cfg.connectionTimeoutSec,
            commandTimeoutSec: cfg.commandTimeoutSec,
            idleTimeoutSec: cfg.idleTimeoutSec
        )
        try await open(tlsCfg)
    }

    // MARK: I/O

    /// Send a single IMAP line (CRLF is appended).
    public func send(line: String) async throws {
        guard let c = conn else { throw IMAPError.invalidState("send on nil connection") }
        let payload = (line + "\r\n").data(using: .utf8) ?? Data()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: self.mapNWError(error, context: "send \(line.prefix(8))…"))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Send raw data without appending CRLF (used for IMAP literals like APPEND).
    public func sendRaw(_ data: Data) async throws {
        guard let c = conn else { throw IMAPError.invalidState("sendRaw on nil connection") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: self.mapNWError(error, context: "sendRaw \(data.count) bytes"))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Receive lines until a final tagged response for `untilTag` arrives (OK/NO/BAD) or until idle timeout.
    /// If `untilTag` is nil, returns lines accumulated until idle timeout.
    public func receiveLines(
        untilTag: String?,
        idleTimeout: TimeInterval? = nil,
        hardTimeout: TimeInterval? = nil,
        maxBytes: Int = 0,
        maxLines: Int = 0
    ) async throws -> [String] {
        guard let c = conn, let cfg = config else { throw IMAPError.invalidState("receive without connection") }
        var lines: [String] = []
        var buffer = Data()
        let softTimeout = idleTimeout ?? TimeInterval(max(3, cfg.commandTimeoutSec))
        let hardDeadline: Date? = hardTimeout != nil ? Date().addingTimeInterval(hardTimeout!) : nil
        let timeout = softTimeout
        var idleDeadline = Date().addingTimeInterval(timeout)

        var totalBytes = 0
        var totalLines = 0

        func drainBufferToLines() -> Int {
            var appended = 0
            guard !buffer.isEmpty else { return 0 }
            if let s = String(data: buffer, encoding: .utf8) {
                if let lastCRLF = s.range(of: "\r\n", options: .backwards) {
                    let upTo = s[..<lastCRLF.lowerBound]
                    let remainder = s[lastCRLF.upperBound...]
                    let parts = upTo.components(separatedBy: "\r\n").filter { !$0.isEmpty }
                    lines.append(contentsOf: parts)
                    appended = parts.count
                    totalLines += appended
                    buffer = Data(remainder.utf8)
                }
            }
            return appended
        }

        print("📡 [receiveLines] Starting loop, timeout=\(timeout)s, tag=\(untilTag ?? "nil")")
        while Date() < idleDeadline && (hardDeadline == nil || Date() < hardDeadline!) {
            // Use a timeout for receive to prevent blocking forever
            let receiveTimeout = min(timeout, 10.0) // Max 10 seconds per receive
            print("📡 [receiveLines] Waiting for data (max \(receiveTimeout)s)...")
            let data: Data? = try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
                            if let error {
                                cont.resume(throwing: self.mapNWError(error, context: "receive"))
                                return
                            }
                            cont.resume(returning: data)
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(receiveTimeout * 1_000_000_000))
                    return nil // Timeout - return nil to signal no data
                }
                // Return the first result (either data or timeout)
                if let result = try await group.next() {
                    group.cancelAll()
                    return result
                }
                return nil
            }
            if data == nil {
                print("📡 [receiveLines] Receive returned nil (timeout or no data)")
            } else {
                print("📡 [receiveLines] Received \(data!.count) bytes")
            }
            guard let data, !data.isEmpty else { break }
            let chunkSize = data.count
            if maxBytes > 0 && (totalBytes + chunkSize) > maxBytes {
                let remaining = maxBytes - totalBytes
                if remaining > 0 {
                    buffer.append(data.prefix(remaining))
                }
                totalBytes = maxBytes
                _ = drainBufferToLines()
                break
            }
            buffer.append(data)
            totalBytes += chunkSize

            // Robust IMAP literal handling using byte-level scan (avoids UTF-8 decoding issues).
            // If the buffer ends with a size marker "{n}\r\n", make sure we have n bytes after that CRLF.
            func missingLiteralBytes(in data: Data) -> Int? {
                if data.count < 4 { return nil }
                return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    if bytes.isEmpty { return nil }
                    var i = bytes.count - 3
                    while i >= 0 {
                        // Look for pattern: '}' CR LF
                        if bytes[i] == 125 && bytes[i+1] == 13 && bytes[i+2] == 10 {
                            // Walk backwards to find '{' and gather digits
                            var j = i - 1
                            var digits: [UInt8] = []
                            var sawOpen = false
                            while j >= 0 {
                                let b = bytes[j]
                                if b == 123 { // '{'
                                    sawOpen = true
                                    break
                                }
                                // Only accept ASCII digits for the size; abort on other chars
                                if b < 48 || b > 57 { digits.removeAll(); break }
                                digits.insert(b, at: 0)
                                j -= 1
                                if digits.count > 10 { break } // guard: absurdly large size token
                            }
                            if sawOpen, !digits.isEmpty, let nStr = String(bytes: digits, encoding: .ascii), let n = Int(nStr), n > 0 {
                                let bytesAfterCRLF = bytes.count - (i + 3)
                                if bytesAfterCRLF < n {
                                    return n - bytesAfterCRLF
                                } else {
                                    return nil
                                }
                            }
                            break
                        }
                        i -= 1
                    }
                    return nil
                }
            }

            if let need = missingLiteralBytes(in: buffer) {
                var remaining = need
                while remaining > 0 && Date() < idleDeadline && (hardDeadline == nil || Date() < hardDeadline!) {
                    let readLen = min(16 * 1024, remaining)
                    let more: Data? = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                        c.receive(minimumIncompleteLength: 1, maximumLength: readLen) { data, _, _, error in
                            if let error {
                                cont.resume(throwing: self.mapNWError(error, context: "receive literal"))
                                return
                            }
                            cont.resume(returning: data)
                        }
                    }
                    guard let more, !more.isEmpty else { break }
                    var toAppend = more
                    if maxBytes > 0 && (totalBytes + more.count) > maxBytes {
                        let allowed = max(0, maxBytes - totalBytes)
                        toAppend = allowed > 0 ? more.prefix(allowed) : Data()
                    }
                    if !toAppend.isEmpty {
                        buffer.append(toAppend)
                        totalBytes += toAppend.count
                        remaining -= toAppend.count
                    } else {
                        break
                    }
                    idleDeadline = Date().addingTimeInterval(timeout)
                    if maxBytes > 0 && totalBytes >= maxBytes { break }
                }
            }

            idleDeadline = Date().addingTimeInterval(timeout)
            let appended = drainBufferToLines()
            if appended > 0 {
                print("📡 [receiveLines] Drained \(appended) lines, total: \(lines.count)")
                for (i, line) in lines.suffix(appended).enumerated() {
                    print("📡 [receiveLines] Line[\(lines.count - appended + i)]: \(line.prefix(100))")
                }
            }
            if maxLines > 0 && totalLines >= maxLines {
                print("📡 [receiveLines] Breaking: maxLines reached")
                break
            }

            if let tag = untilTag {
                if lines.contains(where: { $0.hasPrefix(tag + " OK") || $0.hasPrefix(tag + " NO") || $0.hasPrefix(tag + " BAD") }) {
                    print("📡 [receiveLines] Breaking: found tagged response for \(tag)")
                    break
                }
            }

            // If no tag and we received a continuation response (+), return immediately
            // This prevents deadlock when server waits for literal data
            if untilTag == nil && lines.contains(where: { $0.hasPrefix("+") }) {
                print("📡 [receiveLines] Breaking: found continuation (+)")
                break
            }
        }

        print("📡 [receiveLines] Loop ended, returning \(lines.count) lines")
        // Drain any remaining complete lines
        let _ = drainBufferToLines()
        if maxLines > 0 && lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
        }
        return lines
    }

    /// Receive the server greeting (untagged "* OK" or "* PREAUTH" line) with a hard timeout.
    /// This avoids waiting for a tagged response when opening a new IMAP connection.
    public func receiveGreeting(timeout: TimeInterval? = nil) async throws -> String {
        guard let c = conn, let cfg = config else { throw IMAPError.invalidState("receive without connection") }
        let hard = timeout ?? TimeInterval(max(3, cfg.commandTimeoutSec))
        var buffer = Data()
        let deadline = Date().addingTimeInterval(hard)

        while Date() < deadline {
            let data: Data? = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if let error {
                        cont.resume(throwing: self.mapNWError(error, context: "receive greeting"))
                        return
                    }
                    cont.resume(returning: data)
                }
            }
            guard let data, !data.isEmpty else { continue }
            buffer.append(data)

            // Look for first CRLF-terminated line
            if let crlf = "\r\n".data(using: .utf8), let range = buffer.range(of: crlf) {
                let lineData = buffer.prefix(upTo: range.lowerBound)
                let line = String(data: lineData, encoding: .utf8) ?? ""
                if line.hasPrefix("* OK") || line.hasPrefix("* PREAUTH") {
                    return line
                } else {
                    // Unexpected first line; treat as protocol error
                    throw IMAPError.receiveFailed("Unexpected greeting: \(line)")
                }
            }
        }
        throw IMAPError.connectTimeout("Greeting timeout after \(Int(hard))s")
    }

    // MARK: - Internals

    private func awaitReady(_ c: NWConnection, queue: DispatchQueue, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            func resume(_ result: Result<Void, Error>) {
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success:
                    cont.resume()
                case .failure(let e):
                    c.cancel()
                    cont.resume(throwing: e)
                }
            }

            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resume(.success(()))
                case .failed(let err):
                    resume(.failure(self.mapNWError(err, context: "connect \(self.peerDescription)")))
                case .waiting(let err):
                    resume(.failure(self.mapNWError(err, context: "connect waiting")))
                case .cancelled:
                    resume(.failure(IMAPError.connectFailed("cancelled")))
                default:
                    break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                resume(.failure(IMAPError.connectTimeout("connect timeout after \(Int(timeout))s")))
            }
        }
    }

    // Consistent mapping to IMAPError for UI-friendly diagnostics
    public func mapNWError(_ error: Error, context: String) -> IMAPError {
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code):
                switch code {
                case .ECONNREFUSED:
                    return .connectFailed("Connection refused (\(context))")
                case .ETIMEDOUT:
                    return .connectTimeout("Timeout (\(context))")
                case .ENETUNREACH, .EHOSTUNREACH:
                    return .networkUnreachable("Network/host unreachable (\(context))")
                case .ECONNRESET:
                    return .receiveFailed("Connection reset (\(context))")
                default:
                    return .receiveFailed("Network error \(code.rawValue) (\(context))")
                }
            case .dns(let e):
                return .networkUnreachable("DNS error \(e) (\(context))")
            default:
                return .connectFailed(nw.debugDescription)
            }
        }
        return .receiveFailed(error.localizedDescription)
    }
}

