// Supports configurable verbosity and optional on-screen diagnostics.

// AILO_APP/Configuration/Services/Mail/MailLogger.swift
// Centralized logger for mail operations with standardized tags (CONNECT, LOGIN, LIST, FETCH, PARSE, STORE, SEND).
// Supports configurable verbosity and optional in-memory ring buffer for diagnostics.
// Thread-safety: synchronized via a private serial queue. Lightweight and dependency-free.

import Foundation

public final class MailLogger {

    // MARK: Types

    public enum Level: Int, Comparable, Sendable {
        case off = 0
        case error = 1
        case warn  = 2
        case info  = 3
        case debug = 4
        case trace = 5

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Tag: String, Sendable, CaseIterable {
        case CONNECT, LOGIN, LIST, SELECT, SEARCH, FETCH, PARSE, STORE, SEND
    }

    public struct Entry: Sendable {
        public let ts: Date
        public let accountId: UUID?
        public let tag: Tag
        public let level: Level
        public let message: String
        public let context: [String: String]?

        public init(ts: Date, accountId: UUID?, tag: Tag, level: Level, message: String, context: [String: String]?) {
            self.ts = ts
            self.accountId = accountId
            self.tag = tag
            self.level = level
            self.message = message
            self.context = context
        }

        public var formatted: String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let time = df.string(from: ts)
            let acc = accountId?.uuidString.prefix(8) ?? "-"
            let ctx = (context?.isEmpty == false) ? " \(context!)" : ""
            return "[\(time)] [\(level)] [\(tag.rawValue)] [acc:\(acc)] \(message)\(ctx)"
        }
    }

    // MARK: Singleton

    public static let shared = MailLogger()

    private init() {}

    // MARK: Config

    private let q = DispatchQueue(label: "mail.logger.queue")
    private var globalLevel: Level = .info
    private var perAccountLevel: [UUID: Level] = [:]

    // MARK: - Public log level API (UI-configurable)

    /// User-facing log level abstraction (coarser than internal Level).
    public enum LogLevel: Int, Sendable, CaseIterable {
        case debug
        case info
        case warn
        case error
    }

    /// Get or set the global log level in a UI-friendly way.
    /// Setting this maps to the internal Level (with `trace` unavailable via UI).
    public var logLevel: LogLevel {
        get {
            return q.sync {
                switch globalLevel {
                case .debug, .trace: return .debug
                case .info: return .info
                case .warn: return .warn
                case .error: return .error
                case .off: return .error
                }
            }
        }
        set {
            q.sync {
                switch newValue {
                case .debug: self.globalLevel = .debug
                case .info: self.globalLevel = .info
                case .warn: self.globalLevel = .warn
                case .error: self.globalLevel = .error
                }
            }
        }
    }

    /// Convenience setter matching the existing API but accepting `LogLevel`.
    public func setLogLevel(_ level: LogLevel) {
        self.logLevel = level
    }

    /// Convenience getter for current `LogLevel`.
    public func currentLogLevel() -> LogLevel { self.logLevel }

    // ring buffer
    private var buffer: [Entry] = []
    private var bufferSize: Int = 0
    private var bufferIndex: Int = 0
    private var bufferFilled: Bool = false

    // MARK: Public control API

    public func setLevel(_ level: Level) {
        q.sync { self.globalLevel = level }
    }

    public func setLevel(forAccount id: UUID, level: Level) {
        q.sync { self.perAccountLevel[id] = level }
    }

    public func level(forAccount id: UUID?) -> Level {
        q.sync {
            if let id, let lvl = perAccountLevel[id] { return lvl }
            return globalLevel
        }
    }

    public func enableInMemoryRingBuffer(size: Int) {
        q.sync {
            self.bufferSize = max(0, size)
            self.buffer = Array()
            self.buffer.reserveCapacity(self.bufferSize)
            self.bufferIndex = 0
            self.bufferFilled = false
        }
    }

    public func clearBuffer() {
        q.sync {
            self.buffer.removeAll(keepingCapacity: true)
            self.bufferIndex = 0
            self.bufferFilled = false
        }
    }

    public func snapshot() -> [Entry] {
        q.sync {
            guard bufferSize > 0 else { return [] }
            if !bufferFilled { return Array(buffer) }
            // return in chronological order
            let head = bufferIndex
            let tail = buffer.count
            return Array(buffer[head..<tail] + buffer[0..<head])
        }
    }

    // MARK: Logging

    @discardableResult
    public func log(_ tag: Tag, level: Level, accountId: UUID? = nil, _ message: String, context: [String: String]? = nil) -> Entry? {
        var entry: Entry?
        q.sync {
            // respect per-account level or global level
            let allowedLevel = (accountId != nil) ? (perAccountLevel[accountId!] ?? globalLevel) : globalLevel
            guard level.rawValue <= Level.trace.rawValue, level >= allowedLevel, level != .off else { return }

            let e = Entry(ts: Date(), accountId: accountId, tag: tag, level: level, message: message, context: context)
            entry = e

            // ring buffer write (if enabled)
            if bufferSize > 0 {
                if buffer.count < bufferSize {
                    buffer.append(e)
                    if buffer.count == bufferSize { bufferFilled = true; bufferIndex = 0 }
                } else {
                    buffer[bufferIndex] = e
                    bufferIndex = (bufferIndex + 1) % bufferSize
                }
            }

            // also print to console in DEBUG
            #if DEBUG
            print(e.formatted)
            #endif
        }
        return entry
    }

    // Convenience wrappers

    public func error(_ tag: Tag, accountId: UUID? = nil, _ message: String, context: [String: String]? = nil) {
        _ = log(tag, level: .error, accountId: accountId, message, context: context)
    }

    public func warn(_ tag: Tag, accountId: UUID? = nil, _ message: String, context: [String: String]? = nil) {
        _ = log(tag, level: .warn, accountId: accountId, message, context: context)
    }

    public func info(_ tag: Tag, accountId: UUID? = nil, _ message: String, context: [String: String]? = nil) {
        _ = log(tag, level: .info, accountId: accountId, message, context: context)
    }

    public func debug(_ tag: Tag, accountId: UUID? = nil, _ message: String, context: [String: String]? = nil) {
        _ = log(tag, level: .debug, accountId: accountId, message, context: context)
    }

    public func trace(_ tag: Tag, accountId: UUID? = nil, _ message: String, context: [String: String]? = nil) {
        _ = log(tag, level: .trace, accountId: accountId, message, context: context)
    }
}

