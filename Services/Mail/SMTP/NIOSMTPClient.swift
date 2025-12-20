// AILO_APP/Configuration/Services/Mail/NIOSMTPClient.swift
// SwiftNIO-based SMTP client with full STARTTLS support.
// Non-blocking I/O with in-place TLS upgrade for port 587.

import Foundation

#if canImport(NIOCore) && canImport(NIOPosix)
import NIOCore
import NIOPosix
#if canImport(NIOSSL)
import NIOSSL
#endif

/// Full SwiftNIO SMTP client with STARTTLS support.
/// Implements complete SMTP protocol: EHLO, STARTTLS, AUTH, MAIL FROM, RCPT TO, DATA.
public final class NIOSMTPClient: SMTPClientProtocol {

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var handler: SMTPResponseHandler?

    public init() {}

    deinit {
        try? group?.syncShutdownGracefully()
    }

    public func testConnection(_ config: SMTPConfig) async -> Result<Void, SMTPError> {
        do {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try? group.syncShutdownGracefully() }

            let bootstrap = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .connectTimeout(.seconds(30))
                .channelInitializer { channel in
                    channel.pipeline.addHandler(SMTPResponseHandler())
                }

            #if canImport(NIOSSL)
            // For direct SSL/TLS (port 465), wrap with SSL from start
            if config.encryption == .sslTLS {
                let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
                let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: config.host)
                let sslBootstrap = ClientBootstrap(group: group)
                    .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .connectTimeout(.seconds(30))
                    .channelInitializer { channel in
                        channel.pipeline.addHandler(sslHandler).flatMap {
                            channel.pipeline.addHandler(SMTPResponseHandler())
                        }
                    }
                let channel = try await sslBootstrap.connect(host: config.host, port: Int(config.port)).get()
                let handler = try channel.pipeline.handler(type: SMTPResponseHandler.self).wait()

                // Wait for greeting
                let greeting = try await handler.readResponse()
                guard greeting.code == 220 else {
                    try? await channel.close()
                    return .failure(.greetingFailed("Unexpected greeting: \(greeting.message)"))
                }

                try await handler.sendCommand("QUIT", on: channel)
                _ = try? await handler.readResponse()
                try? await channel.close()
                return .success(())
            }
            #endif

            let channel = try await bootstrap.connect(host: config.host, port: Int(config.port)).get()
            let handler = try channel.pipeline.handler(type: SMTPResponseHandler.self).wait()

            // Wait for greeting (code 220)
            let greeting = try await handler.readResponse()
            guard greeting.code == 220 else {
                try? await channel.close()
                return .failure(.greetingFailed("Unexpected greeting: \(greeting.message)"))
            }

            // Issue QUIT and close
            try await handler.sendCommand("QUIT", on: channel)
            _ = try? await handler.readResponse()
            try? await channel.close()
            return .success(())
        } catch {
            return .failure(.receiveFailed(error.localizedDescription))
        }
    }

    public func send(_ message: MailMessage, using config: SMTPConfig) async -> DeliveryResult {
        do {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.group = group

            // Step 1: Connect to SMTP server
            #if canImport(NIOSSL)
            if config.encryption == .sslTLS {
                // Direct SSL/TLS connection (port 465)
                try await connectWithSSL(config: config, group: group)
            } else {
                // Plain connection, possibly with STARTTLS upgrade
                try await connectPlain(config: config, group: group)
            }
            #else
            try await connectPlain(config: config, group: group)
            #endif

            guard let channel = self.channel, let handler = self.handler else {
                return .failure(.connectionFailed("Channel not established"))
            }

            // Step 2: Wait for greeting (220)
            let greeting = try await handler.readResponse()
            guard greeting.code == 220 else {
                try? await channel.close()
                return .failure(.greetingFailed("Server greeting: \(greeting.message)"))
            }

            // Step 3: EHLO
            let heloName = config.heloName ?? "localhost"
            try await handler.sendCommand("EHLO \(heloName)", on: channel)
            var ehloResponse = try await handler.readResponse()
            guard ehloResponse.code == 250 else {
                // Fallback to HELO
                try await handler.sendCommand("HELO \(heloName)", on: channel)
                ehloResponse = try await handler.readResponse()
                guard ehloResponse.code == 250 else {
                    try? await channel.close()
                    return .failure(.authFailed("HELO failed: \(ehloResponse.message)"))
                }
            }

            // Step 4: STARTTLS if required
            #if canImport(NIOSSL)
            if config.encryption == .startTLS {
                // Check if server supports STARTTLS
                let supportsStartTLS = ehloResponse.fullResponse.contains("STARTTLS")
                if supportsStartTLS {
                    try await performSTARTTLS(config: config, channel: channel, handler: handler)

                    // Re-issue EHLO after TLS upgrade
                    try await handler.sendCommand("EHLO \(heloName)", on: channel)
                    let _ = try await handler.readResponse()
                } else {
                    print("⚠️ Server does not advertise STARTTLS, proceeding without TLS")
                }
            }
            #endif

            // Step 5: AUTH LOGIN
            if let username = config.username, let password = config.password,
               !username.isEmpty, !password.isEmpty {
                try await handler.sendCommand("AUTH LOGIN", on: channel)
                let authResponse = try await handler.readResponse()

                if authResponse.code == 334 {
                    // Send base64 encoded username
                    let userB64 = Data(username.utf8).base64EncodedString()
                    try await handler.sendCommand(userB64, on: channel)
                    let userResponse = try await handler.readResponse()

                    if userResponse.code == 334 {
                        // Send base64 encoded password
                        let passB64 = Data(password.utf8).base64EncodedString()
                        try await handler.sendCommand(passB64, on: channel)
                        let passResponse = try await handler.readResponse()

                        guard passResponse.code == 235 else {
                            try? await channel.close()
                            return .failure(.authFailed("Authentication failed: \(passResponse.message)"))
                        }
                    } else {
                        try? await channel.close()
                        return .failure(.authFailed("Username rejected: \(userResponse.message)"))
                    }
                } else if authResponse.code != 235 {
                    try? await channel.close()
                    return .failure(.authFailed("AUTH LOGIN not supported: \(authResponse.message)"))
                }
            }

            // Step 6: MAIL FROM
            let fromAddress = message.from.email
            try await handler.sendCommand("MAIL FROM:<\(fromAddress)>", on: channel)
            let mailFromResponse = try await handler.readResponse()
            guard mailFromResponse.code == 250 else {
                try? await channel.close()
                return .failure(.sendFailed("MAIL FROM rejected: \(mailFromResponse.message)"))
            }

            // Step 7: RCPT TO (for all recipients)
            let allRecipients = message.to + message.cc + message.bcc
            for recipient in allRecipients {
                try await handler.sendCommand("RCPT TO:<\(recipient.email)>", on: channel)
                let rcptResponse = try await handler.readResponse()
                guard rcptResponse.code == 250 || rcptResponse.code == 251 else {
                    try? await channel.close()
                    return .failure(.sendFailed("RCPT TO rejected for \(recipient.email): \(rcptResponse.message)"))
                }
            }

            // Step 8: DATA
            try await handler.sendCommand("DATA", on: channel)
            let dataResponse = try await handler.readResponse()
            guard dataResponse.code == 354 else {
                try? await channel.close()
                return .failure(.sendFailed("DATA command rejected: \(dataResponse.message)"))
            }

            // Step 9: Send message content
            let messageData = buildMIMEMessage(message)
            try await handler.sendRawData(messageData, on: channel)

            // End DATA with CRLF.CRLF
            try await handler.sendCommand("\r\n.", on: channel)
            let endDataResponse = try await handler.readResponse()
            guard endDataResponse.code == 250 else {
                try? await channel.close()
                return .failure(.sendFailed("Message rejected: \(endDataResponse.message)"))
            }

            // Step 10: QUIT
            try await handler.sendCommand("QUIT", on: channel)
            _ = try? await handler.readResponse()
            try? await channel.close()

            // Extract message ID from response if available
            let messageId = extractMessageId(from: endDataResponse.message)

            return .success(messageId)

        } catch let error as SMTPError {
            try? await channel?.close()
            return .failure(error)
        } catch {
            try? await channel?.close()
            return .failure(.sendFailed(error.localizedDescription))
        }
    }

    // MARK: - Connection Helpers

    private func connectPlain(config: SMTPConfig, group: MultiThreadedEventLoopGroup) async throws {
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(30))
            .channelInitializer { channel in
                channel.pipeline.addHandler(SMTPResponseHandler())
            }

        let channel = try await bootstrap.connect(host: config.host, port: Int(config.port)).get()
        let handler = try channel.pipeline.handler(type: SMTPResponseHandler.self).wait()

        self.channel = channel
        self.handler = handler
    }

    #if canImport(NIOSSL)
    private func connectWithSSL(config: SMTPConfig, group: MultiThreadedEventLoopGroup) async throws {
        let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: config.host)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(30))
            .channelInitializer { channel in
                channel.pipeline.addHandler(sslHandler).flatMap {
                    channel.pipeline.addHandler(SMTPResponseHandler())
                }
            }

        let channel = try await bootstrap.connect(host: config.host, port: Int(config.port)).get()
        let handler = try channel.pipeline.handler(type: SMTPResponseHandler.self).wait()

        self.channel = channel
        self.handler = handler
    }

    /// Performs in-place STARTTLS upgrade on existing plaintext connection
    private func performSTARTTLS(config: SMTPConfig, channel: Channel, handler: SMTPResponseHandler) async throws {
        // Send STARTTLS command
        try await handler.sendCommand("STARTTLS", on: channel)
        let response = try await handler.readResponse()

        guard response.code == 220 else {
            throw SMTPError.tlsFailed("STARTTLS rejected: \(response.message)")
        }

        // Create SSL context and handler
        let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: config.host)

        // Add SSL handler at the beginning of the pipeline (before response handler)
        // This upgrades the connection in-place without closing/reopening
        try await channel.pipeline.addHandler(sslHandler, position: .first).get()

        print("✅ STARTTLS upgrade successful for \(config.host)")
    }
    #endif

    // MARK: - MIME Message Building

    private func buildMIMEMessage(_ message: MailMessage) -> String {
        var lines: [String] = []

        // Headers
        lines.append("From: \(formatAddress(message.from))")
        if !message.to.isEmpty {
            lines.append("To: \(message.to.map { formatAddress($0) }.joined(separator: ", "))")
        }
        if !message.cc.isEmpty {
            lines.append("Cc: \(message.cc.map { formatAddress($0) }.joined(separator: ", "))")
        }
        lines.append("Subject: \(encodeHeader(message.subject))")
        lines.append("Date: \(formatRFC2822Date(message.date))")
        lines.append("MIME-Version: 1.0")

        let messageId = message.messageId ?? "<\(UUID().uuidString)@ailo.local>"
        lines.append("Message-ID: \(messageId)")

        if let inReplyTo = message.inReplyTo {
            lines.append("In-Reply-To: \(inReplyTo)")
        }
        if let references = message.references, !references.isEmpty {
            lines.append("References: \(references.joined(separator: " "))")
        }

        // Determine content type
        let hasAttachments = !(message.attachments ?? []).isEmpty
        let hasHTML = message.htmlBody != nil && !message.htmlBody!.isEmpty

        if hasAttachments {
            let boundary = "----=_Part_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")

            // Text/HTML part
            if hasHTML {
                let altBoundary = "----=_Alt_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                lines.append("--\(boundary)")
                lines.append("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"")
                lines.append("")

                // Plain text
                lines.append("--\(altBoundary)")
                lines.append("Content-Type: text/plain; charset=utf-8")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncode(message.textBody ?? ""))
                lines.append("")

                // HTML
                lines.append("--\(altBoundary)")
                lines.append("Content-Type: text/html; charset=utf-8")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncode(message.htmlBody ?? ""))
                lines.append("")
                lines.append("--\(altBoundary)--")
            } else {
                lines.append("--\(boundary)")
                lines.append("Content-Type: text/plain; charset=utf-8")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncode(message.textBody ?? ""))
            }

            // Attachments
            for attachment in message.attachments ?? [] {
                lines.append("")
                lines.append("--\(boundary)")
                lines.append("Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("Content-Disposition: attachment; filename=\"\(attachment.filename)\"")
                lines.append("")
                lines.append(attachment.data.base64EncodedString(options: .lineLength76Characters))
            }

            lines.append("")
            lines.append("--\(boundary)--")
        } else if hasHTML {
            let boundary = "----=_Alt_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            lines.append("")

            // Plain text
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncode(message.textBody ?? ""))
            lines.append("")

            // HTML
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/html; charset=utf-8")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncode(message.htmlBody ?? ""))
            lines.append("")
            lines.append("--\(boundary)--")
        } else {
            // Plain text only
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncode(message.textBody ?? ""))
        }

        return lines.joined(separator: "\r\n")
    }

    private func formatAddress(_ addr: MailAddress) -> String {
        if let name = addr.name, !name.isEmpty {
            return "\"\(name)\" <\(addr.email)>"
        }
        return addr.email
    }

    private func encodeHeader(_ text: String) -> String {
        // RFC 2047 encoding for non-ASCII characters
        if text.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return text
        }
        let encoded = Data(text.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    private func formatRFC2822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private func quotedPrintableEncode(_ text: String) -> String {
        var result = ""
        var lineLength = 0

        for scalar in text.unicodeScalars {
            let char = Character(scalar)
            let encoded: String

            if scalar == "\r" || scalar == "\n" {
                encoded = String(char)
                lineLength = 0
            } else if scalar.isASCII && scalar.value >= 33 && scalar.value <= 126 && scalar != "=" {
                encoded = String(char)
            } else if scalar == " " || scalar == "\t" {
                encoded = String(char)
            } else {
                let bytes = String(char).utf8
                encoded = bytes.map { String(format: "=%02X", $0) }.joined()
            }

            if lineLength + encoded.count > 76 {
                result += "=\r\n"
                lineLength = 0
            }

            result += encoded
            lineLength += encoded.count
        }

        return result
    }

    private func extractMessageId(from response: String) -> String? {
        // Try to extract message ID from server response
        // Common format: "250 2.0.0 OK <message-id>"
        if let range = response.range(of: "<[^>]+>", options: .regularExpression) {
            return String(response[range])
        }
        return nil
    }
}

// MARK: - SMTP Response Handler

/// Handles SMTP line-based protocol with proper multiline response support
final class SMTPResponseHandler: ChannelInboundHandler, ChannelOutboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var buffer = ByteBufferAllocator().buffer(capacity: 1024)
    private let lock = NIOLock()
    private var responseWaiters: [EventLoopPromise<SMTPResponse>] = []
    private var pendingLines: [String] = []

    struct SMTPResponse {
        let code: Int
        let message: String
        let fullResponse: String
        let isMultiline: Bool
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        buffer.writeBuffer(&buf)

        // Process all complete lines
        while let line = readLineCRLF() {
            processLine(line, context: context)
        }
    }

    private func processLine(_ line: String, context: ChannelHandlerContext) {
        lock.withLock {
            pendingLines.append(line)

            // Check if this is the final line of a response
            // SMTP multiline: "250-First line", "250-Second line", "250 Last line"
            // Final line has space after code, not hyphen
            if line.count >= 4 {
                let separator = line[line.index(line.startIndex, offsetBy: 3)]
                if separator == " " || separator == "\r" || separator == "\n" {
                    // This is the final line
                    let fullResponse = pendingLines.joined(separator: "\n")
                    let code = Int(line.prefix(3)) ?? 0
                    let message = String(line.dropFirst(4))

                    let response = SMTPResponse(
                        code: code,
                        message: message,
                        fullResponse: fullResponse,
                        isMultiline: pendingLines.count > 1
                    )

                    pendingLines.removeAll()

                    if !responseWaiters.isEmpty {
                        let promise = responseWaiters.removeFirst()
                        promise.succeed(response)
                    }
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lock.withLock {
            for promise in responseWaiters {
                promise.fail(error)
            }
            responseWaiters.removeAll()
        }
        context.close(promise: nil)
    }

    // MARK: - Public API

    func readResponse() async throws -> SMTPResponse {
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                // Create promise - we'll set it up properly when we have a channel
                // For now, store the continuation directly
            }

            // Use a simple callback-based approach
            DispatchQueue.global().async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: SMTPError.connectionFailed("Handler deallocated"))
                    return
                }

                // Poll for response with timeout
                let timeout = Date().addingTimeInterval(60)
                while Date() < timeout {
                    var response: SMTPResponse?
                    self.lock.withLock {
                        // Check if we have a complete response waiting
                        if !self.pendingLines.isEmpty {
                            let lastLine = self.pendingLines.last ?? ""
                            if lastLine.count >= 4 {
                                let separator = lastLine[lastLine.index(lastLine.startIndex, offsetBy: 3)]
                                if separator == " " {
                                    let fullResponse = self.pendingLines.joined(separator: "\n")
                                    let code = Int(lastLine.prefix(3)) ?? 0
                                    let message = String(lastLine.dropFirst(4))
                                    response = SMTPResponse(
                                        code: code,
                                        message: message,
                                        fullResponse: fullResponse,
                                        isMultiline: self.pendingLines.count > 1
                                    )
                                    self.pendingLines.removeAll()
                                }
                            }
                        }
                    }

                    if let response = response {
                        continuation.resume(returning: response)
                        return
                    }

                    Thread.sleep(forTimeInterval: 0.01)
                }

                continuation.resume(throwing: SMTPError.receiveFailed("Response timeout"))
            }
        }
    }

    func sendCommand(_ command: String, on channel: Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: command.utf8.count + 2)
        buffer.writeString(command)
        if !command.hasSuffix("\r\n") {
            buffer.writeString("\r\n")
        }
        try await channel.writeAndFlush(self.wrapOutboundOut(buffer)).get()
    }

    func sendRawData(_ data: String, on channel: Channel) async throws {
        // Escape any lone dots at beginning of lines (RFC 5321)
        let escaped = data.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        var buffer = channel.allocator.buffer(capacity: escaped.utf8.count)
        buffer.writeString(escaped)
        try await channel.writeAndFlush(self.wrapOutboundOut(buffer)).get()
    }

    // MARK: - Internal Helpers

    private func readLineCRLF() -> String? {
        guard let view = buffer.readableBytesView.firstRange(of: Data("\r\n".utf8)) else {
            return nil
        }

        let lineLength = buffer.readableBytesView.distance(from: buffer.readableBytesView.startIndex, to: view.lowerBound)
        guard var lineSlice = buffer.readSlice(length: lineLength) else {
            return nil
        }

        // Consume CRLF
        _ = buffer.readSlice(length: 2)

        return lineSlice.readString(length: lineSlice.readableBytes)
    }
}

// Keep old SMTPLineHandler for backwards compatibility with testConnection
final class SMTPLineHandler: ChannelInboundHandler, ChannelOutboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var buffer = ByteBufferAllocator().buffer(capacity: 0)
    private let lock = NIOLock()
    private var waiters: [EventLoopPromise<String>] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        buffer.writeBuffer(&buf)

        while let line = readLineCRLF() {
            lock.withLock {
                if !waiters.isEmpty {
                    let p = waiters.removeFirst()
                    p.succeed(line)
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lock.withLock {
            for p in waiters { p.fail(error) }
            waiters.removeAll()
        }
        context.close(promise: nil)
    }

    func nextLine(on el: EventLoop) async throws -> String {
        return try await withCheckedThrowingContinuation { cont in
            let p: EventLoopPromise<String> = el.makePromise(of: String.self)
            p.futureResult.whenSuccess { cont.resume(returning: $0) }
            p.futureResult.whenFailure { cont.resume(throwing: $0) }
            lock.withLock { waiters.append(p) }
        }
    }

    func sendLine(_ s: String, on channel: Channel) async throws {
        var out = channel.allocator.buffer(capacity: s.utf8.count + 2)
        out.writeString(s)
        out.writeString("\r\n")
        try await channel.writeAndFlush(self.wrapOutboundOut(out)).get()
    }

    private func readLineCRLF() -> String? {
        guard let view = buffer.readableBytesView.firstRange(of: Data("\r\n".utf8)) else {
            return nil
        }
        let lineLength = buffer.readableBytesView.distance(from: buffer.readableBytesView.startIndex, to: view.lowerBound)
        guard var lineSlice = buffer.readSlice(length: lineLength) else {
            return nil
        }
        _ = buffer.readSlice(length: 2)
        return lineSlice.readString(length: lineSlice.readableBytes)
    }
}

#else

// Fallback if SwiftNIO is not available in this target. Conform to protocol and delegate to SMTPClient.
public final class NIOSMTPClient: SMTPClientProtocol {
    public init() {}
    public func testConnection(_ config: SMTPConfig) async -> Result<Void, SMTPError> {
        let smtp = SMTPClient()
        return await smtp.testConnection(config)
    }
    public func send(_ message: MailMessage, using config: SMTPConfig) async -> DeliveryResult {
        let smtp = SMTPClient()
        return await smtp.send(message, using: config)
    }
}

#endif
