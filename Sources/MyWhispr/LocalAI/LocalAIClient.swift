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
        return Self.plainText(result, fallback: text)
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

    private static func plainText(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.hasPrefix("```") {
            return trimmed
                .replacingOccurrences(of: #"^```[A-Za-z]*\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
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

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid HTTP or HTTPS local model endpoint."
        case .nonLocalEndpoint: "Only loopback model servers are allowed unless LAN access is enabled."
        case .modelNotSelected: "Select a local language model first."
        case .invalidResponse: "The local model server returned an invalid response."
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
