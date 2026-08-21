import Foundation

protocol LocalAIClient: Sendable {
    func discoverModels() async throws -> [String]
    func complete(systemPrompt: String, text: String, timeout: TimeInterval) async throws -> String
}

actor LocalAIService {
    func discoverModels(configuration: LocalAIConfiguration) async throws -> [String] {
        try Self.validate(configuration: configuration)
        return try await client(configuration: configuration).discoverModels()
    }

    func rewrite(_ text: String, configuration: LocalAIConfiguration) async throws -> String {
        guard configuration.rewriteEnabled, !configuration.model.isEmpty else { return text }
        try Self.validate(configuration: configuration)
        let result = try await client(configuration: configuration).complete(
            systemPrompt: configuration.rewritePrompt,
            text: text,
            timeout: configuration.rewriteTimeoutSeconds
        )
        let polished = Self.plainText(result, fallback: text)
        // A polish that is much longer or much shorter than what went in is not a
        // polish. The model paraphrased, answered a question it invented, or
        // narrated what it was about to do — none of which the owner asked for, and
        // all of which are better replaced by their own words.
        guard Self.isPlausiblePolish(of: text, result: polished) else {
            throw LocalAIError.rewriteDivergedFromSpeech
        }
        return polished
    }

    func summarize(_ transcript: String, configuration: LocalAIConfiguration) async throws -> String {
        guard !configuration.model.isEmpty else { throw LocalAIError.modelNotSelected }
        try Self.validate(configuration: configuration)
        return try await client(configuration: configuration).complete(
            systemPrompt: configuration.summaryPrompt,
            text: transcript,
            timeout: 120
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func client(configuration: LocalAIConfiguration) -> any LocalAIClient {
        switch configuration.provider {
        case .ollama:
            OllamaClient(baseURL: URL(string: configuration.baseURL)!, model: configuration.model)
        case .openAICompatible:
            OpenAICompatibleLocalClient(baseURL: URL(string: configuration.baseURL)!, model: configuration.model)
        }
    }

    private static func validate(configuration: LocalAIConfiguration) throws {
        guard let url = URL(string: configuration.baseURL),
              let host = url.host,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw LocalAIError.invalidEndpoint
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        guard loopback || configuration.allowLAN else { throw LocalAIError.nonLocalEndpoint }
    }

    static func plainText(_ value: String, fallback: String) -> String {
        // Reasoning models emit their scratchpad before the answer. Left in, it would
        // be typed straight into whatever app the owner was writing in.
        var trimmed = value
            .replacingOccurrences(
                of: #"(?s)<(think|thinking|reasoning)>.*?</\1>"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: #"^```[A-Za-z]*\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A model that wraps its answer in quotation marks did not mean them as part
        // of the sentence. Curly quotes open and close with different characters, so
        // the pairs are matched explicitly rather than by comparing the two ends.
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"),
            ("\u{2018}", "\u{2019}"), ("\u{00AB}", "\u{00BB}"),
        ]
        if trimmed.count > 1, let first = trimmed.first, let last = trimmed.last,
           quotePairs.contains(where: { $0 == first && $1 == last }) {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Whether a rewrite is close enough in size to be a tidy-up of the same speech.
    ///
    /// Length is a crude proxy for "same content", but it is the one signal available
    /// without a second model, and it catches the failures that actually happen:
    /// summarising, translating, and answering the dictation instead of cleaning it.
    static func isPlausiblePolish(of original: String, result: String) -> Bool {
        let before = original.trimmingCharacters(in: .whitespacesAndNewlines).count
        let after = result.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard after > 0 else { return false }
        guard before > 0 else { return true }
        // Short dictations swing proportionally on a single word, so allow them an
        // absolute allowance instead of a ratio.
        if abs(after - before) <= 24 { return true }
        let ratio = Double(after) / Double(before)
        return ratio >= 0.5 && ratio <= 1.5
    }
}

struct OllamaClient: LocalAIClient {
    let baseURL: URL
    let model: String
    var session: URLSession = .shared

    func discoverModels() async throws -> [String] {
        let url = baseURL.appending(path: "api/tags")
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return try JSONDecoder().decode(OllamaTags.self, from: data).models.map(\.name).sorted()
    }

    func complete(systemPrompt: String, text: String, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: "<transcript>\n\(text)\n</transcript>"),
            ],
            stream: false
        ))
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(OllamaChatResponse.self, from: data).message.content
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalAIError.invalidResponse
        }
    }
}

struct OpenAICompatibleLocalClient: LocalAIClient {
    let baseURL: URL
    let model: String
    var session: URLSession = .shared

    func discoverModels() async throws -> [String] {
        let (data, response) = try await session.data(from: endpoint("models"))
        try validate(response)
        return try JSONDecoder().decode(OpenAIModels.self, from: data).data.map(\.id).sorted()
    }

    func complete(systemPrompt: String, text: String, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: endpoint("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OpenAIChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: "<transcript>\n\(text)\n</transcript>"),
            ],
            temperature: 0.1
        ))
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let content = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            .choices.first?.message.content else {
            throw LocalAIError.invalidResponse
        }
        return content
    }

    private func endpoint(_ path: String) -> URL {
        let normalized = baseURL.path.hasSuffix("/v1") ? baseURL : baseURL.appending(path: "v1")
        return normalized.appending(path: path)
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalAIError.invalidResponse
        }
    }
}

enum LocalAIError: LocalizedError {
    case invalidEndpoint
    case nonLocalEndpoint
    case modelNotSelected
    case invalidResponse
    case rewriteDivergedFromSpeech

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid HTTP or HTTPS local model endpoint."
        case .nonLocalEndpoint: "Only loopback model servers are allowed unless LAN access is enabled."
        case .modelNotSelected: "Select a local language model first."
        case .invalidResponse: "The local model server returned an invalid response."
        case .rewriteDivergedFromSpeech: "The local model rewrote the dictation instead of tidying it."
        }
    }
}

private struct OllamaTags: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
}

private struct OllamaChatResponse: Decodable {
    let message: ChatMessage
}

private struct OpenAIModels: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable { let message: ChatMessage }
    let choices: [Choice]
}
