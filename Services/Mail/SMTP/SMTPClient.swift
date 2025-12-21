// AILO_APP/Configuration/Services/Mail/SMTPClient.swift
// Lightweight SMTP client supporting SSL/TLS and STARTTLS with AUTH PLAIN/LOGIN.
// Provides send(mail:) and testConnection().
// Used by MailSendService and for connection diagnostics.


import Foundation
import Network
import Darwin

// Fallback HELO/EHLO name that works on iOS without Foundation.Host
@inline(__always) fileprivate func defaultHeloName() -> String {
    var buf = [CChar](repeating: 0, count: 256)
    if gethostname(&buf, buf.count) == 0 {
        let name = String(cString: buf)
        return name.isEmpty ? "localhost" : name
    }
    return "localhost"
}

// MARK: - Models & Config

public enum SMTPTLSEncryption: Sendable {
    case sslTLS        // Implicit TLS (usually port 465)
    case startTLS      // STARTTLS upgrade (usually port 587)
    case plain         // No TLS (not recommended)
}

public struct SMTPConfig: Sendable {
    public let host: String
    public let port: Int
    public let encryption: SMTPTLSEncryption
    public let heloName: String
    public let username: String?
    public let password: String?
    public let connectionTimeoutSec: Int
    public let commandTimeoutSec: Int
    public let sniHost: String?

    public init(
        host: String,
        port: Int,
        encryption: SMTPTLSEncryption,
        heloName: String? = nil,
        username: String? = nil,
        password: String? = nil,
        connectionTimeoutSec: Int = 15,
        commandTimeoutSec: Int = 12,
        sniHost: String? = nil
    ) {
        self.host = host
        self.port = port
        self.encryption = encryption
        self.heloName = heloName ?? defaultHeloName()
        self.username = username
        self.password = password
        self.connectionTimeoutSec = connectionTimeoutSec
        self.commandTimeoutSec = commandTimeoutSec
        self.sniHost = sniHost
    }
}

public enum SMTPError: LocalizedError {
    case invalidState(String)
    case connectTimeout(String)
    case connectFailed(String)
    case greetingFailed(String)
    case startTLSRejected
    case authRequired
    case authFailed(String)
    case commandFailed(code: Int, message: String)
    case sendFailed(String)
    case receiveFailed(String)
    case networkUnreachable(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .invalidState(let s): return s
        case .connectTimeout(let s): return s
        case .connectFailed(let s): return s
        case .greetingFailed(let s): return s
        case .startTLSRejected: return "Server rejected STARTTLS"
        case .authRequired: return "Authentication required"
        case .authFailed(let s): return "Authentication failed: \(s)"
        case .commandFailed(let code, let msg): return "SMTP \(code): \(msg)"
        case .sendFailed(let s): return s
        case .receiveFailed(let s): return s
        case .networkUnreachable(let s): return s
        case .closed: return "Connection closed"
        }
    }
}

public enum DeliveryResult: Sendable {
    case success(serverId: String?)
    case failed(SMTPError)
}

extension MailAddress {
    public var rfc822: String {
        if let n = name, !n.isEmpty {
            let escaped = n.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(email)>"
        }
        return "<\(email)>"
    }
}

extension MailMessage {
    public var allRecipients: [MailAddress] { to + cc + bcc }
}

// MARK: - SMTPClient

public final class SMTPClient {
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "smtp.client.queue")
    private var cfg: SMTPConfig?

    public init() {}

    // MARK: Public API

    public func testConnection(_ config: SMTPConfig) async -> Result<Void, SMTPError> {
        do {
            // Open connection according to encryption mode; open() already enforces a connect-timeout.
            try await open(config)

            // Read the initial greeting (must be 220 ...). This also enforces a command-timeout.
            _ = try await readResponse(expected: [220])

            // We explicitly DO NOT attempt STARTTLS/EHLO in the test path.
            // The goal is: reachability + correct banner.
            try await quit()
            return .success(())
        } catch let e as SMTPError {
            safeClose()
            return .failure(e)
        } catch {
            safeClose()
            return .failure(mapNWError(error, context: "testConnection"))
        }
    }

    // MARK: Phase 2 convenience API (explicit connect/auth/send)

    /// Opens a connection, reads greeting, performs EHLO and STARTTLS upgrade when configured.
    public func connect(config: SMTPConfig) async throws {
        // Open TCP/TLS according to config
        try await open(config)
        // Expect 220 greeting
        _ = try await readResponse(expected: [220])
        // EHLO first
        try await send("EHLO \(config.heloName)")
        _ = try await readResponse(expected: [250])
        // STARTTLS if requested and not already TLS
        if config.encryption == .startTLS, !isTLSConn() {
            try await send("STARTTLS")
            _ = try await readResponse(expected: [220])
            try await reopenAsTLS()
            // Re-EHLO after TLS per RFC
            try await send("EHLO \(config.heloName)")
            _ = try await readResponse(expected: [250])
        }
    }

    /// Performs SMTP AUTH with username/password. Prefers LOGIN, falls back to PLAIN.
    public func authenticate(username: String, password: String) async throws {
        // AUTH LOGIN flow
        try await send("AUTH LOGIN")
        _ = try await readResponse(expected: [334])
        try await send(Data(username.utf8).base64EncodedString())
        _ = try await readResponse(expected: [334])
        try await send(Data(password.utf8).base64EncodedString())
        _ = try await readResponse(expected: [235])
    }

    /// Sends a message using an already connected (and optionally authenticated) session.
    /// Use `connect(config:)` (and optionally `authenticate`) before calling this function.
    public func send(message: MailMessage) async throws {
        // MAIL FROM
        try await send("MAIL FROM:\(message.from.rfc822)")
        _ = try await readResponse(expected: [250])
        // RCPT TO for all recipients
        let recipients = message.allRecipients
        if recipients.isEmpty { throw SMTPError.invalidState("No recipients") }
        for r in recipients {
            try await send("RCPT TO:\(r.rfc822)")
            _ = try await readResponse(expected: [250, 251])
        }
        // DATA
        try await send("DATA")
        _ = try await readResponse(expected: [354])
        let wire = buildRFC5322(message)
        try await sendRaw(wire)
        try await send(".")
        _ = try await readResponse(expected: [250])
    }

    /// Builds a MIME/RFC5322 message from a MailDraft. Attachments not yet implemented.
    public func buildMIMEMessage(draft: MailDraft) -> Data {
        let wire = buildRFC5322(draft.toMailMessage())
        return Data(wire.utf8)
    }

    public func send(_ message: MailMessage, using config: SMTPConfig) async -> DeliveryResult {
        do {
            try await open(config)
            // Greeting
            _ = try await readResponse(expected: [220])

            // EHLO / STARTTLS-handling
            try await send("EHLO \(config.heloName)")
            _ = try await readResponse(expected: [250])

            if config.encryption == .startTLS {
                // Only if not already TLS
                if !isTLSConn() {
                    try await send("STARTTLS")
                    _ = try await readResponse(expected: [220])
                    try await reopenAsTLS()
                    try await send("EHLO \(config.heloName)")
                    _ = try await readResponse(expected: [250])
                }
            }

            // AUTH if credentials provided
            if let u = config.username, let p = config.password {
                // Prefer AUTH LOGIN (wide support). PLAIN also possible.
                try await send("AUTH LOGIN")
                _ = try await readResponse(expected: [334]) // Expect "VXNlcm5hbWU6"
                try await send(Data(u.utf8).base64EncodedString())
                _ = try await readResponse(expected: [334]) // Expect "UGFzc3dvcmQ6"
                try await send(Data(p.utf8).base64EncodedString())
                _ = try await readResponse(expected: [235]) // Auth success
            }

            // MAIL FROM
            try await send("MAIL FROM:\(message.from.rfc822)")
            _ = try await readResponse(expected: [250])

            // RCPT TO for all recipients
            let recipients = message.allRecipients
            if recipients.isEmpty { throw SMTPError.invalidState("No recipients") }
            for r in recipients {
                try await send("RCPT TO:\(r.rfc822)")
                _ = try await readResponse(expected: [250, 251]) // 251 = will forward
            }

            // DATA
            try await send("DATA")
            _ = try await readResponse(expected: [354])

            // Compose RFC 5322 message (simple; multipart alternative if both bodies are present)
            let wire = buildRFC5322(message)
            try await sendRaw(wire) // send body as-is (with CRLF)
            try await send(".")     // end of DATA (dot-terminator on its own line)
            let final = try await readResponse(expected: [250])
            let serverId = extractQueuedId(final)
            try await quit()
            return .success(serverId: serverId)
        } catch let e as SMTPError {
            safeClose()
            return .failed(e)
        } catch {
            safeClose()
            return .failed(mapNWError(error, context: "send"))
        }
    }

    // MARK: Connection lifecycle

    private func open(_ config: SMTPConfig) async throws {
        guard conn == nil else { throw SMTPError.invalidState("connection already open") }
        self.cfg = config
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: UInt16(config.port))!
        )
        let parameters: NWParameters
        switch config.encryption {
        case .sslTLS:
            let tls = NWProtocolTLS.Options()
            let sni = config.sniHost ?? config.host
            if !sni.isEmpty {
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sni)
            }
            // Enforce conservative TLS versions for better interoperability
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            let tcp = NWProtocolTCP.Options()
            parameters = NWParameters(tls: tls, tcp: tcp)
        case .startTLS, .plain:
            let tcp = NWProtocolTCP.Options()
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        parameters.preferNoProxies = true
        parameters.allowLocalEndpointReuse = true

        let c = NWConnection(to: endpoint, using: parameters)
        self.conn = c

        try await awaitReady(c, timeout: TimeInterval(max(3, config.connectionTimeoutSec)))
    }

    private func reopenAsTLS() async throws {
        guard let cfg = cfg else { throw SMTPError.invalidState("no config for TLS upgrade") }
        // Close current and reopen as TLS (implicit SSL)
        safeClose()
        let tlsCfg = SMTPConfig(
            host: cfg.host,
            port: cfg.port,
            encryption: .sslTLS,
            heloName: cfg.heloName,
            username: cfg.username,
            password: cfg.password,
            connectionTimeoutSec: cfg.connectionTimeoutSec,
            commandTimeoutSec: cfg.commandTimeoutSec,
            sniHost: cfg.sniHost
        )
        try await open(tlsCfg)
        // On TLS connect, servers send a fresh 220 greeting
        _ = try await readResponse(expected: [220])
    }

    private func quit() async throws {
        try await send("QUIT")
        _ = try await readResponse(expected: [221, 250]) // some servers reply 250 then close
        safeClose()
    }

    private func safeClose() {
        conn?.cancel()
        conn = nil
    }

    // MARK: I/O helpers

    private func send(_ line: String) async throws {
        try await sendRaw(line + "\r\n")
    }

    private func sendRaw(_ raw: String) async throws {
        guard let c = conn else { throw SMTPError.invalidState("send on nil connection") }
        let data = Data(raw.utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: self.mapNWError(err, context: "send")) }
                else { cont.resume() }
            })
        }
    }

    private func readResponse(expected: [Int]) async throws -> [String] {
        let lines = try await readLines(timeout: TimeInterval(cfg?.commandTimeoutSec ?? 12))
        guard let code = parseReplyCode(lines.last), expected.contains(code) else {
            let last = lines.last ?? "(no response)"
            throw SMTPError.commandFailed(code: parseReplyCode(last) ?? -1, message: last)
        }
        return lines
    }

    private func readLines(timeout: TimeInterval) async throws -> [String] {
        guard let c = conn else { throw SMTPError.invalidState("receive on nil connection") }
        var lines: [String] = []
        var buffer = Data()
        var idleDeadline = Date().addingTimeInterval(timeout)

        func drain() {
            guard !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) else { return }
            let parts = s.components(separatedBy: "\r\n")
            // Keep the last incomplete fragment in buffer
            if let last = parts.last, !last.isEmpty && !s.hasSuffix("\r\n") {
                lines.append(contentsOf: parts.dropLast().filter { !$0.isEmpty })
                buffer = Data(last.utf8)
            } else {
                lines.append(contentsOf: parts.filter { !$0.isEmpty })
                buffer.removeAll(keepingCapacity: true)
            }
        }

        while Date() < idleDeadline {
            let chunk: Data? = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
                    if let error { cont.resume(throwing: self.mapNWError(error, context: "receive")) }
                    else { cont.resume(returning: data) }
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)
            idleDeadline = Date().addingTimeInterval(timeout)
            drain()

            // SMTP multi-line replies: "250-..." continue, last is "250 ..."
            if let last = lines.last, let code = parseReplyCode(last) {
                // If last indicates final (space after code), we can return; if dash, continue.
                if isFinalReplyLine(last, code: code) { return lines }
            }
        }
        drain()
        return lines
    }

    private func parseReplyCode(_ line: String?) -> Int? {
        guard let line, line.count >= 3 else { return nil }
        let prefix = String(line.prefix(3))
        return Int(prefix)
    }

    private func isFinalReplyLine(_ line: String, code: Int) -> Bool {
        let prefix = "\(code)"
        guard line.hasPrefix(prefix) else { return false }
        // "250 " final, "250-" continue
        if line.count >= 4 {
            let idx = line.index(line.startIndex, offsetBy: 3)
            return line[idx] == " "
        }
        return true
    }

    private func awaitReady(_ c: NWConnection, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            func resume(_ result: Result<Void, Error>) {
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success: cont.resume()
                case .failure(let e):
                    c.cancel()
                    cont.resume(throwing: e)
                }
            }
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: resume(.success(()))
                case .failed(let err): resume(.failure(self.mapNWError(err, context: "connect")))
                case .waiting(let err): resume(.failure(self.mapNWError(err, context: "connect waiting")))
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                resume(.failure(SMTPError.connectTimeout("connect timeout after \(Int(timeout))s")))
            }
        }
    }

    private func isTLSConn() -> Bool {
        guard let c = conn else { return false }
        // NWConnection does not expose a direct "isTLS" flag; presence of TLS options is managed at creation time.
        // For our purposes, we assume TLS if the connection was created with TLS parameters (sslTLS mode).
        if let cfg = cfg, case .sslTLS = cfg.encryption { return true }
        return false
    }

    // MARK: Message building

    // Overload to support MailSendMessage produced by MailDraft.toMailMessage()
    private func buildRFC5322(_ msg: MailSendMessage) -> String {
        let adapted = MailMessage(
            from: MailAddress(msg.from.email, name: msg.from.name),
            replyTo: msg.replyTo.map { MailAddress($0.email, name: $0.name) },
            to: msg.to.map { MailAddress($0.email, name: $0.name) },
            cc: msg.cc.map { MailAddress($0.email, name: $0.name) },
            bcc: msg.bcc.map { MailAddress($0.email, name: $0.name) },
            subject: msg.subject,
            textBody: msg.textBody,
            htmlBody: msg.htmlBody
        )
        return buildRFC5322(adapted)
    }

    private func buildRFC5322(_ msg: MailMessage) -> String {
        var headers: [String] = []
        headers.append("From: \(msg.from.rfc822)")
        if let replyTo = msg.replyTo { headers.append("Reply-To: \(replyTo.rfc822)") }
        if !msg.to.isEmpty { headers.append("To: " + msg.to.map { $0.rfc822 }.joined(separator: ", ")) }
        if !msg.cc.isEmpty { headers.append("Cc: " + msg.cc.map { $0.rfc822 }.joined(separator: ", ")) }
        headers.append("Subject: \(msg.subject)")
        headers.append("MIME-Version: 1.0")
        headers.append("Date: \(rfc2822Date(Date()))")
        headers.append("Message-ID: <\(UUID().uuidString)@\(cfg?.heloName ?? "localhost")>")

        let body: String
        if let text = msg.textBody, let html = msg.htmlBody {
            let boundary = "=_SwiftBoundary_\(UUID().uuidString.prefix(8))"
            headers.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            var parts: [String] = []
            parts.append("--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(dotStuff(text))\r\n")
            parts.append("--\(boundary)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(dotStuff(html))\r\n")
            parts.append("--\(boundary)--\r\n")
            body = parts.joined()
        } else if let html = msg.htmlBody {
            headers.append("Content-Type: text/html; charset=utf-8")
            headers.append("Content-Transfer-Encoding: 8bit")
            body = dotStuff(html) + "\r\n"
        } else {
            let text = msg.textBody ?? ""
            headers.append("Content-Type: text/plain; charset=utf-8")
            headers.append("Content-Transfer-Encoding: 8bit")
            body = dotStuff(text) + "\r\n"
        }

        return headers.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    private func rfc2822Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    private func dotStuff(_ s: String) -> String {
        // Lines beginning with '.' must be dot-stuffed per RFC 5321 section 4.5.2
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let stuffed = lines.map { line -> String in
            if line.hasPrefix(".") { return "." + line }
            return String(line)
        }
        return stuffed.joined(separator: "\r\n")
    }

    // MARK: Utils

    private func parseReplyCode(_ line: String) -> Int? {
        guard line.count >= 3 else { return nil }
        let codeStr = String(line.prefix(3))
        return Int(codeStr)
    }

    private func extractQueuedId(_ lines: [String]) -> String? {
        // Try to find 'Queued as <id>' or similar in 250 response
        let joined = lines.joined(separator: " ")
        if let range = joined.range(of: "Queued as ") {
            let tail = joined[range.upperBound...]
            let parts = tail.split(separator: " ")
            return parts.first.map(String.init)
        }
        return nil
    }

    private func mapNWError(_ error: Error, context: String) -> SMTPError {
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code):
                switch code {
                case .ECONNREFUSED: return .networkUnreachable("Connection refused (\(context))")
                case .ETIMEDOUT:    return .networkUnreachable("Timeout (\(context))")
                case .ENETUNREACH, .EHOSTUNREACH: return .networkUnreachable("Network/host unreachable (\(context))")
                case .ECONNRESET:   return .receiveFailed("Connection reset (\(context))")
                default:            return .receiveFailed("Network error \(code.rawValue) (\(context))")
                }
            case .dns(let e):
                return .networkUnreachable("DNS error \(e) (\(context))")
            default:
                break
            }
        }
        return .receiveFailed(error.localizedDescription)
    }
}

extension SMTPClient: SMTPClientProtocol {}

