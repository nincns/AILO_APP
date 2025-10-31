// AILO_APP/Configuration/Services/Mail/NIOSMTPClient.swift
// SwiftNIO-based SMTP client (skeleton). Non-blocking I/O with optional STARTTLS upgrade.
// For MVP this implementation focuses on connectivity testing and defers full send to SMTPClient.

import Foundation

#if canImport(NIOCore) && canImport(NIOPosix)
import NIOCore
import NIOPosix
#if canImport(NIOSSL)
import NIOSSL
#endif

/// Minimal SwiftNIO implementation that conforms to SMTPClientProtocol.
/// - testConnection: Opens a TCP connection, reads greeting, issues QUIT.
/// - send: Falls back to the synchronous SMTPClient for robust RFC handling (DATA, AUTH, multipart),
///   while we build out a non-blocking pipeline in a later sprint.
public final class NIOSMTPClient: SMTPClientProtocol {
    public init() {}

    public func testConnection(_ config: SMTPConfig) async -> Result<Void, SMTPError> {
        do {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try? group.syncShutdownGracefully() }

            let bootstrap = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(SMTPLineHandler())
                }

            let channel = try await bootstrap.connect(host: config.host, port: Int(config.port)).get()
            // Wait for greeting (single line with code 220)
            let handler = try channel.pipeline.handler(type: SMTPLineHandler.self).wait()
            let greeting = try await handler.nextLine(on: channel.eventLoop)
            guard greeting.hasPrefix("220") else {
                _ = try? channel.close(mode: .all).wait()
                return .failure(.greetingFailed("Unexpected greeting: \(greeting)"))
            }
            // Issue QUIT and close
            try await handler.sendLine("QUIT", on: channel)
            _ = try? channel.close(mode: .all).wait()
            return .success(())
        } catch {
            return .failure(.receiveFailed(error.localizedDescription))
        }
    }

    public func send(_ message: MailMessage, using config: SMTPConfig) async -> DeliveryResult {
        // For now, delegate to the synchronous SMTPClient which is fully featured.
        // This keeps behavior correct while we incrementally build the non-blocking pipeline.
        let fallback = SMTPClient()
        return await fallback.send(message, using: config)
    }
}

// MARK: - Pipeline handler

final class SMTPLineHandler: ChannelInboundHandler, ChannelOutboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var buffer = ByteBufferAllocator().buffer(capacity: 0)
    private let lock = NIOLock()
    private var waiters: [EventLoopPromise<String>] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        if var bytes = buf.readBytes(length: buf.readableBytes) {
            buffer.writeBytes(&bytes, count: bytes.count)
        }
        // Attempt to extract CRLF-terminated lines
        while let line = readLineCRLF() {
            // Fulfill the first waiter if exists, otherwise drop
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

    // Public helpers
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

    // Internal CRLF line reader
    private func readLineCRLF() -> String? {
        // Search for CRLF in buffer
        if let view = buffer.readableBytesView.firstRange(of: Data("\r\n".utf8)) {
            let endIndex = view.lowerBound
            let lineData = buffer.readSlice(length: endIndex)
            _ = buffer.readSlice(length: 2) // consume CRLF
            if var data = lineData, let s = data.readString(length: data.readableBytes) {
                return s
            }
        }
        return nil
    }
}

#else

// Fallback if SwiftNIO is not available in this target. Conform to protocol and delegate to SMTPClient.
public final class NIOSMTPClient: SMTPClientProtocol {
    public init() {}
    public func testConnection(_ config: SMTPConfig) async -> Result<Void, SMTPError> {
        // Indicate that NIO path is unavailable by deferring to the synchronous client
        let smtp = SMTPClient()
        return await smtp.testConnection(config)
    }
    public func send(_ message: MailMessage, using config: SMTPConfig) async -> DeliveryResult {
        let smtp = SMTPClient()
        return await smtp.send(message, using: config)
    }
}

#endif
