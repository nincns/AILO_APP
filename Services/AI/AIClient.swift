import Foundation

/// Zentraler HTTP‑Client für AI‑Operationen (OpenAI / Ollama).
/// Aktuell nur: Rewrite eines Textes mit optionalem Pre‑Prompt.
///
/// Verwendung:
/// AIClient.rewrite(
///     baseURL: "https://api.openai.com",
///     port: "443",
///     apiKey: "...",
///     model: "gpt-5-chat-latest",
///     prePrompt: "Überarbeite den Text…",
///     userText: "Mein Originaltext",
///     completion: { result in ... }
/// )
enum AIClient {

    // Fehlerbild für die UI
    enum ClientError: LocalizedError {
        case invalidBaseURL
        case invalidHTTPResponse
        case httpStatus(Int)
        case emptyResponse
        case decoding
        case other(Error)
        case endpointNotFound

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:        return "Ungültige Serveradresse."
            case .invalidHTTPResponse:   return "Ungültige Serverantwort."
            case .httpStatus(let code):  return "HTTP-Fehler \(code)."
            case .emptyResponse:         return "Leere Antwort."
            case .decoding:              return "Antwort konnte nicht gelesen werden."
            case .other(let err):        return err.localizedDescription
            case .endpointNotFound:      return "Endpoint nicht gefunden."
            }
        }
    }

    /// Führt eine Überarbeitung durch. Erkennt automatisch OpenAI (Chat Completions)
    /// vs. Ollama ( /api/chat oder /api/generate ).
    ///
    /// An empty base is treated as `https://api.openai.com` and port defaults to 443,
    /// to mirror the behaviour in the configuration hint.
    static func rewrite(
        baseURL: String,
        port: String?,
        apiKey: String?,
        model: String,
        prePrompt: String,
        userText: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        #if DEBUG
        _debugPrintBase(baseURL, port: port)
        #endif
        // 0) Fallback: Ausgewählten Provider aus UserDefaults laden
        let fb = _selectedProviderFallback()
        // 1) Effektive Parameter bestimmen: übergebene Werte haben Priorität, sonst Fallback
        let effBase: String = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (fb.baseURL ?? baseURL) : baseURL
        let effPort: String? = {
            let p = (port ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? fb.port : port
        }()
        let effKey: String? = {
            if let k = apiKey, !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return k }
            return fb.apiKey
        }()
        let effModel: String = {
            let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? (fb.model ?? model) : model
        }()
        // 2) Basis‑URL normalisieren
        guard let root = normalizedRootURL(effBase, port: effPort) else {
            // Letzter Versuch: direkt mit dem Fallback‑Provider normalisieren
            if let fbBase = fb.baseURL, let r2 = normalizedRootURL(fbBase, port: fb.port) {
                if isOpenAI(r2) {
                    callOpenAI(root: r2, apiKey: effKey ?? "", model: effModel, prePrompt: prePrompt, userText: userText, completion: completion)
                } else {
                    callOllama(root: r2, apiKey: effKey, model: effModel, prePrompt: prePrompt, userText: userText, completion: completion)
                }
                return
            }
            completion(.failure(ClientError.invalidBaseURL))
            return
        }
        // 3) Zweigwahl: OpenAI vs. Ollama
        if isOpenAI(root) {
            callOpenAI(root: root, apiKey: effKey ?? "", model: effModel, prePrompt: prePrompt, userText: userText, completion: completion)
        } else {
            callOllama(root: root, apiKey: effKey, model: effModel, prePrompt: prePrompt, userText: userText, completion: completion)
        }
    }
}

// MARK: - Helpers
private extension AIClient {

    static let _session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        // keine Proxies/Cache erzwingen
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    static func normalizedRootURL(_ base: String, port: String?) -> URL? {
        // 0) Ausgangsstring trimmen & unsichtbare Zeichen entfernen
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leerer String → Standard OpenAI‑Root
        if trimmed.isEmpty { trimmed = "https://api.openai.com" }
        let zeroWidth = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
        trimmed = String(trimmed.unicodeScalars.filter { !zeroWidth.contains($0) })

        // 1) Häufige Kopier-/Tippfehler automatisch korrigieren
        //    "https//example.com"  -> "https://example.com"
        //    "http//example.com"   -> "http://example.com"
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https//") && !trimmed.contains("://") {
            trimmed = "https://" + trimmed.dropFirst("https//".count)
        } else if lower.hasPrefix("http//") && !trimmed.contains("://") {
            trimmed = "http://" + trimmed.dropFirst("http//".count)
        }

        // 2) Wenn kein Schema angegeben ist → https voranstellen
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }

        // 3) Backslashes (z. B. aus kopierten Pfaden) in normale Slashes wandeln
        trimmed = trimmed.replacingOccurrences(of: "\\", with: "/")

        // 4) URL zerlegen (wir akzeptieren auch Strings mit Pfad, der später entfernt wird)
        guard let comps = URLComponents(string: trimmed) else { return nil }

        // 5) Host muss vorhanden sein
        guard let scheme = comps.scheme, let host = comps.host, !host.isEmpty else {
            return nil
        }

        // 6) Port bestimmen:
        //    - wenn in der URL schon vorhanden → verwenden
        //    - sonst Port-String (falls numerisch & nicht 443) verwenden
        //    - ansonsten nil (Standard-HTTPS)
        let currentPort = comps.port
        let pStringRaw = (port ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pString = pStringRaw.isEmpty ? nil : pStringRaw
        let providedPort: Int? = {
            if let p = pString, let v = Int(p), v > 0, v < 65536 { return v }
            return nil
        }()
        let effectivePort: Int? = {
            if let currentPort { return currentPort }
            if let providedPort, providedPort != 443 { return providedPort }
            return nil
        }()

        // 7) Root-URL ohne Pfad/Query/Fragment aufbauen
        var rootComps = URLComponents()
        rootComps.scheme = scheme
        rootComps.host   = host
        rootComps.port   = effectivePort
        rootComps.path   = "" // explizit Root
        rootComps.query  = nil
        rootComps.fragment = nil

        return rootComps.url
    }

    /// Liefert den ausgewählten Provider aus UserDefaults als leichtgewichtigen Fallback.
    static func _selectedProviderFallback() -> (baseURL: String?, port: String?, apiKey: String?, model: String?) {
        let ud = UserDefaults.standard
        let listKey = "config.ai.providers.list"
        let selKey  = "config.ai.providers.selected"
        struct ProviderLite: Codable {
            let id: String?
            let baseURL: String?
            let port: String?
            let apiKey: String?
            let model: String?
        }
        guard let data = ud.data(forKey: listKey),
              let arr  = try? JSONDecoder().decode([ProviderLite].self, from: data) else {
            return (nil, nil, nil, nil)
        }
        let selID = ud.string(forKey: selKey)
        let chosen = arr.first { $0.id == selID } ?? arr.first
        return (chosen?.baseURL, chosen?.port, chosen?.apiKey, chosen?.model)
    }

    #if DEBUG
    static func _debugPrintBase(_ base: String, port: String?) {
        print("AIClient DEBUG base='\(base)' port='\(port ?? "")'")
    }
    #endif

    /// Prüft ob der Host eine OpenAI-kompatible API hat (OpenAI, Mistral, etc.)
    static func isOpenAI(_ root: URL) -> Bool {
        let host = (root.host ?? "").lowercased()
        return host.contains("openai.com") || host.contains("mistral.ai")
    }

    static func url(_ root: URL, path: String) -> URL? {
        var base = root
        // Ensure base URL has no trailing slash so that appending works predictably
        let abs = base.absoluteString
        if abs.hasSuffix("/") {
            guard let u = URL(string: String(abs.dropLast())) else { return nil }
            base = u
        }
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent(clean)
    }

    // MARK: OpenAI
    static func callOpenAI(
        root: URL,
        apiKey: String,
        model: String,
        prePrompt: String,
        userText: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = url(root, path: "/v1/chat/completions") else {
            DispatchQueue.main.async { completion(.failure(ClientError.invalidBaseURL)) }
            return
        }

        struct Req: Encodable {
            let model: String
            let messages: [[String: String]]
            // bewusst konservativ: keine Temperature, um Fehler zu vermeiden
        }

        let sys = prePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let usr = userText.trimmingCharacters(in: .whitespacesAndNewlines)

        let body = Req(
            model: model,
            messages: [
                ["role": "system", "content": sys.isEmpty ? "You are a helpful assistant." : sys],
                ["role": "user", "content": usr]
            ]
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("close", forHTTPHeaderField: "Connection")
        req.timeoutInterval = 45
        req.httpBody = try? JSONEncoder().encode(body)

        _session.dataTask(with: req) { data, resp, err in
            if let err = err {
                return DispatchQueue.main.async { completion(.failure(ClientError.other(err))) }
            }
            guard let http = resp as? HTTPURLResponse else {
                return DispatchQueue.main.async { completion(.failure(ClientError.invalidHTTPResponse)) }
            }
            if http.statusCode == 404 {
                return DispatchQueue.main.async { completion(.failure(ClientError.endpointNotFound)) }
            }
            guard (200...299).contains(http.statusCode) else {
                return DispatchQueue.main.async { completion(.failure(ClientError.httpStatus(http.statusCode))) }
            }
            guard let data = data else {
                return DispatchQueue.main.async { completion(.failure(ClientError.emptyResponse)) }
            }
            // Minimal Parsing auf die erste Choice
            if
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let first = choices.first,
                let msg = first["message"] as? [String: Any],
                let content = msg["content"] as? String
            {
                return DispatchQueue.main.async { completion(.success(content)) }
            }
            DispatchQueue.main.async { completion(.failure(ClientError.decoding)) }
        }.resume()
    }

    // MARK: Ollama
    static func callOllama(
        root: URL,
        apiKey: String?,
        model: String,
        prePrompt: String,
        userText: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // /api/generate (ältere) oder /api/chat (neuere), jetzt generate zuerst
        let paths = ["/api/generate", "/api/chat"]
        func tryNext(_ i: Int) {
            if i >= paths.count {
                return DispatchQueue.main.async { completion(.failure(ClientError.invalidBaseURL)) }
            }
            guard let url = url(root, path: paths[i]) else { return tryNext(i+1) }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let key = apiKey, !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            req.setValue("close", forHTTPHeaderField: "Connection")
            req.timeoutInterval = 45

            // zwei Formate unterstützen
            let sys = prePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let usr = userText.trimmingCharacters(in: .whitespacesAndNewlines)

            let payloadChat: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": sys.isEmpty ? "You are a helpful assistant." : sys],
                    ["role": "user", "content": usr]
                ],
                "stream": false
            ]

            let payloadGenerate: [String: Any] = [
                "model": model,
                "prompt": (sys.isEmpty ? "" : sys + "\n\n") + usr,
                "stream": false
            ]

            let bodyObj = (paths[i] == "/api/chat") ? payloadChat : payloadGenerate
            req.httpBody = try? JSONSerialization.data(withJSONObject: bodyObj)

            _session.dataTask(with: req) { data, resp, err in
                if let err = err {
                    return DispatchQueue.main.async { completion(.failure(ClientError.other(err))) }
                }
                guard let http = resp as? HTTPURLResponse else {
                    return DispatchQueue.main.async { completion(.failure(ClientError.invalidHTTPResponse)) }
                }
                if http.statusCode == 404 {
                    return DispatchQueue.main.async { completion(.failure(ClientError.endpointNotFound)) }
                }
                guard (200...299).contains(http.statusCode) else {
                    return DispatchQueue.main.async { completion(.failure(ClientError.httpStatus(http.statusCode))) }
                }
                guard let data = data else {
                    return DispatchQueue.main.async { completion(.failure(ClientError.emptyResponse)) }
                }
                if
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    // /api/chat → { message: { content: "..." } }
                    if let message = json["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        return DispatchQueue.main.async { completion(.success(content)) }
                    }
                    // /api/generate → { response: "..." }
                    if let content = json["response"] as? String {
                        return DispatchQueue.main.async { completion(.success(content)) }
                    }
                }
                // Falls der erste Pfad nicht passte, den nächsten testen
                if i == 0 { return tryNext(1) }
                DispatchQueue.main.async { completion(.failure(ClientError.decoding)) }
            }.resume()
        }
        tryNext(0)
    }
}
