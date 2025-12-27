// Services/AI/AIClient.swift
// AILO - Zentraler HTTP-Client für AI-Operationen
// Unterstützt: OpenAI, Mistral (OpenAI-kompatibel), Ollama, Anthropic

import Foundation

enum AIClient {

    // MARK: - Errors

    enum ClientError: LocalizedError {
        case invalidBaseURL
        case invalidHTTPResponse
        case httpStatus(Int)
        case emptyResponse
        case decoding
        case other(Error)
        case endpointNotFound
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL: return String(localized: "ai.error.invalidBaseURL")
            case .invalidHTTPResponse: return String(localized: "ai.error.invalidHTTPResponse")
            case .httpStatus(let code): return String(format: String(localized: "ai.error.httpStatus"), code)
            case .emptyResponse: return String(localized: "ai.error.emptyResponse")
            case .decoding: return String(localized: "ai.error.decoding")
            case .other(let err): return err.localizedDescription
            case .endpointNotFound: return String(localized: "ai.error.endpointNotFound")
            case .missingAPIKey: return String(localized: "ai.error.missingAPIKey")
            }
        }
    }

    // MARK: - Main Entry Point

    /// Führt eine Überarbeitung durch. Erkennt automatisch den API-Typ.
    static func rewrite(
        baseURL: String,
        port: String?,
        apiKey: String?,
        model: String,
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        topP: Double? = nil,
        prePrompt: String,
        userText: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        #if DEBUG
        print("AIClient: base='\(baseURL)' port='\(port ?? "")' model='\(model)'")
        #endif

        // Fallback: Ausgewählten Provider aus UserDefaults laden
        let fb = _selectedProviderFallback()

        // Effektive Parameter bestimmen
        let effBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fb.baseURL ?? "https://api.openai.com")
            : baseURL
        let effPort: String? = {
            let p = (port ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? fb.port : port
        }()
        let effKey: String? = {
            if let k = apiKey, !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return k }
            return fb.apiKey
        }()
        let effModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fb.model ?? "gpt-4o")
            : model
        let effTemp = fb.temperature ?? temperature
        let effMaxTokens = fb.maxTokens ?? maxTokens
        let effTopP = fb.topP ?? topP

        // Basis-URL normalisieren
        guard let root = normalizedRootURL(effBase, port: effPort) else {
            completion(.failure(ClientError.invalidBaseURL))
            return
        }

        // API-Typ erkennen und routen
        let apiType = detectAPIType(root)

        switch apiType {
        case .anthropic:
            callAnthropic(
                root: root,
                apiKey: effKey ?? "",
                model: effModel,
                temperature: effTemp,
                maxTokens: effMaxTokens,
                topP: effTopP,
                prePrompt: prePrompt,
                userText: userText,
                completion: completion
            )

        case .openAI:
            callOpenAI(
                root: root,
                apiKey: effKey ?? "",
                model: effModel,
                temperature: effTemp,
                maxTokens: effMaxTokens,
                topP: effTopP,
                prePrompt: prePrompt,
                userText: userText,
                completion: completion
            )

        case .ollama:
            callOllama(
                root: root,
                apiKey: effKey,
                model: effModel,
                temperature: effTemp,
                prePrompt: prePrompt,
                userText: userText,
                completion: completion
            )
        }
    }

    // MARK: - API Type Detection

    private enum APIType {
        case openAI     // OpenAI, Mistral, etc.
        case anthropic  // Anthropic Claude
        case ollama     // Local Ollama
    }

    private static func detectAPIType(_ root: URL) -> APIType {
        let host = (root.host ?? "").lowercased()

        if host.contains("anthropic.com") {
            return .anthropic
        } else if host.contains("openai.com") || host.contains("mistral.ai") {
            return .openAI
        } else if host.contains("localhost") || host.contains("127.0.0.1") {
            // Lokale Instanz: Ollama oder OpenAI-kompatibel je nach Port
            let port = root.port ?? 443
            if port == 11434 {
                return .ollama
            }
            return .openAI // Default für andere lokale Ports
        }

        // Default: OpenAI-kompatibel
        return .openAI
    }
}

// MARK: - OpenAI Compatible API

private extension AIClient {

    static func callOpenAI(
        root: URL,
        apiKey: String,
        model: String,
        temperature: Double,
        maxTokens: Int,
        topP: Double?,
        prePrompt: String,
        userText: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = url(root, path: "/v1/chat/completions") else {
            return DispatchQueue.main.async { completion(.failure(ClientError.invalidBaseURL)) }
        }

        let sys = prePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let usr = userText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Request Body aufbauen
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": sys.isEmpty ? "You are a helpful assistant." : sys],
                ["role": "user", "content": usr]
            ],
            "temperature": temperature,
            "max_tokens": maxTokens
        ]

        // Optional: top_p nur wenn != 1.0
        if let topP = topP, topP < 1.0 {
            body["top_p"] = topP
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 60
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _session.dataTask(with: req) { data, resp, err in
            if let err = err {
                return DispatchQueue.main.async { completion(.failure(ClientError.other(err))) }
            }
            guard let http = resp as? HTTPURLResponse else {
                return DispatchQueue.main.async { completion(.failure(ClientError.invalidHTTPResponse)) }
            }
            guard (200...299).contains(http.statusCode) else {
                return DispatchQueue.main.async { completion(.failure(ClientError.httpStatus(http.statusCode))) }
            }
            guard let data = data else {
                return DispatchQueue.main.async { completion(.failure(ClientError.emptyResponse)) }
            }

            // Parse Response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let content = msg["content"] as? String {
                return DispatchQueue.main.async { completion(.success(content)) }
            }

            DispatchQueue.main.async { completion(.failure(ClientError.decoding)) }
        }.resume()
    }
}

// MARK: - Anthropic API

private extension AIClient {

    static func callAnthropic(
        root: URL,
        apiKey: String,
        model: String,
        temperature: Double,
        maxTokens: Int,
        topP: Double?,
        prePrompt: String,
        userText: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard !apiKey.isEmpty else {
            return DispatchQueue.main.async { completion(.failure(ClientError.missingAPIKey)) }
        }

        guard let url = url(root, path: "/v1/messages") else {
            return DispatchQueue.main.async { completion(.failure(ClientError.invalidBaseURL)) }
        }

        let sys = prePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let usr = userText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Anthropic Request Body (unterscheidet sich von OpenAI!)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": usr]
            ]
        ]

        // System-Prompt ist bei Anthropic ein separates Feld
        if !sys.isEmpty {
            body["system"] = sys
        }

        // Optional parameters
        body["temperature"] = min(temperature, 1.0) // Anthropic: max 1.0

        if let topP = topP, topP < 1.0 {
            body["top_p"] = topP
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        // Anthropic-spezifische Header!
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        req.timeoutInterval = 60
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _session.dataTask(with: req) { data, resp, err in
            if let err = err {
                return DispatchQueue.main.async { completion(.failure(ClientError.other(err))) }
            }
            guard let http = resp as? HTTPURLResponse else {
                return DispatchQueue.main.async { completion(.failure(ClientError.invalidHTTPResponse)) }
            }
            guard (200...299).contains(http.statusCode) else {
                // Anthropic gibt detaillierte Fehlermeldungen
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return DispatchQueue.main.async { completion(.failure(ClientError.other(NSError(domain: "Anthropic", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])))) }
                }
                return DispatchQueue.main.async { completion(.failure(ClientError.httpStatus(http.statusCode))) }
            }
            guard let data = data else {
                return DispatchQueue.main.async { completion(.failure(ClientError.emptyResponse)) }
            }

            // Parse Anthropic Response
            // Format: { "content": [{ "type": "text", "text": "..." }] }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [[String: Any]],
               let first = content.first,
               let text = first["text"] as? String {
                return DispatchQueue.main.async { completion(.success(text)) }
            }

            DispatchQueue.main.async { completion(.failure(ClientError.decoding)) }
        }.resume()
    }
}

// MARK: - Ollama API

private extension AIClient {

    static func callOllama(
        root: URL,
        apiKey: String?,
        model: String,
        temperature: Double,
        prePrompt: String,
        userText: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let paths = ["/api/chat", "/api/generate"]

        func tryNext(_ i: Int) {
            if i >= paths.count {
                return DispatchQueue.main.async { completion(.failure(ClientError.endpointNotFound)) }
            }

            guard let url = url(root, path: paths[i]) else {
                return tryNext(i + 1)
            }

            let sys = prePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let usr = userText.trimmingCharacters(in: .whitespacesAndNewlines)

            var body: [String: Any]

            if paths[i] == "/api/chat" {
                body = [
                    "model": model,
                    "messages": [
                        ["role": "system", "content": sys.isEmpty ? "You are a helpful assistant." : sys],
                        ["role": "user", "content": usr]
                    ],
                    "stream": false,
                    "options": ["temperature": temperature]
                ]
            } else {
                body = [
                    "model": model,
                    "prompt": (sys.isEmpty ? "" : sys + "\n\n") + usr,
                    "stream": false,
                    "options": ["temperature": temperature]
                ]
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key = apiKey, !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            req.timeoutInterval = 60
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            _session.dataTask(with: req) { data, resp, err in
                if let err = err {
                    return DispatchQueue.main.async { completion(.failure(ClientError.other(err))) }
                }
                guard let http = resp as? HTTPURLResponse else {
                    return DispatchQueue.main.async { completion(.failure(ClientError.invalidHTTPResponse)) }
                }

                if http.statusCode == 404 {
                    return tryNext(i + 1)
                }

                guard (200...299).contains(http.statusCode) else {
                    return DispatchQueue.main.async { completion(.failure(ClientError.httpStatus(http.statusCode))) }
                }
                guard let data = data else {
                    return DispatchQueue.main.async { completion(.failure(ClientError.emptyResponse)) }
                }

                // Parse Response
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // /api/chat: { "message": { "content": "..." } }
                    if let message = json["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        return DispatchQueue.main.async { completion(.success(content)) }
                    }
                    // /api/generate: { "response": "..." }
                    if let content = json["response"] as? String {
                        return DispatchQueue.main.async { completion(.success(content)) }
                    }
                }

                if i == 0 { return tryNext(1) }
                DispatchQueue.main.async { completion(.failure(ClientError.decoding)) }
            }.resume()
        }

        tryNext(0)
    }
}

// MARK: - Helpers

private extension AIClient {

    static let _session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    static func normalizedRootURL(_ base: String, port: String?) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = "https://api.openai.com" }

        // Zero-width characters entfernen
        let zeroWidth = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
        trimmed = String(trimmed.unicodeScalars.filter { !zeroWidth.contains($0) })

        // Schema korrigieren
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https//") && !trimmed.contains("://") {
            trimmed = "https://" + trimmed.dropFirst("https//".count)
        } else if lower.hasPrefix("http//") && !trimmed.contains("://") {
            trimmed = "http://" + trimmed.dropFirst("http//".count)
        }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }

        trimmed = trimmed.replacingOccurrences(of: "\\", with: "/")

        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme,
              let host = comps.host, !host.isEmpty else {
            return nil
        }

        // Port bestimmen
        let currentPort = comps.port
        let pString = (port ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let providedPort: Int? = Int(pString).flatMap { $0 > 0 && $0 < 65536 ? $0 : nil }
        let effectivePort: Int? = currentPort ?? (providedPort != 443 ? providedPort : nil)

        var rootComps = URLComponents()
        rootComps.scheme = scheme
        rootComps.host = host
        rootComps.port = effectivePort
        rootComps.path = ""

        return rootComps.url
    }

    static func url(_ root: URL, path: String) -> URL? {
        var base = root
        let abs = base.absoluteString
        if abs.hasSuffix("/") {
            guard let u = URL(string: String(abs.dropLast())) else { return nil }
            base = u
        }
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent(clean)
    }

    /// Liefert den ausgewählten Provider aus UserDefaults
    static func _selectedProviderFallback() -> (
        baseURL: String?,
        port: String?,
        apiKey: String?,
        model: String?,
        temperature: Double?,
        maxTokens: Int?,
        topP: Double?
    ) {
        let ud = UserDefaults.standard
        let listKey = "config.ai.providers.list"
        let selKey = "config.ai.providers.selected"

        struct ProviderLite: Codable {
            let id: UUID?
            let baseURL: String?
            let port: String?
            let apiKey: String?
            let model: String?
            let temperature: Double?
            let maxTokens: Int?
            let topP: Double?
        }

        guard let data = ud.data(forKey: listKey),
              let arr = try? JSONDecoder().decode([ProviderLite].self, from: data) else {
            return (nil, nil, nil, nil, nil, nil, nil)
        }

        let selID = ud.string(forKey: selKey).flatMap { UUID(uuidString: $0) }
        let chosen = arr.first { $0.id == selID } ?? arr.first

        return (
            chosen?.baseURL,
            chosen?.port,
            chosen?.apiKey,
            chosen?.model,
            chosen?.temperature,
            chosen?.maxTokens,
            chosen?.topP
        )
    }
}
