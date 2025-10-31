// AILO_APP/Configuration/Services/Mail/FolderDiscoveryService.swift
// Resolves special-use folders (INBOX, SENT, DRAFTS, TRASH, SPAM) for each account.
// Uses IMAP LIST + SPECIAL-USE when available; falls back to name heuristics.
// Cache API allows quick reuse across the app without re-running network discovery each time.


import Foundation

extension Notification.Name {
    static let folderDiscoveryDidUpdate = Notification.Name("folderDiscoveryDidUpdate")
}

actor FolderDiscoveryCoordinator {
    static let shared = FolderDiscoveryCoordinator()
    private var tasks: [UUID: Task<Result<FolderMap, Error>, Never>] = [:]

    func run(accountId: UUID, operation: @escaping () async -> Result<FolderMap, Error>) async -> Result<FolderMap, Error> {
        if let existing = tasks[accountId] {
            return await existing.value
        }
        let task = Task { await operation() }
        tasks[accountId] = task
        let result = await task.value
        tasks[accountId] = nil
        return result
    }

    func cancelAll() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
    }
    
    func cancel(accountId: UUID) {
        if let task = tasks[accountId] {
            task.cancel()
            tasks[accountId] = nil
        }
    }
}

actor DiscoveryDebounce {
    static let shared = DiscoveryDebounce()
    private var lastStart: [UUID: Date] = [:]
    // Debounce window to suppress immediate re-runs after a recent discovery
    private let window: TimeInterval = 60.0

    func shouldStart(accountId: UUID) -> Bool {
        let now = Date()
        if let last = lastStart[accountId], now.timeIntervalSince(last) < window {
            return false
        }
        lastStart[accountId] = now
        return true
    }
}

public struct FolderMap: Sendable, Equatable {
    public let inbox: String
    public let sent: String
    public let drafts: String
    public let trash: String
    public let spam: String

    public init(inbox: String = "INBOX", sent: String = "Sent", drafts: String = "Drafts", trash: String = "Trash", spam: String = "Spam") {
        self.inbox = inbox
        self.sent = sent
        self.drafts = drafts
        self.trash = trash
        self.spam = spam
    }
}

public final class FolderDiscoveryService {
    // Known provider fast-path to avoid network discovery on common hosts
    private let knownProviders: [String: FolderMap] = [
        "imap.gmail.com": FolderMap(
            inbox: "INBOX",
            sent: "[Gmail]/Sent Mail",
            drafts: "[Gmail]/Drafts",
            trash: "[Gmail]/Trash",
            spam: "[Gmail]/Spam"
        ),
        "outlook.office365.com": FolderMap(
            inbox: "INBOX",
            sent: "Sent Items",
            drafts: "Drafts",
            trash: "Deleted Items",
            spam: "Junk Email"
        )
    ]

    public static let shared = FolderDiscoveryService()

    private let q = DispatchQueue(label: "mail.folder.discovery.cache")
    private var cache: [UUID: FolderMap] = [:]

    // Track active IMAP connections per account so we can force-close on cancelAll
    private let connRegistryQ = DispatchQueue(label: "mail.folder.discovery.connreg")
    private var activeConns: [UUID: IMAPConnection] = [:]
    // During editor connection tests, block discovery starts
    private var isTestMode: Bool = false

    // Notification observers
    private var observers: [NSObjectProtocol] = []

    private init() {
        let o1 = NotificationCenter.default.addObserver(forName: .folderDiscoveryCancelAll, object: nil, queue: .main) { [weak self] _ in
            self?.handleCancelAll()
        }
        let o2 = NotificationCenter.default.addObserver(forName: .folderDiscoveryCancelAccount, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            self?.handleCancel(accountId: id)
        }
        observers.append(contentsOf: [o1, o2])
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Cache API

    public func getCached(accountId: UUID) -> FolderMap? {
        q.sync { cache[accountId] }
    }

    public func invalidate(accountId: UUID) {
        q.sync { cache.removeValue(forKey: accountId) }
    }


    // MARK: Test-mode API
    /// Prevents new discovery starts and closes any active discovery connections.
    public func enterTestMode() {
        // Flip under registry queue to serialize with potential starters
        connRegistryQ.sync { isTestMode = true }
        MailLogger.shared.debug(.CONNECT, accountId: nil, "[Discovery] Entering TEST MODE – blocking new discoveries and closing active ones")
        handleCancelAll()
    }

    /// Allows discovery to start again after editor connection tests are done.
    public func exitTestMode() {
        connRegistryQ.sync { isTestMode = false }
        MailLogger.shared.debug(.CONNECT, accountId: nil, "[Discovery] Exiting TEST MODE – allowing discoveries again")
    }

    // MARK: Discovery API

    /// High-level discovery that logs in and inspects folders to map special-use targets.
    /// The minimal inputs are passed explicitly to keep this service decoupled from app-specific models.
    public struct IMAPLogin: Sendable {
        public let host: String
        public let port: Int
        public let useTLS: Bool
        public let sniHost: String?
        public let username: String
        public let password: String
        // Optional timeouts to allow callers (e.g., editor UI) to control behavior
        public let connectionTimeoutSec: Int?
        public let commandTimeoutSec: Int?
        public let idleTimeoutSec: Int?

        public init(
            host: String,
            port: Int,
            useTLS: Bool = true,
            sniHost: String? = nil,
            username: String,
            password: String,
            connectionTimeoutSec: Int? = nil,
            commandTimeoutSec: Int? = nil,
            idleTimeoutSec: Int? = nil
        ) {
            self.host = host
            self.port = port
            self.useTLS = useTLS
            self.sniHost = sniHost
            self.username = username
            self.password = password
            self.connectionTimeoutSec = connectionTimeoutSec
            self.commandTimeoutSec = commandTimeoutSec
            self.idleTimeoutSec = idleTimeoutSec
        }
    }

    public func discover(accountId: UUID, login: IMAPLogin) async -> Result<FolderMap, Error> {
        // Block discovery while editor test is running to prevent greeting hijack
        if connRegistryQ.sync(execute: { isTestMode }) {
            MailLogger.shared.debug(.CONNECT, accountId: accountId, "[Discovery] Start blocked – TEST MODE active")
            return .failure(DiscoveryError.blockedByTestMode)
        }
        return await FolderDiscoveryCoordinator.shared.run(accountId: accountId) {
            // If a discovery just ran very recently, return the cached result (if any) and skip re-run
            let allow = await DiscoveryDebounce.shared.shouldStart(accountId: accountId)
            if !allow {
                if let cached = self.getCached(accountId: accountId) {
                    return .success(cached)
                }
                // No cache available; proceed to a single discovery run anyway
            }
            return await self._discover(accountId: accountId, login: login)
        }
    }

    private func _discover(accountId: UUID, login: IMAPLogin) async -> Result<FolderMap, Error> {
        if connRegistryQ.sync(execute: { isTestMode }) {
            MailLogger.shared.debug(.CONNECT, accountId: accountId, "[Discovery] _discover blocked – TEST MODE active")
            return .failure(DiscoveryError.blockedByTestMode)
        }
        // Create a fresh connection + commands each time to avoid cross-session state.
        let conn = IMAPConnection(label: "discover.\(accountId.uuidString.prefix(6))")
        // Register connection so cancelAll() can force-close it
        connRegistryQ.sync { activeConns[accountId] = conn }
        _debugDumpActiveConnections(where: "after-register")
        defer {
            // Ensure connection gets removed and closed on any exit path
            _debugDumpActiveConnections(where: "before-deregister")
            connRegistryQ.sync { activeConns.removeValue(forKey: accountId) }
            conn.close()
        }
        let commands = IMAPCommands()
        do {
            // Provider fast-path: return immediately if we know the standard folder names
            if let pre = knownProviders[login.host.lowercased()] {
                q.sync { cache[accountId] = pre }
                NotificationCenter.default.post(name: .folderDiscoveryDidUpdate, object: accountId, userInfo: ["map": pre])
                return .success(pre)
            }
            // Discovery-specific short timeouts. Keep them conservative but snappy.
            let connTimeout = min(login.connectionTimeoutSec ?? 15, 8)
            let cmdTimeout  = min(login.commandTimeoutSec ?? 10, 5)
            let idleTimeout = min(login.idleTimeoutSec ?? 10, 2)
            let cfg = IMAPConnectionConfig(
                host: login.host,
                port: login.port,
                tls: login.useTLS,
                sniHost: login.sniHost,
                connectionTimeoutSec: connTimeout,
                commandTimeoutSec: cmdTimeout,
                idleTimeoutSec: idleTimeout
            )
            try await withAbsoluteTimeout(Double(connTimeout)) { try await conn.open(cfg) }
            let _ = try await conn.receiveGreeting(timeout: Double(max(5, cmdTimeout)))
            try await withAbsoluteTimeout(Double(cmdTimeout)) { try await commands.login(conn, user: login.username, pass: login.password) }
            // Absolute overall cap for discovery
            let overallCap: TimeInterval = max(Double(cmdTimeout) * 2.0, 6.0)
            let started = Date()
            // Very short per-command idle for discovery
            let quickIdle: TimeInterval = Double(idleTimeout)
            // 1) SPECIAL-USE fast path (single capped request)
            var lines = try await withAbsoluteTimeout(Double(cmdTimeout)) {
                try await commands.listSpecialUse(conn, idleTimeout: quickIdle)
            }
            func isListLike(_ ls: [String]) -> Bool { containsListLike(ls) && !ls.isEmpty }
            // 2) Fallback to capped LIST "*" only if needed and within overall cap
            if !isListLike(lines) && Date().timeIntervalSince(started) <= overallCap {
                let t = "L1"
                try await conn.send(line: "\(t) LIST \"\" \"*\"")
                // Apply strict caps: 50KB or 200 lines, hard timeout 3s
                lines = try await conn.receiveLines(untilTag: t, idleTimeout: quickIdle, hardTimeout: Double(cmdTimeout), maxBytes: 50_000, maxLines: 200)
            }
            let folders = extractFolderNames(from: lines)
            // Early-exit: if we already see all four common folders, skip further work
            if folders.contains(where: { $0.uppercased() == "INBOX" }) &&
               folders.contains(where: { $0.localizedCaseInsensitiveContains("sent") }) &&
               folders.contains(where: { $0.localizedCaseInsensitiveContains("draft") }) &&
               folders.contains(where: { $0.localizedCaseInsensitiveContains("trash") || $0.localizedCaseInsensitiveContains("deleted") }) {
                let quickMap = mapSpecialUse(from: folders, rawListLines: lines)
                q.sync { cache[accountId] = quickMap }
                NotificationCenter.default.post(name: .folderDiscoveryDidUpdate, object: accountId, userInfo: ["map": quickMap])
                try? await commands.logout(conn)
                return .success(quickMap)
            }
            let mapped = mapSpecialUse(from: folders, rawListLines: lines)
            // Cache & logout
            q.sync { cache[accountId] = mapped }
            NotificationCenter.default.post(name: .folderDiscoveryDidUpdate, object: accountId, userInfo: ["map": mapped])
            try? await commands.logout(conn)
            return .success(mapped)
        } catch {
            return .failure(error)
        }
    }
    private enum DiscoveryError: LocalizedError {
        case blockedByTestMode
        var errorDescription: String? {
            switch self {
            case .blockedByTestMode:
                return String(localized: "Ordner-Erkennung ist vorübergehend deaktiviert (Verbindungstest läuft).")
            }
        }
    }

    // Absolute timeout helper for blocking async steps
    private struct AbsoluteTimeoutError: LocalizedError {
        var errorDescription: String? {
            return NSLocalizedString("Zeitüberschreitung bei der Serverantwort.", comment: "Absolute timeout during IMAP discovery")
        }
    }

    private func withAbsoluteTimeout<T>(_ timeout: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AbsoluteTimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: Parsing helpers

    private func containsListLike(_ lines: [String]) -> Bool {
        return lines.contains { line in
            line.hasPrefix("* LIST") || line.hasPrefix("* XLIST") || line.hasPrefix("* LSUB")
        }
    }

    private func extractFolderNames(from lines: [String]) -> [String] {
        // Example: * LIST (\HasNoChildren \Sent) "/" "Sent Items"
        var result: [String] = []
        // Safety cap: avoid processing unbounded LIST dumps
        if lines.count > 2000 { return Array(lines.prefix(2000)) }
        for l in lines where l.hasPrefix("* ") && (l.contains(" LIST ") || l.contains(" XLIST ")) {
            if let lastQuote = l.split(separator: "\"", omittingEmptySubsequences: false).last {
                let name = String(lastQuote)
                if !name.isEmpty { result.append(name) }
                continue
            }
            // Fallback: last whitespace token
            if let last = l.split(whereSeparator: \.isWhitespace).last {
                result.append(String(last))
            }
        }
        return Array(Set(result)) // unique
    }

    private func mapSpecialUse(from folderNames: [String], rawListLines: [String]) -> FolderMap {
        func containsAttr(_ line: String, attr: String) -> Bool {
            line.lowercased().contains("\\\(attr)".lowercased())
        }

        func pick(byAttributes attrs: [String]) -> String? {
            for l in rawListLines {
                if attrs.contains(where: { containsAttr(l, attr: $0) }) {
                    if let quoted = l.split(separator: "\"", omittingEmptySubsequences: false).last {
                        return String(quoted)
                    }
                }
            }
            return nil
        }

        // Prefer explicit SPECIAL-USE attributes
        let inbox = folderNames.first(where: { $0.uppercased() == "INBOX" }) ?? "INBOX"
        let sent  = pick(byAttributes: ["Sent", "SentMail", "SentItems"]) ?? firstMatching(folderNames, patterns: sentNames)
        let drafts = pick(byAttributes: ["Drafts"]) ?? firstMatching(folderNames, patterns: draftNames)
        let trash = pick(byAttributes: ["Trash", "Deleted"]) ?? firstMatching(folderNames, patterns: trashNames)
        let spam  = pick(byAttributes: ["Junk", "Spam"]) ?? firstMatching(folderNames, patterns: spamNames)

        return FolderMap(
            inbox: inbox,
            sent: sent ?? "",
            drafts: drafts ?? "",
            trash: trash ?? "",
            spam: spam ?? ""
        )
    }

    // MARK: Heuristic dictionaries (multi-language)

    private let sentNames: [String] = [
        "sent", "sent items", "gesendet", "gesendete elemente", "inviati", "enviados", "envoyés", "inviati", "送信済み", "발송됨"
    ]

    private let draftNames: [String] = [
        "draft", "drafts", "entwürfe", "bozze", "borradores", "brouillons", "下書き", "임시보관함"
    ]

    private let trashNames: [String] = [
        "trash", "deleted items", "papierkorb", "cestino", "eliminados", "corbeille", "ごみ箱", "휴지통"
    ]

    private let spamNames: [String] = [
        "spam", "junk", "junk e-mail", "unerwünscht", "posta indesiderata", "correo no deseado", "indésirables", "迷惑メール", "스팸"
    ]

    private func firstMatching(_ folders: [String], patterns: [String]) -> String? {
        let lower = folders.map { $0.lowercased() }
        for p in patterns {
            if let idx = lower.firstIndex(where: { $0.contains(p) }) {
                return folders[idx]
            }
        }
        return nil
    }

    private func handleCancelAll() {
        // Log & force-close all active discovery connections
        let conns: [UUID: IMAPConnection] = connRegistryQ.sync { activeConns }
        MailLogger.shared.debug(.CONNECT, accountId: nil, "[Discovery] cancelAll – closing \(conns.count) active connections")
        for (id, c) in conns {
            MailLogger.shared.debug(.CONNECT, accountId: id, "[Discovery] Force-closing IMAP connection")
            c.close()
        }
        connRegistryQ.sync { activeConns.removeAll() }
        // Cancel any running discovery tasks
        Task { await FolderDiscoveryCoordinator.shared.cancelAll() }
    }

    private func handleCancel(accountId: UUID) {
        // Close a single active connection if present
        if let c = connRegistryQ.sync(execute: { activeConns.removeValue(forKey: accountId) }) {
            MailLogger.shared.debug(.CONNECT, accountId: accountId, "[Discovery] Force-closing IMAP connection for account")
            c.close()
        }
        // Also cancel task for this account if any
        Task { await FolderDiscoveryCoordinator.shared.cancel(accountId: accountId) }
    }
    // Debug utility to inspect how many discovery connections are currently tracked
    func _debugDumpActiveConnections(where note: String) {
        let snapshot: (count: Int, keys: [UUID]) = connRegistryQ.sync { (activeConns.count, Array(activeConns.keys)) }
        MailLogger.shared.debug(.CONNECT, accountId: nil, "[Discovery] ActiveConns(\(note)): count=\(snapshot.count) keys=\(snapshot.keys)")
    }


    // MARK: - Advanced folder listing API

    /// Lists folders with attributes and delimiter using IMAP LIST/XLIST/SPECIAL-USE, and optionally returns subscribed-only via LSUB.
    public func listFoldersDetailed(accountId: UUID, login: IMAPLogin, subscribedOnly: Bool = false) async -> Result<[(name: String, delimiter: String?, attributes: [String])], Error> {
        // Block in test mode to avoid greeting race with editor tests
        if connRegistryQ.sync(execute: { isTestMode }) {
            return .failure(DiscoveryError.blockedByTestMode)
        }
        let conn = IMAPConnection(label: "discover.list.\(accountId.uuidString.prefix(6))")
        connRegistryQ.sync { activeConns[accountId] = conn }
        defer { connRegistryQ.sync { activeConns.removeValue(forKey: accountId) }; conn.close() }
        do {
            let cfg = IMAPConnectionConfig(
                host: login.host,
                port: login.port,
                tls: login.useTLS,
                sniHost: login.sniHost,
                connectionTimeoutSec: min(login.connectionTimeoutSec ?? 15, 10),
                commandTimeoutSec: min(login.commandTimeoutSec ?? 10, 6),
                idleTimeoutSec: min(login.idleTimeoutSec ?? 10, 4)
            )
            try await conn.open(cfg)
            let cmds = IMAPCommands()
            _ = try await cmds.greeting(conn)
            try await cmds.login(conn, user: login.username, pass: login.password)

            // Prefer SPECIAL-USE, fallback to LIST; subscribedOnly→LSUB
            var lines: [String] = []
            if subscribedOnly {
                let t = "S1"; try await conn.send(line: "\(t) LSUB \"\" \"*\"")
                lines = try await conn.receiveLines(untilTag: t, idleTimeout: Double(cfg.commandTimeoutSec))
            } else {
                lines = try await cmds.listSpecialUse(conn, idleTimeout: Double(cfg.idleTimeoutSec))
                if !containsListLike(lines) {
                    let t = "L1"; try await conn.send(line: "\(t) LIST \"\" \"*\"")
                    let more = try await conn.receiveLines(untilTag: t, idleTimeout: Double(cfg.idleTimeoutSec))
                    lines.append(contentsOf: more)
                }
            }
            // Parse folder info
            var result: [(String, String?, [String])] = []
            for l in lines where l.hasPrefix("* ") && (l.contains(" LIST ") || l.contains(" LSUB ") || l.contains(" XLIST ")) {
                if let info = try? IMAPParsers().parseListResponse(l) {
                    result.append((info.name, info.delimiter, info.attributes))
                }
            }
            try? await cmds.logout(conn)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    /// Subscribe to a folder (IMAP SUBSCRIBE). Returns success/failure.
    public func subscribe(accountId: UUID, login: IMAPLogin, folder: String) async -> Bool {
        let conn = IMAPConnection(label: "discover.subscribe.\(accountId.uuidString.prefix(6))")
        defer { conn.close() }
        do {
            let cfg = IMAPConnectionConfig(host: login.host, port: login.port, tls: login.useTLS, sniHost: login.sniHost)
            try await conn.open(cfg)
            let cmds = IMAPCommands(); _ = try await cmds.greeting(conn)
            try await cmds.login(conn, user: login.username, pass: login.password)
            let t = "C1"; try await conn.send(line: "\(t) SUBSCRIBE \(folder.quotedIMAP())")
            let lines = try await conn.receiveLines(untilTag: t, idleTimeout: 6)
            try? await cmds.logout(conn)
            return lines.last?.hasPrefix("\(t) OK") == true
        } catch { return false }
    }

    /// Unsubscribe from a folder (IMAP UNSUBSCRIBE). Returns success/failure.
    public func unsubscribe(accountId: UUID, login: IMAPLogin, folder: String) async -> Bool {
        let conn = IMAPConnection(label: "discover.unsubscribe.\(accountId.uuidString.prefix(6))")
        defer { conn.close() }
        do {
            let cfg = IMAPConnectionConfig(host: login.host, port: login.port, tls: login.useTLS, sniHost: login.sniHost)
            try await conn.open(cfg)
            let cmds = IMAPCommands(); _ = try await cmds.greeting(conn)
            try await cmds.login(conn, user: login.username, pass: login.password)
            let t = "C1"; try await conn.send(line: "\(t) UNSUBSCRIBE \(folder.quotedIMAP())")
            let lines = try await conn.receiveLines(untilTag: t, idleTimeout: 6)
            try? await cmds.logout(conn)
            return lines.last?.hasPrefix("\(t) OK") == true
        } catch { return false }
    }

}

private extension String {
    func quotedIMAP() -> String {
        let escaped = self.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

