// AILO_APP/Configuration/Services/Mail/NIOSMTPClient.swift
// SwiftNIO-based SMTP client with full STARTTLS support.
// Non-blocking I/O with in-place TLS upgrade for port 587.

import Foundation

#if canImport(NIOCore) && canImport(NIOPosix)
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
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
        print("🔧 [NIO-SMTP] Starting send via NIOSMTPClient")
        print("🔧 [NIO-SMTP] Host: \(config.host):\(config.port)")
        print("🔧 [NIO-SMTP] Encryption: \(config.encryption)")
        #if canImport(NIOSSL)
        print("🔧 [NIO-SMTP] NIOSSL is available ✅")
        #else
        print("⚠️ [NIO-SMTP] NIOSSL is NOT available - STARTTLS won't work!")
        #endif

        do {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.group = group

            // Step 1: Connect to SMTP server
            print("🔧 [NIO-SMTP] Step 1: Connecting to server...")
            #if canImport(NIOSSL)
            if config.encryption == .sslTLS {
                // Direct SSL/TLS connection (port 465)
                try await connectWithSSL(config: config, group: group)
                print("🔧 [NIO-SMTP] Step 1: Connected with SSL/TLS")
            } else {
                // Plain connection, possibly with STARTTLS upgrade
                try await connectPlain(config: config, group: group)
                print("🔧 [NIO-SMTP] Step 1: Connected (plain)")
            }
            #else
            try await connectPlain(config: config, group: group)
            print("🔧 [NIO-SMTP] Step 1: Connected (plain, no NIOSSL)")
            #endif

            guard let channel = self.channel, let handler = self.handler else {
                print("❌ [NIO-SMTP] Channel not established!")
                return .failed(.connectFailed("Channel not established"))
            }

            // Step 2: Wait for greeting (220)
            let greeting = try await handler.readResponse()
            print("🔧 [NIO-SMTP] Step 2: Greeting received: \(greeting.code) \(greeting.message)")
            guard greeting.code == 220 else {
                try? await channel.close()
                return .failed(.greetingFailed("Server greeting: \(greeting.message)"))
            }

            // Step 3: EHLO
            let heloName = config.heloName ?? "localhost"
            try await handler.sendCommand("EHLO \(heloName)", on: channel)
            var ehloResponse = try await handler.readResponse()
            print("🔧 [NIO-SMTP] Step 3: EHLO response: \(ehloResponse.code)")
            if ehloResponse.code != 250 {
                // Fallback to HELO
                try await handler.sendCommand("HELO \(heloName)", on: channel)
                ehloResponse = try await handler.readResponse()
                guard ehloResponse.code == 250 else {
                    try? await channel.close()
                    return .failed(.authFailed("HELO failed: \(ehloResponse.message)"))
                }
            }

            // Step 4: STARTTLS if required
            #if canImport(NIOSSL)
            if config.encryption == .startTLS {
                print("🔧 [NIO-SMTP] Step 4: Attempting STARTTLS upgrade...")
                // Check if server supports STARTTLS
                let supportsStartTLS = ehloResponse.fullResponse.contains("STARTTLS")
                print("🔧 [NIO-SMTP] Server advertises STARTTLS: \(supportsStartTLS)")
                if supportsStartTLS {
                    try await performSTARTTLS(config: config, channel: channel, handler: handler)
                    print("✅ [NIO-SMTP] Step 4: STARTTLS upgrade successful!")

                    // Re-issue EHLO after TLS upgrade
                    try await handler.sendCommand("EHLO \(heloName)", on: channel)
                    let _ = try await handler.readResponse()
                    print("🔧 [NIO-SMTP] Step 4: Post-TLS EHLO completed")
                } else {
                    print("⚠️ [NIO-SMTP] Server does not advertise STARTTLS, proceeding without TLS")
                }
            }
            #else
            if config.encryption == .startTLS {
                print("❌ [NIO-SMTP] STARTTLS requested but NIOSSL not available!")
            }
            #endif

            // Step 5: AUTH LOGIN
            print("🔧 [NIO-SMTP] Step 5: Starting authentication...")
            if let username = config.username, let password = config.password,
               !username.isEmpty, !password.isEmpty {
                print("🔧 [NIO-SMTP] Step 5: Sending AUTH LOGIN")
                try await handler.sendCommand("AUTH LOGIN", on: channel)
                let authResponse = try await handler.readResponse()
                print("🔧 [NIO-SMTP] Step 5: AUTH response: \(authResponse.code)")

                if authResponse.code == 334 {
                    // Send base64 encoded username
                    let userB64 = Data(username.utf8).base64EncodedString()
                    try await handler.sendCommand(userB64, on: channel)
                    let userResponse = try await handler.readResponse()
                    print("🔧 [NIO-SMTP] Step 5: Username response: \(userResponse.code)")

                    if userResponse.code == 334 {
                        // Send base64 encoded password
                        let passB64 = Data(password.utf8).base64EncodedString()
                        try await handler.sendCommand(passB64, on: channel)
                        let passResponse = try await handler.readResponse()
                        print("🔧 [NIO-SMTP] Step 5: Password response: \(passResponse.code)")

                        guard passResponse.code == 235 else {
                            print("❌ [NIO-SMTP] Authentication failed: \(passResponse.message)")
                            try? await channel.close()
                            return .failed(.authFailed("Authentication failed: \(passResponse.message)"))
                        }
                        print("✅ [NIO-SMTP] Step 5: Authentication successful!")
                    } else {
                        print("❌ [NIO-SMTP] Username rejected: \(userResponse.message)")
                        try? await channel.close()
                        return .failed(.authFailed("Username rejected: \(userResponse.message)"))
                    }
                } else if authResponse.code != 235 {
                    print("❌ [NIO-SMTP] AUTH LOGIN not supported: \(authResponse.message)")
                    try? await channel.close()
                    return .failed(.authFailed("AUTH LOGIN not supported: \(authResponse.message)"))
                }
            } else {
                print("🔧 [NIO-SMTP] Step 5: Skipping auth (no credentials)")
            }

            // Step 6: MAIL FROM
            let fromAddress = message.from.email
            print("🔧 [NIO-SMTP] Step 6: MAIL FROM <\(fromAddress)>")
            try await handler.sendCommand("MAIL FROM:<\(fromAddress)>", on: channel)
            let mailFromResponse = try await handler.readResponse()
            guard mailFromResponse.code == 250 else {
                print("❌ [NIO-SMTP] MAIL FROM rejected: \(mailFromResponse.message)")
                try? await channel.close()
                return .failed(.sendFailed("MAIL FROM rejected: \(mailFromResponse.message)"))
            }

            // Step 7: RCPT TO (for all recipients)
            let allRecipients = message.to + message.cc + message.bcc
            print("🔧 [NIO-SMTP] Step 7: RCPT TO for \(allRecipients.count) recipients")
            for recipient in allRecipients {
                try await handler.sendCommand("RCPT TO:<\(recipient.email)>", on: channel)
                let rcptResponse = try await handler.readResponse()
                guard rcptResponse.code == 250 || rcptResponse.code == 251 else {
                    print("❌ [NIO-SMTP] RCPT TO rejected for \(recipient.email): \(rcptResponse.message)")
                    try? await channel.close()
                    return .failed(.sendFailed("RCPT TO rejected for \(recipient.email): \(rcptResponse.message)"))
                }
            }

            // Step 8: DATA
            print("🔧 [NIO-SMTP] Step 8: Sending DATA command")
            try await handler.sendCommand("DATA", on: channel)
            let dataResponse = try await handler.readResponse()
            guard dataResponse.code == 354 else {
                print("❌ [NIO-SMTP] DATA command rejected: \(dataResponse.message)")
                try? await channel.close()
                return .failed(.sendFailed("DATA command rejected: \(dataResponse.message)"))
            }

            // Step 9: Send message content
            print("🔧 [NIO-SMTP] Step 9: Sending message content...")
            let messageData = buildMIMEMessage(message)
            try await handler.sendRawData(messageData, on: channel)

            // End DATA with CRLF.CRLF
            try await handler.sendCommand("\r\n.", on: channel)
            let endDataResponse = try await handler.readResponse()
            guard endDataResponse.code == 250 else {
                print("❌ [NIO-SMTP] Message rejected: \(endDataResponse.message)")
                try? await channel.close()
                return .failed(.sendFailed("Message rejected: \(endDataResponse.message)"))
            }
            print("✅ [NIO-SMTP] Step 9: Message accepted by server")

            // Step 10: QUIT
            print("🔧 [NIO-SMTP] Step 10: Sending QUIT")
            try await handler.sendCommand("QUIT", on: channel)
            _ = try? await handler.readResponse()
            try? await channel.close()

            // Extract message ID from response if available
            let messageId = extractMessageId(from: endDataResponse.message)
            print("✅ [NIO-SMTP] Send completed successfully! MessageID: \(messageId ?? "none")")

            return .success(serverId: messageId)

        } catch let error as SMTPError {
            print("❌ [NIO-SMTP] SMTPError: \(error)")
            try? await channel?.close()
            return .failed(error)
        } catch {
            print("❌ [NIO-SMTP] General error: \(error)")
            print("❌ [NIO-SMTP] Error type: \(type(of: error))")
            print("❌ [NIO-SMTP] Error description: \(error.localizedDescription)")
            try? await channel?.close()
            return .failed(.sendFailed(error.localizedDescription))
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
            throw SMTPError.startTLSRejected
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
        // Check if S/MIME signing is requested
        if let certId = message.signingCertificateId, !certId.isEmpty {
            print("🔐 [NIO-SMTP] S/MIME signing requested with certificate: \(certId.prefix(16))...")
            return buildSignedMIMEMessage(message, certificateId: certId)
        }
        return buildUnsignedMIMEMessage(message)
    }

    /// Builds a signed MIME message using S/MIME
    private func buildSignedMIMEMessage(_ message: MailMessage, certificateId: String) -> String {
        // Build the inner MIME content to be signed (body only, no outer headers)
        let innerContent = buildInnerMIMEContent(message)
        let innerData = Data(innerContent.utf8)

        // DEBUG: Log the inner content before signing
        print("🔐 [NIO-SMTP S/MIME] === INNER CONTENT BEFORE SIGNING ===")
        print("🔐 [NIO-SMTP S/MIME] Inner content length: \(innerData.count) bytes")
        if innerData.count <= 500 {
            print("🔐 [NIO-SMTP S/MIME] Inner content (escaped):")
            print(innerContent.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n\n"))
        }

        // Sign the content using SMIMESigningService
        let result = SMIMESigningService.shared.signMessage(
            mimeContent: innerData,
            certificateId: certificateId
        )

        switch result {
        case .success(let signedData):
            print("✅ [NIO-SMTP] S/MIME signing successful")
            // Build outer headers
            var lines: [String] = []
            let senderDomain = extractDomain(from: message.from.email) ?? "mail.ailo.network"
            let messageId = "<\(UUID().uuidString.lowercased())@\(senderDomain)>"

            lines.append("From: \(formatRFC2822Address(message.from))")
            if !message.to.isEmpty {
                lines.append("To: \(message.to.map { formatRFC2822Address($0) }.joined(separator: ",\r\n\t"))")
            }
            if !message.cc.isEmpty {
                lines.append("Cc: \(message.cc.map { formatRFC2822Address($0) }.joined(separator: ",\r\n\t"))")
            }
            lines.append("Subject: \(encodeHeaderRFC2047(message.subject))")
            lines.append("Date: \(formatRFC2822Date(Date()))")
            lines.append("Message-ID: \(messageId)")
            lines.append("MIME-Version: 1.0")
            lines.append("X-Mailer: AILO Mail/1.0")

            // The signed data contains the Content-Type header for multipart/signed
            let signedContent = String(data: signedData, encoding: .utf8) ?? ""
            return lines.joined(separator: "\r\n") + "\r\n" + signedContent

        case .failure(let error):
            // Fallback: send unsigned if signing fails
            print("⚠️ [NIO-SMTP] S/MIME signing failed: \(error.localizedDescription) - sending unsigned")
            return buildUnsignedMIMEMessage(message)
        }
    }

    /// Builds the inner MIME content without outer headers (for S/MIME signing)
    /// IMPORTANT: Uses LF line endings because mail servers convert CRLF→LF during transport.
    /// The signature must be computed on what the recipient will actually receive.
    private func buildInnerMIMEContent(_ message: MailMessage) -> String {
        var lines: [String] = []
        let altBoundary = "----=_AltPart_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
        let mixedBoundary = "----=_MixedPart_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"

        let hasHTML = message.htmlBody != nil && !(message.htmlBody?.isEmpty ?? true)
        let hasText = message.textBody != nil && !(message.textBody?.isEmpty ?? true)
        let hasAttachments = !message.attachments.isEmpty

        if hasAttachments {
            lines.append("Content-Type: multipart/mixed;")
            lines.append("\tboundary=\"\(mixedBoundary)\"")
            lines.append("")
            lines.append("--\(mixedBoundary)")

            if hasHTML {
                let textVersion = hasText ? message.textBody! : htmlToPlainText(message.htmlBody ?? "")
                lines.append("Content-Type: multipart/alternative;")
                lines.append("\tboundary=\"\(altBoundary)\"")
                lines.append("")
                lines.append("--\(altBoundary)")
                lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncodeLF(textVersion))
                lines.append("")
                lines.append("--\(altBoundary)")
                lines.append("Content-Type: text/html; charset=\"UTF-8\"")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncodeLF(message.htmlBody ?? ""))
                lines.append("")
                lines.append("--\(altBoundary)--")
            } else {
                lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncodeLF(message.textBody ?? ""))
            }
            lines.append("")

            for attachment in message.attachments {
                lines.append("--\(mixedBoundary)")
                lines.append("Content-Type: \(attachment.mimeType);")
                lines.append("\tname=\"\(encodeHeaderRFC2047(attachment.filename))\"")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("Content-Disposition: attachment;")
                lines.append("\tfilename=\"\(encodeHeaderRFC2047(attachment.filename))\"")
                lines.append("")
                lines.append(base64EncodeWithLineBreaksLF(attachment.data))
                lines.append("")
            }
            lines.append("--\(mixedBoundary)--")
        } else if hasHTML {
            let textVersion = hasText ? message.textBody! : htmlToPlainText(message.htmlBody ?? "")
            lines.append("Content-Type: multipart/alternative;")
            lines.append("\tboundary=\"\(altBoundary)\"")
            lines.append("")
            lines.append("--\(altBoundary)")
            lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncodeLF(textVersion))
            lines.append("")
            lines.append("--\(altBoundary)")
            lines.append("Content-Type: text/html; charset=\"UTF-8\"")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncodeLF(message.htmlBody ?? ""))
            lines.append("")
            lines.append("--\(altBoundary)--")
        } else {
            lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncodeLF(message.textBody ?? ""))
        }

        // MIME canonical form requires CRLF line endings per RFC 5751
        // OpenSSL/verifiers canonicalize to CRLF before computing digest
        // Include trailing CRLF - this is part of the body per RFC 1847
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Quoted-printable encoding with LF line endings (for S/MIME signed content)
    private func quotedPrintableEncodeLF(_ text: String) -> String {
        var result = ""
        var lineLength = 0
        var pendingWhitespace = ""

        for scalar in text.unicodeScalars {
            let char = Character(scalar)
            var encoded: String

            if scalar == "\r" {
                continue
            } else if scalar == "\n" {
                for ws in pendingWhitespace.unicodeScalars {
                    if ws == " " {
                        result += "=20"
                    } else if ws == "\t" {
                        result += "=09"
                    }
                }
                pendingWhitespace = ""
                result += "\n"  // LF only
                lineLength = 0
                continue
            } else if scalar == " " || scalar == "\t" {
                pendingWhitespace += String(char)
                continue
            } else {
                if !pendingWhitespace.isEmpty {
                    if lineLength + pendingWhitespace.count > 75 {
                        result += "=\n"  // LF only
                        lineLength = 0
                    }
                    result += pendingWhitespace
                    lineLength += pendingWhitespace.count
                    pendingWhitespace = ""
                }

                if scalar.isASCII && scalar.value >= 33 && scalar.value <= 126 && scalar != "=" {
                    encoded = String(char)
                } else {
                    let bytes = String(char).utf8
                    encoded = bytes.map { String(format: "=%02X", $0) }.joined()
                }
            }

            if lineLength + encoded.count > 75 {
                result += "=\n"  // LF only
                lineLength = 0
            }

            result += encoded
            lineLength += encoded.count
        }

        for ws in pendingWhitespace.unicodeScalars {
            let encoded: String
            if ws == " " {
                encoded = "=20"
            } else if ws == "\t" {
                encoded = "=09"
            } else {
                encoded = String(Character(ws))
            }
            if lineLength + encoded.count > 75 {
                result += "=\n"
                lineLength = 0
            }
            result += encoded
            lineLength += encoded.count
        }

        return result
    }

    /// Base64 encoding with LF line breaks (for S/MIME signed content)
    private func base64EncodeWithLineBreaksLF(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        var result = ""
        var index = base64.startIndex
        while index < base64.endIndex {
            let endIndex = base64.index(index, offsetBy: 76, limitedBy: base64.endIndex) ?? base64.endIndex
            result += base64[index..<endIndex]
            if endIndex < base64.endIndex {
                result += "\n"  // LF only
            }
            index = endIndex
        }
        return result
    }

    private func buildUnsignedMIMEMessage(_ message: MailMessage) -> String {
        // Debug: Log attachment info
        print("📎 [NIO-SMTP] Building MIME message (unsigned)")
        print("📎 [NIO-SMTP] Attachments count: \(message.attachments.count)")
        for (idx, att) in message.attachments.enumerated() {
            print("📎 [NIO-SMTP] Attachment \(idx): \(att.filename) (\(att.mimeType), \(att.data.count) bytes)")
        }

        var lines: [String] = []

        // Extract sender domain for Message-ID
        let senderDomain = extractDomain(from: message.from.email) ?? "mail.ailo.network"

        // Generate unique identifiers
        let messageId = "<\(UUID().uuidString.lowercased())@\(senderDomain)>"
        let mixedBoundary = "----=_MixedPart_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
        let altBoundary = "----=_AltPart_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"

        // === Required Headers (RFC 5322) ===
        lines.append("From: \(formatRFC2822Address(message.from))")

        if !message.to.isEmpty {
            lines.append("To: \(message.to.map { formatRFC2822Address($0) }.joined(separator: ",\r\n\t"))")
        }

        if !message.cc.isEmpty {
            lines.append("Cc: \(message.cc.map { formatRFC2822Address($0) }.joined(separator: ",\r\n\t"))")
        }

        // Subject with proper encoding
        lines.append("Subject: \(encodeHeaderRFC2047(message.subject))")

        // Date in RFC 2822 format
        lines.append("Date: \(formatRFC2822Date(Date()))")

        // Message-ID with sender's domain (important for DKIM alignment)
        lines.append("Message-ID: \(messageId)")

        // === MIME Headers ===
        lines.append("MIME-Version: 1.0")

        // === Delivery & Anti-Spam Headers ===
        lines.append("X-Mailer: AILO Mail/1.0")
        lines.append("X-Priority: 3")  // Normal priority
        lines.append("X-MSMail-Priority: Normal")
        lines.append("Importance: Normal")

        // === Content Type ===
        let hasHTML = message.htmlBody != nil && !(message.htmlBody?.isEmpty ?? true)
        let hasText = message.textBody != nil && !(message.textBody?.isEmpty ?? true)
        let hasAttachments = !message.attachments.isEmpty

        if hasAttachments {
            // Multipart/mixed for attachments
            lines.append("Content-Type: multipart/mixed;")
            lines.append("\tboundary=\"\(mixedBoundary)\"")
            lines.append("")

            // First part: the message body
            lines.append("--\(mixedBoundary)")

            if hasHTML {
                // Body is multipart/alternative (text + HTML)
                let textVersion = hasText ? message.textBody! : htmlToPlainText(message.htmlBody ?? "")

                lines.append("Content-Type: multipart/alternative;")
                lines.append("\tboundary=\"\(altBoundary)\"")
                lines.append("")

                // Plain text part
                lines.append("--\(altBoundary)")
                lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncode(textVersion))
                lines.append("")

                // HTML part
                lines.append("--\(altBoundary)")
                lines.append("Content-Type: text/html; charset=\"UTF-8\"")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncode(sanitizeHTML(message.htmlBody ?? "")))
                lines.append("")

                lines.append("--\(altBoundary)--")
            } else {
                // Plain text only
                lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncode(message.textBody ?? ""))
            }
            lines.append("")

            // Attachment parts
            for attachment in message.attachments {
                lines.append("--\(mixedBoundary)")
                lines.append("Content-Type: \(attachment.mimeType);")
                lines.append("\tname=\"\(encodeHeaderRFC2047(attachment.filename))\"")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("Content-Disposition: attachment;")
                lines.append("\tfilename=\"\(encodeHeaderRFC2047(attachment.filename))\"")
                lines.append("")
                // Base64 encode with line wrapping (76 chars per line)
                lines.append(base64EncodeWithLineBreaks(attachment.data))
                lines.append("")
            }

            lines.append("--\(mixedBoundary)--")
        } else if hasHTML {
            // No attachments, HTML body - use multipart/alternative
            let textVersion = hasText ? message.textBody! : htmlToPlainText(message.htmlBody ?? "")

            lines.append("Content-Type: multipart/alternative;")
            lines.append("\tboundary=\"\(altBoundary)\"")
            lines.append("")

            // Plain text part
            lines.append("--\(altBoundary)")
            lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncode(textVersion))
            lines.append("")

            // HTML part
            lines.append("--\(altBoundary)")
            lines.append("Content-Type: text/html; charset=\"UTF-8\"")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncode(sanitizeHTML(message.htmlBody ?? "")))
            lines.append("")

            lines.append("--\(altBoundary)--")
        } else {
            // Plain text only, no attachments
            lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncode(message.textBody ?? ""))
        }

        return lines.joined(separator: "\r\n")
    }

    /// Base64 encode data with line breaks every 76 characters (RFC 2045)
    private func base64EncodeWithLineBreaks(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        var result = ""
        var index = base64.startIndex
        while index < base64.endIndex {
            let endIndex = base64.index(index, offsetBy: 76, limitedBy: base64.endIndex) ?? base64.endIndex
            result += base64[index..<endIndex]
            if endIndex < base64.endIndex {
                result += "\r\n"
            }
            index = endIndex
        }
        return result
    }

    /// Extracts domain from email address
    private func extractDomain(from email: String) -> String? {
        guard let atIndex = email.lastIndex(of: "@") else { return nil }
        let domain = String(email[email.index(after: atIndex)...])
        return domain.isEmpty ? nil : domain
    }

    /// Formats address according to RFC 2822
    private func formatRFC2822Address(_ addr: MailAddress) -> String {
        if let name = addr.name, !name.isEmpty {
            // Encode name if it contains non-ASCII or special characters
            let encodedName = encodeHeaderRFC2047(name)
            if encodedName.hasPrefix("=?") {
                // Already encoded
                return "\(encodedName) <\(addr.email)>"
            } else {
                // Quote the name if it contains special chars
                let needsQuoting = name.contains(where: { "\"(),.:;<>@[\\]".contains($0) })
                if needsQuoting {
                    let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                                       .replacingOccurrences(of: "\"", with: "\\\"")
                    return "\"\(escaped)\" <\(addr.email)>"
                }
                return "\(name) <\(addr.email)>"
            }
        }
        // No name - return plain email without angle brackets (RFC 5321 compatible)
        // Using <email> without name triggers spam filters
        return addr.email
    }

    /// RFC 2047 encoding for header fields with non-ASCII characters
    private func encodeHeaderRFC2047(_ text: String) -> String {
        // Check if encoding is needed
        let needsEncoding = text.unicodeScalars.contains { !$0.isASCII } ||
                           text.contains(where: { "=?".contains($0) })

        guard needsEncoding else { return text }

        // Use Base64 for reliability (Q-encoding has more edge cases)
        let base64 = Data(text.utf8).base64EncodedString()

        // Split into 75-character chunks (RFC 2047 limit)
        var result = ""
        var remaining = base64
        let maxChunkSize = 45 // Leaves room for =?UTF-8?B?...?= wrapper

        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(maxChunkSize))
            remaining = String(remaining.dropFirst(maxChunkSize))

            if !result.isEmpty {
                result += "\r\n " // Continuation line
            }
            result += "=?UTF-8?B?\(chunk)?="
        }

        return result
    }

    /// Sanitizes HTML to remove potentially problematic content that triggers spam filters
    private func sanitizeHTML(_ html: String) -> String {
        var sanitized = html

        // Remove dangerous tags that trigger spam filters
        let dangerousTags = ["script", "style", "form", "iframe", "object", "embed", "applet", "meta", "link", "base"]
        for tag in dangerousTags {
            // Remove opening and closing tags with content
            while let range = sanitized.range(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", options: [.regularExpression, .caseInsensitive]) {
                sanitized.removeSubrange(range)
            }
            // Remove self-closing tags
            while let range = sanitized.range(of: "<\(tag)[^>]*/?>", options: [.regularExpression, .caseInsensitive]) {
                sanitized.removeSubrange(range)
            }
        }

        // Remove event handlers (onclick, onload, onerror, etc.)
        while let eventRange = sanitized.range(of: "\\s+on\\w+\\s*=\\s*[\"'][^\"']*[\"']", options: [.regularExpression, .caseInsensitive]) {
            sanitized.removeSubrange(eventRange)
        }
        // Also handle unquoted event handlers
        while let eventRange = sanitized.range(of: "\\s+on\\w+\\s*=\\s*[^\\s>]+", options: [.regularExpression, .caseInsensitive]) {
            sanitized.removeSubrange(eventRange)
        }

        // Remove javascript: and data: URLs (common in phishing)
        sanitized = sanitized.replacingOccurrences(of: "javascript:", with: "", options: .caseInsensitive)
        sanitized = sanitized.replacingOccurrences(of: "data:", with: "", options: .caseInsensitive)
        sanitized = sanitized.replacingOccurrences(of: "vbscript:", with: "", options: .caseInsensitive)

        // Remove external stylesheet references
        sanitized = sanitized.replacingOccurrences(of: "@import[^;]+;", with: "", options: .regularExpression)

        // Remove -webkit- prefixed styles from inline style attributes (WKWebView adds these)
        sanitized = sanitized.replacingOccurrences(
            of: "-webkit-[^;:]+:[^;\"]+;?",
            with: "",
            options: .regularExpression
        )

        // Remove empty style attributes left after cleaning
        sanitized = sanitized.replacingOccurrences(
            of: "\\s*style\\s*=\\s*\"\\s*\"",
            with: "",
            options: .regularExpression
        )

        // Remove empty spans (often left by WKWebView editor)
        while let range = sanitized.range(of: "<span[^>]*>\\s*</span>", options: .regularExpression) {
            sanitized.removeSubrange(range)
        }

        // Simplify spans that have no meaningful attributes
        sanitized = sanitized.replacingOccurrences(
            of: "<span\\s*>([^<]*)</span>",
            with: "$1",
            options: .regularExpression
        )

        // Ensure proper HTML structure (many spam filters require this)
        return wrapInHTMLStructure(sanitized)
    }

    /// Wraps HTML content in a proper document structure if missing
    private func wrapInHTMLStructure(_ html: String) -> String {
        let lowercased = html.lowercased()

        // Check if already has proper structure
        if lowercased.contains("<!doctype") || lowercased.contains("<html") {
            // Already has structure, just ensure no duplicate doctypes
            return html
        }

        // Wrap in minimal valid HTML5 structure for email
        return """
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
</head>
<body>
\(html)
</body>
</html>
"""
    }

    /// Converts HTML to plain text for multipart/alternative
    private func htmlToPlainText(_ html: String) -> String {
        var text = html

        // Replace common block elements with newlines
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</tr>", with: "\n", options: .caseInsensitive)

        // Remove all HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")

        // Clean up whitespace
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatRFC2822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private func quotedPrintableEncode(_ text: String) -> String {
        var result = ""
        var lineLength = 0
        var pendingWhitespace = ""  // Buffer for trailing whitespace

        for scalar in text.unicodeScalars {
            let char = Character(scalar)
            var encoded: String

            if scalar == "\r" {
                // Skip CR, we'll handle CRLF properly
                continue
            } else if scalar == "\n" {
                // Line break - encode any pending whitespace before the line break (RFC 2045)
                for ws in pendingWhitespace.unicodeScalars {
                    if ws == " " {
                        result += "=20"
                    } else if ws == "\t" {
                        result += "=09"
                    }
                }
                pendingWhitespace = ""
                result += "\r\n"
                lineLength = 0
                continue
            } else if scalar == " " || scalar == "\t" {
                // Buffer whitespace - we'll encode it if it's at end of line
                pendingWhitespace += String(char)
                continue
            } else {
                // Flush any pending whitespace (not at end of line, so keep as-is)
                if !pendingWhitespace.isEmpty {
                    // Check if we need soft line break
                    if lineLength + pendingWhitespace.count > 75 {
                        result += "=\r\n"
                        lineLength = 0
                    }
                    result += pendingWhitespace
                    lineLength += pendingWhitespace.count
                    pendingWhitespace = ""
                }

                if scalar.isASCII && scalar.value >= 33 && scalar.value <= 126 && scalar != "=" {
                    // Printable ASCII except =
                    encoded = String(char)
                } else {
                    // Encode as =XX
                    let bytes = String(char).utf8
                    encoded = bytes.map { String(format: "=%02X", $0) }.joined()
                }
            }

            // Soft line break if line would exceed 76 chars
            if lineLength + encoded.count > 75 {
                result += "=\r\n"
                lineLength = 0
            }

            result += encoded
            lineLength += encoded.count
        }

        // Handle any trailing whitespace at end of content (encode it)
        for ws in pendingWhitespace.unicodeScalars {
            let encoded: String
            if ws == " " {
                encoded = "=20"
            } else if ws == "\t" {
                encoded = "=09"
            } else {
                encoded = String(Character(ws))
            }
            if lineLength + encoded.count > 75 {
                result += "=\r\n"
                lineLength = 0
            }
            result += encoded
            lineLength += encoded.count
        }

        return result
    }

    private func extractMessageId(from response: String) -> String? {
        if let range = response.range(of: "<[^>]+>", options: .regularExpression) {
            return String(response[range])
        }
        return nil
    }

    // Keep legacy method for compatibility
    private func formatAddress(_ addr: MailAddress) -> String {
        return formatRFC2822Address(addr)
    }

    private func encodeHeader(_ text: String) -> String {
        return encodeHeaderRFC2047(text)
    }
}

// MARK: - SMTP Response Handler

/// Handles SMTP line-based protocol with proper multiline response support and response buffering
final class SMTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var buffer = ByteBufferAllocator().buffer(capacity: 1024)
    private let lock = NIOLock()
    private var responseQueue: [SMTPResponse] = []  // Buffer for responses received before readResponse() called
    private var pendingContinuation: CheckedContinuation<SMTPResponse, Error>?
    private var pendingLines: [String] = []

    struct SMTPResponse {
        let code: Int
        let message: String
        let fullResponse: String
        let isMultiline: Bool

        init(lines: [String]) {
            self.fullResponse = lines.joined(separator: "\n")
            self.isMultiline = lines.count > 1

            if let lastLine = lines.last, lastLine.count >= 3,
               let code = Int(String(lastLine.prefix(3))) {
                self.code = code
                self.message = lastLine.count > 4 ? String(lastLine.dropFirst(4)) : ""
            } else {
                self.code = 0
                self.message = lines.joined(separator: "\n")
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        buffer.writeBuffer(&buf)

        // Process all complete responses from buffer
        while let response = parseCompleteResponse() {
            lock.withLock {
                if let continuation = pendingContinuation {
                    // Someone is waiting for a response - deliver immediately
                    pendingContinuation = nil
                    continuation.resume(returning: response)
                } else {
                    // No one waiting yet - buffer the response
                    responseQueue.append(response)
                    print("🔧 [NIO-SMTP] Buffered response: \(response.code)")
                }
            }
        }
    }

    private func parseCompleteResponse() -> SMTPResponse? {
        // Read lines until we find a final line (code followed by space, not hyphen)
        while let line = readLineCRLF() {
            pendingLines.append(line)

            // Check if this is the final line of a response
            if line.count >= 4 {
                let index = line.index(line.startIndex, offsetBy: 3)
                let separator = line[index]

                if separator == " " {
                    // Final line found - create response and clear pending lines
                    let response = SMTPResponse(lines: pendingLines)
                    pendingLines.removeAll()
                    return response
                }
                // If separator is "-", it's a multiline continuation, keep reading
            } else if line.count >= 3 {
                // Short response line (just code)
                let response = SMTPResponse(lines: pendingLines)
                pendingLines.removeAll()
                return response
            }
        }

        return nil // Incomplete response, wait for more data
    }

    private func readLineCRLF() -> String? {
        guard let crlfRange = buffer.readableBytesView.firstRange(of: [0x0D, 0x0A]) else {
            return nil
        }

        let lineLength = buffer.readableBytesView.distance(
            from: buffer.readableBytesView.startIndex,
            to: crlfRange.lowerBound
        )

        guard var lineSlice = buffer.readSlice(length: lineLength) else {
            return nil
        }

        // Consume CRLF
        buffer.moveReaderIndex(forwardBy: 2)

        return lineSlice.readString(length: lineSlice.readableBytes)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lock.withLock {
            pendingContinuation?.resume(throwing: error)
            pendingContinuation = nil
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.withLock {
            pendingContinuation?.resume(throwing: SMTPError.closed)
            pendingContinuation = nil
        }
    }

    // MARK: - Public API

    func readResponse() async throws -> SMTPResponse {
        // First check if we already have a buffered response
        let buffered: SMTPResponse? = lock.withLock {
            if !responseQueue.isEmpty {
                return responseQueue.removeFirst()
            }
            return nil
        }

        if let response = buffered {
            print("🔧 [NIO-SMTP] Using buffered response: \(response.code)")
            return response
        }

        // No buffered response - wait for one with timeout
        return try await withThrowingTaskGroup(of: SMTPResponse.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.withLock {
                        // Double-check buffer under lock
                        if !self.responseQueue.isEmpty {
                            let response = self.responseQueue.removeFirst()
                            continuation.resume(returning: response)
                            return
                        }

                        // No buffered response - store continuation for channelRead to fulfill
                        self.pendingContinuation = continuation
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30s timeout
                throw SMTPError.receiveFailed("Response timeout")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func sendCommand(_ command: String, on channel: Channel) async throws {
        var buf = channel.allocator.buffer(capacity: command.utf8.count + 2)
        buf.writeString(command)
        if !command.hasSuffix("\r\n") {
            buf.writeString("\r\n")
        }
        try await channel.writeAndFlush(buf).get()
    }

    func sendRawData(_ data: String, on channel: Channel) async throws {
        // Escape any lone dots at beginning of lines (RFC 5321)
        let escaped = data.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        var buf = channel.allocator.buffer(capacity: escaped.utf8.count)
        buf.writeString(escaped)
        try await channel.writeAndFlush(buf).get()
    }
}

#else

// Fallback if SwiftNIO is not available in this target. Conform to protocol and delegate to SMTPClient.
public final class NIOSMTPClient: SMTPClientProtocol {
    public init() {
        print("⚠️ [NIO-SMTP] Using FALLBACK implementation (NIO not available)")
    }

    public func testConnection(_ config: SMTPConfig) async -> Result<Void, SMTPError> {
        print("⚠️ [NIO-SMTP] testConnection via FALLBACK (delegating to SMTPClient)")
        let smtp = SMTPClient()
        return await smtp.testConnection(config)
    }

    public func send(_ message: MailMessage, using config: SMTPConfig) async -> DeliveryResult {
        print("⚠️ [NIO-SMTP] send via FALLBACK (delegating to SMTPClient)")
        print("⚠️ [NIO-SMTP] STARTTLS will NOT work in fallback mode!")
        print("⚠️ [NIO-SMTP] Config: \(config.host):\(config.port) encryption:\(config.encryption)")
        let smtp = SMTPClient()
        return await smtp.send(message, using: config)
    }
}

#endif
