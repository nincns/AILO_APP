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

    // MARK: - IMAP Modified UTF-7 Decoder (RFC 3501 Section 5.1.3)

    /// Dekodiert IMAP Modified UTF-7 Strings (z.B. "Entw&APw-rfe" → "Entwürfe")
    private func decodeModifiedUTF7(_ input: String) -> String {
        var result = ""
        var i = input.startIndex

        while i < input.endIndex {
            let char = input[i]

            if char == "&" {
                // Suche nach dem Ende der Base64-Sequenz
                if let dashIndex = input[i...].firstIndex(of: "-") {
                    let base64Start = input.index(after: i)

                    if base64Start == dashIndex {
                        // "&-" ist ein escaped "&"
                        result.append("&")
                    } else {
                        // Dekodiere Base64-Sequenz
                        let base64Str = String(input[base64Start..<dashIndex])
                        // IMAP Modified Base64: "," statt "/" in Standard Base64
                        let standardBase64 = base64Str.replacingOccurrences(of: ",", with: "/")

                        // Padding hinzufügen falls nötig
                        let paddedBase64: String
                        let remainder = standardBase64.count % 4
                        if remainder > 0 {
                            paddedBase64 = standardBase64 + String(repeating: "=", count: 4 - remainder)
                        } else {
                            paddedBase64 = standardBase64
                        }

                        if let data = Data(base64Encoded: paddedBase64) {
                            // UTF-16BE dekodieren
                            let utf16 = data.withUnsafeBytes { ptr -> [UInt16] in
                                let count = data.count / 2
                                var arr = [UInt16]()
                                for j in 0..<count {
                                    let high = UInt16(ptr[j * 2])
                                    let low = UInt16(ptr[j * 2 + 1])
                                    arr.append((high << 8) | low)
                                }
                                return arr
                            }
                            let decoded = String(utf16CodeUnits: utf16, count: utf16.count)
                            result.append(decoded)
                        }
                    }
                    i = input.index(after: dashIndex)
                } else {
                    // Kein "-" gefunden, nimm "&" literal
                    result.append(char)
                    i = input.index(after: i)
                }
            } else {
                result.append(char)
                i = input.index(after: i)
            }
        }

        return result
    }

    private func extractFolderNames(from lines: [String]) -> [String] {
        // Example: * LIST (\HasNoChildren \Sent) "/" "Sent Items"
        var result: [String] = []

        // Safety cap: avoid processing unbounded LIST dumps
        let linesToProcess = lines.count > 2000 ? Array(lines.prefix(2000)) : lines

        for line in linesToProcess {
            guard line.hasPrefix("* ") && (line.contains(" LIST ") || line.contains(" XLIST ")) else {
                continue
            }

            var name: String? = nil

            // Methode 1: Quoted folder name (z.B. "Gesendete Elemente")
            // Finde den LETZTEN quoted String in der Zeile
            if let lastQuoteEnd = line.lastIndex(of: "\"") {
                let beforeLastQuote = line[..<lastQuoteEnd]
                if let lastQuoteStart = beforeLastQuote.lastIndex(of: "\"") {
                    let quotedName = String(line[line.index(after: lastQuoteStart)..<lastQuoteEnd])
                    if !quotedName.isEmpty && quotedName != "/" && quotedName != "." && quotedName != "NIL" {
                        name = quotedName
                    }
                }
            }

            // Methode 2: Unquoted folder name (z.B. INBOX, Drafts)
            if name == nil {
                // Nimm das letzte Whitespace-Token
                let tokens = line.split(whereSeparator: \.isWhitespace)
                if let lastToken = tokens.last {
                    let candidate = String(lastToken).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !candidate.isEmpty && candidate != "/" && candidate != "." && candidate != "NIL" {
                        name = candidate
                    }
                }
            }

            // Dekodiere Modified UTF-7 und füge hinzu
            if var extractedName = name {
                let rawName = extractedName
                extractedName = decodeModifiedUTF7(extractedName)
                extractedName = extractedName.trimmingCharacters(in: .whitespacesAndNewlines)

                if !extractedName.isEmpty {
                    result.append(extractedName)
                    if rawName != extractedName {
                        print("📁 Extracted folder name: '\(extractedName)' (raw: '\(rawName)')")
                    } else {
                        print("📁 Extracted folder name: '\(extractedName)'")
                    }
                }
            }
        }

        return Array(Set(result)) // Unique
    }

    private func mapSpecialUse(from folderNames: [String], rawListLines: [String]) -> FolderMap {
        print("📁 [Discovery] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📁 [Discovery] Mapping \(folderNames.count) folders")
        print("📁 [Discovery] Folders: \(folderNames)")

        // Log alle SPECIAL-USE Flags aus den Raw-Lines
        for line in rawListLines {
            if line.contains("\\Sent") || line.contains("\\Drafts") ||
               line.contains("\\Trash") || line.contains("\\Junk") ||
               line.contains("\\sent") || line.contains("\\drafts") ||
               line.contains("\\trash") || line.contains("\\junk") {
                print("📁 [Discovery] SPECIAL-USE: \(line)")
            }
        }

        func containsAttr(_ line: String, attr: String) -> Bool {
            // RFC 6154: Flags sind case-insensitive und beginnen mit Backslash
            let lineLower = line.lowercased()
            return lineLower.contains("\\\(attr.lowercased())")
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

        // Prefer explicit SPECIAL-USE attributes (RFC 6154 compliant flags only)
        let inbox = folderNames.first(where: { $0.uppercased() == "INBOX" }) ?? "INBOX"
        let sent   = pick(byAttributes: ["Sent"]) ?? firstMatching(folderNames, patterns: sentNames)
        let drafts = pick(byAttributes: ["Drafts"]) ?? firstMatching(folderNames, patterns: draftNames)
        let trash  = pick(byAttributes: ["Trash"]) ?? firstMatching(folderNames, patterns: trashNames)
        let spam   = pick(byAttributes: ["Junk"]) ?? firstMatching(folderNames, patterns: spamNames)

        // Debug: Ergebnis loggen
        print("📁 [Discovery] Result:")
        print("📁 [Discovery]   inbox  = '\(inbox)'")
        print("📁 [Discovery]   sent   = '\(sent ?? "NOT FOUND")'")
        print("📁 [Discovery]   drafts = '\(drafts ?? "NOT FOUND")'")
        print("📁 [Discovery]   trash  = '\(trash ?? "NOT FOUND")'")
        print("📁 [Discovery]   spam   = '\(spam ?? "NOT FOUND")'")
        print("📁 [Discovery] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

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
        // Englisch
        "sent", "sent items", "sent messages", "sent mail", "outbox",
        // Deutsch (inkl. Exchange-Varianten)
        "gesendet", "gesendete elemente", "gesendete objekte", "gesendete nachrichten",
        // Französisch
        "envoyés", "éléments envoyés", "messages envoyés",
        // Spanisch
        "enviados", "elementos enviados", "mensajes enviados",
        // Italienisch
        "inviati", "posta inviata", "elementi inviati",
        // Asiatisch
        "送信済み", "발송됨", "已发送"
    ]

    private let draftNames: [String] = [
        // Englisch
        "draft", "drafts",
        // Deutsch
        "entwurf", "entwürfe",
        // Französisch
        "brouillon", "brouillons",
        // Spanisch
        "borrador", "borradores",
        // Italienisch
        "bozza", "bozze",
        // Asiatisch
        "下書き", "임시보관함", "草稿"
    ]

    private let trashNames: [String] = [
        // Englisch
        "trash", "deleted", "deleted items", "deleted messages", "bin", "rubbish",
        // Deutsch (inkl. Exchange-Varianten)
        "papierkorb", "gelöscht", "gelöschte elemente", "gelöschte objekte", "gelöschte nachrichten",
        // Französisch
        "corbeille", "éléments supprimés", "messages supprimés",
        // Spanisch
        "papelera", "eliminados", "elementos eliminados",
        // Italienisch
        "cestino", "eliminati", "elementi eliminati",
        // Asiatisch
        "ごみ箱", "휴지통", "已删除"
    ]

    private let spamNames: [String] = [
        // Englisch
        "spam", "junk", "junk e-mail", "junk email", "junk mail", "junk-email", "bulk", "bulk mail",
        // Deutsch (WICHTIG: Mit und ohne Bindestrich!)
        "junk-e-mail", "unerwünscht", "unerwünschte werbung", "werbung",
        // Französisch
        "indésirables", "courrier indésirable", "pourriel",
        // Spanisch
        "correo no deseado", "no deseado",
        // Italienisch
        "posta indesiderata", "indesiderata",
        // Asiatisch
        "迷惑メール", "스팸", "垃圾邮件"
    ]

    /// Findet den ersten Ordner der einem Pattern entspricht (case-insensitive)
    /// Gibt den ORIGINALEN Ordnernamen zurück (nicht lowercase!)
    private func firstMatching(_ folders: [String], patterns: [String]) -> String? {
        let patternsLower = patterns.map { $0.lowercased() }

        // 1. Priorität: Exakter Match (case-insensitive)
        for folder in folders {
            let folderLower = folder.lowercased()
            if patternsLower.contains(folderLower) {
                print("📁 [Discovery] Exact match: '\(folder)' matches pattern")
                return folder
            }
        }

        // 2. Priorität: Ordnername enthält Pattern
        for folder in folders {
            let folderLower = folder.lowercased()
            for pattern in patternsLower {
                if folderLower.contains(pattern) && pattern.count >= 4 {
                    // Nur Patterns mit min. 4 Zeichen für Substring-Match
                    print("📁 [Discovery] Substring match: '\(folder)' contains '\(pattern)'")
                    return folder
                }
            }
        }

        // 3. Priorität: Pattern enthält Ordnername (für kurze Ordnernamen)
        for folder in folders {
            let folderLower = folder.lowercased()
            if folderLower.count >= 4 {
                for pattern in patternsLower {
                    if pattern.contains(folderLower) {
                        print("📁 [Discovery] Reverse match: pattern '\(pattern)' contains '\(folder)'")
                        return folder
                    }
                }
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

