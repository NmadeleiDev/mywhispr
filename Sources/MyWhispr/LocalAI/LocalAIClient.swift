import Foundation

/// One turn in a conversation with a local model.
struct LocalAIMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    var role: Role
    var content: String

    static func system(_ content: String) -> LocalAIMessage { .init(role: .system, content: content) }
    static func user(_ content: String) -> LocalAIMessage { .init(role: .user, content: content) }
    static func assistant(_ content: String) -> LocalAIMessage { .init(role: .assistant, content: content) }
}

/// One request to a local model server.
struct LocalAIRequest: Equatable, Sendable {
    var messages: [LocalAIMessage]
    /// How long the server may go silent before the request is treated as dead.
    ///
    /// Not a total budget. Answering a question about an hour of speech legitimately
    /// takes a long time, and the length of the answer is not something to police —
    /// the owner has a Stop button. What is worth catching is a server that has
    /// stopped talking altogether.
    var idleTimeout: TimeInterval
    var temperature: Double = 0.2
    /// The context window to ask for, where the protocol lets a request choose one.
    ///
    /// Ollama otherwise picks its own — a few thousand tokens on most machines —
    /// and quietly drops whatever does not fit. For a meeting transcript that means
    /// answering questions about the last few minutes while claiming to have read
    /// the whole thing, which is worse than refusing.
    var contextTokens: Int?
}

protocol LocalAIClient: Sendable {
    func discoverModels() async throws -> [String]
    /// Streams one answer, calling `onDelta` with each fragment in the order the
    /// server produced it. Returns when the answer is complete.
    func stream(_ request: LocalAIRequest, onDelta: @Sendable @escaping (String) async -> Void) async throws
}

extension LocalAIClient {
    /// The whole answer at once, for callers with nothing to do until it is
    /// finished.
    ///
    /// Built on the streaming path rather than beside it, so there is one request
    /// shape, one parser, and one place where a server's dialect and its reasoning
    /// scratchpad are dealt with.
    func complete(_ request: LocalAIRequest) async throws -> String {
        let collected = TextCollector()
        try await stream(request) { await collected.append($0) }
        return await collected.text
    }
}

private actor TextCollector {
    private(set) var text = ""
    func append(_ chunk: String) { text += chunk }
}

actor LocalAIService {
    func discoverModels(configuration: LocalAIConfiguration) async throws -> [String] {
        try Self.validate(configuration: configuration)
        return try await client(configuration: configuration, model: configuration.model).discoverModels()
    }

    func rewrite(_ text: String, configuration: LocalAIConfiguration) async throws -> String {
        guard configuration.rewriteEnabled, !configuration.model.isEmpty else { return text }
        try Self.validate(configuration: configuration)
        let request = LocalAIRequest(
            messages: [
                .system(configuration.rewritePrompt),
                .user("<transcript>\n\(text)\n</transcript>"),
            ],
            idleTimeout: configuration.rewriteTimeoutSeconds,
            temperature: 0.1
        )
        // Rewriting happens inside the gap between releasing the key and seeing text
        // appear, so it gets a total deadline rather than only an idle one: a model
        // that answers slowly is as useless here as one that does not answer.
        let result = try await Self.withDeadline(configuration.rewriteTimeoutSeconds) {
            try await self.client(configuration: configuration, model: configuration.model).complete(request)
        }
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

    func summarize(
        _ transcript: String,
        configuration: LocalAIConfiguration
    ) async throws -> MeetingSummary {
        let model = configuration.effectiveSummaryModel
        guard !model.isEmpty else { throw LocalAIError.modelNotSelected }
        try Self.validate(configuration: configuration)
        let messages = Self.summaryMessages(transcript, configuration: configuration)
        let request = LocalAIRequest(
            messages: messages,
            idleTimeout: 180,
            temperature: 0.2,
            contextTokens: TokenBudget.context(for: messages, limit: configuration.maxContextTokens)
        )
        let answer = try await client(configuration: configuration, model: model).complete(request)
        return try MeetingSummary.parse(answer)
    }

    static func summaryMessages(
        _ transcript: String,
        configuration: LocalAIConfiguration
    ) -> [LocalAIMessage] {
        [
            .system("""
            \(configuration.summaryPrompt)

            Also create a specific, scannable title for this recording based only on \
            the transcript. The title must be plain text, at most 80 characters, and \
            must not include a date, quotation marks, Markdown, or a generic label \
            such as "Meeting". \(configuration.summaryLanguage.promptInstruction)

            Use standard Markdown only. Do not use LaTeX or dollar-delimited math. \
            Write symbols as Unicode (for example, → and ≥), and write currency \
            normally (for example, $20,000). If you use a table, emit a valid \
            Markdown pipe table with one row per line and a separator row.

            Return exactly this envelope, with no text outside it:
            <title>Short recording title</title>
            <summary>
            Markdown meeting notes
            </summary>
            """),
            .user("<transcript>\n\(transcript)\n</transcript>"),
        ]
    }

    /// Answers one question about a meeting, streaming the answer as it is written.
    ///
    /// The caller assembles the messages, because what the model is told about the
    /// meeting is a decision about the conversation, not about the transport.
    func answer(
        _ messages: [LocalAIMessage],
        contextTokens: Int?,
        configuration: LocalAIConfiguration,
        onDelta: @Sendable @escaping (String) async -> Void
    ) async throws {
        let model = configuration.effectiveSummaryModel
        guard !model.isEmpty else { throw LocalAIError.modelNotSelected }
        try Self.validate(configuration: configuration)
        let request = LocalAIRequest(
            messages: messages,
            idleTimeout: 300,
            temperature: 0.2,
            contextTokens: contextTokens
        )
        try await client(configuration: configuration, model: model).stream(request, onDelta: onDelta)
    }

    private func client(configuration: LocalAIConfiguration, model: String) -> any LocalAIClient {
        switch configuration.provider {
        case .ollama:
            OllamaClient(baseURL: URL(string: configuration.baseURL)!, model: model)
        case .openAICompatible:
            OpenAICompatibleLocalClient(baseURL: URL(string: configuration.baseURL)!, model: model)
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

    /// Fails the work if it has not finished within `seconds`.
    ///
    /// `URLRequest.timeoutInterval` bounds the silence between packets, not the whole
    /// exchange, so it cannot express "this must be done by then" on its own.
    private static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LocalAIError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LocalAIError.timedOut }
            return first
        }
    }

    static func plainText(_ value: String, fallback: String) -> String {
        var trimmed = ReasoningFilter.strip(value).trimmingCharacters(in: .whitespacesAndNewlines)
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

struct MeetingSummary: Equatable, Sendable {
    var title: String
    var markdown: String

    static func parse(_ response: String) throws -> MeetingSummary {
        guard let titleRange = response.range(of: "<title>"),
              let titleEnd = response.range(of: "</title>", range: titleRange.upperBound..<response.endIndex),
              let summaryRange = response.range(of: "<summary>", range: titleEnd.upperBound..<response.endIndex),
              let summaryEnd = response.range(of: "</summary>", range: summaryRange.upperBound..<response.endIndex) else {
            throw LocalAIError.invalidSummaryResponse
        }

        let outside = response[..<titleRange.lowerBound] + response[summaryEnd.upperBound...]
        let title = response[titleRange.upperBound..<titleEnd.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = response[summaryRange.upperBound..<summaryEnd.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard outside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.isEmpty,
              title.count <= 80,
              !title.contains("\n"),
              !markdown.isEmpty else {
            throw LocalAIError.invalidSummaryResponse
        }
        return MeetingSummary(title: title, markdown: markdown)
    }
}

// MARK: - Ollama

struct OllamaClient: LocalAIClient {
    let baseURL: URL
    let model: String
    var session: URLSession = .shared

    func discoverModels() async throws -> [String] {
        let url = baseURL.appending(path: "api/tags")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalAIError.invalidResponse
        }
        return try JSONDecoder().decode(OllamaTags.self, from: data).models.map(\.name).sorted()
    }

    func stream(_ request: LocalAIRequest, onDelta: @Sendable @escaping (String) async -> Void) async throws {
        var http = URLRequest(url: baseURL.appending(path: "api/chat"))
        http.httpMethod = "POST"
        http.timeoutInterval = request.idleTimeout
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try JSONEncoder().encode(OllamaChatRequest(
            model: model,
            messages: request.messages,
            stream: true,
            options: OllamaOptions(temperature: request.temperature, numCtx: request.contextTokens)
        ))

        let (bytes, response) = try await session.bytes(for: http)
        try await LocalAIWire.check(response, bytes: bytes)

        var filter = ReasoningFilter()
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(OllamaChatChunk.self, from: data) else { continue }
            if let error = chunk.error { throw LocalAIError.server(error) }
            // `thinking` is deliberately not read. It is the model's scratchpad, and
            // the owner asked a question, not to watch one being thought about.
            let visible = filter.consume(chunk.message?.content ?? "")
            if !visible.isEmpty { await onDelta(visible) }
            if chunk.done == true { break }
        }
        let tail = filter.flush()
        if !tail.isEmpty { await onDelta(tail) }
    }
}

// MARK: - OpenAI-compatible

struct OpenAICompatibleLocalClient: LocalAIClient {
    let baseURL: URL
    let model: String
    var session: URLSession = .shared

    func discoverModels() async throws -> [String] {
        let (data, response) = try await session.data(from: endpoint("models"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalAIError.invalidResponse
        }
        return try JSONDecoder().decode(OpenAIModels.self, from: data).data.map(\.id).sorted()
    }

    func stream(_ request: LocalAIRequest, onDelta: @Sendable @escaping (String) async -> Void) async throws {
        var http = URLRequest(url: endpoint("chat/completions"))
        http.httpMethod = "POST"
        http.timeoutInterval = request.idleTimeout
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // `contextTokens` is not sent: this protocol has no field for it. The window
        // is whatever the server loaded the model with, which is why the interface
        // states the transcript's size rather than pretending to control it.
        http.httpBody = try JSONEncoder().encode(OpenAIChatRequest(
            model: model,
            messages: request.messages,
            temperature: request.temperature,
            stream: true
        ))

        let (bytes, response) = try await session.bytes(for: http)
        try await LocalAIWire.check(response, bytes: bytes)

        var filter = ReasoningFilter()
        for try await line in bytes.lines {
            // Comments (`: ping`) and the blank lines between events carry nothing.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OpenAIChatChunk.self, from: data) else { continue }
            let visible = filter.consume(chunk.choices.first?.delta.content ?? "")
            if !visible.isEmpty { await onDelta(visible) }
        }
        let tail = filter.flush()
        if !tail.isEmpty { await onDelta(tail) }
    }

    private func endpoint(_ path: String) -> URL {
        let normalized = baseURL.path.hasSuffix("/v1") ? baseURL : baseURL.appending(path: "v1")
        return normalized.appending(path: path)
    }
}

// MARK: - Shared wire handling

/// Response checking shared by both dialects.
///
/// A local model server refuses for reasons the owner can act on — the model is not
/// pulled, the name is misspelled, the context asked for does not fit in memory —
/// and every one of those arrives as a status code with an explanation in the body.
/// Throwing "invalid response" would discard exactly the part worth reading.
enum LocalAIWire {
    static func check(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw LocalAIError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        throw LocalAIError.server(message(from: await body(of: bytes), status: http.statusCode))
    }

    /// The body of a refusal is short. Reading it under a cap keeps a server that
    /// answers an error with a stream from being read forever, and a read that
    /// fails part-way still yields whatever explanation had arrived.
    private static func body(of bytes: URLSession.AsyncBytes, limit: Int = 800) async -> String {
        var collected = ""
        do {
            for try await line in bytes.lines {
                collected += line
                if collected.count >= limit { break }
            }
        } catch {}
        return collected
    }

    static func message(from body: String, status: Int) -> String {
        if let data = body.data(using: .utf8) {
            if let flat = try? JSONDecoder().decode(FlatError.self, from: data) {
                return flat.error
            }
            if let nested = try? JSONDecoder().decode(NestedError.self, from: data) {
                return nested.error.message
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The local model server returned \(status)." : trimmed
    }

    private struct FlatError: Decodable { let error: String }
    private struct NestedError: Decodable {
        struct Payload: Decodable { let message: String }
        let error: Payload
    }
}

enum LocalAIError: LocalizedError, Equatable {
    case invalidEndpoint
    case nonLocalEndpoint
    case modelNotSelected
    case invalidResponse
    case invalidSummaryResponse
    case rewriteDivergedFromSpeech
    case timedOut
    case emptyAnswer
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid HTTP or HTTPS local model endpoint."
        case .nonLocalEndpoint: "Only loopback model servers are allowed unless LAN access is enabled."
        case .modelNotSelected: "Select a local language model first."
        case .invalidResponse: "The local model server returned an invalid response."
        case .invalidSummaryResponse: "The local model did not return a usable title and summary. Try again."
        case .rewriteDivergedFromSpeech: "The local model rewrote the dictation instead of tidying it."
        case .timedOut: "The local model did not answer in time."
        case .emptyAnswer: "The local model returned an empty answer."
        case .server(let message): message
        }
    }
}

// MARK: - Wire types

private struct OllamaTags: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

private struct OllamaOptions: Encodable {
    let temperature: Double
    let numCtx: Int?

    private enum CodingKeys: String, CodingKey {
        case temperature
        case numCtx = "num_ctx"
    }
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [LocalAIMessage]
    let stream: Bool
    let options: OllamaOptions
}

private struct OllamaChatChunk: Decodable {
    struct Message: Decodable { let content: String? }
    let message: Message?
    let done: Bool?
    let error: String?
}

private struct OpenAIModels: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [LocalAIMessage]
    let temperature: Double
    let stream: Bool
}

private struct OpenAIChatChunk: Decodable {
    struct Delta: Decodable { let content: String? }
    struct Choice: Decodable { let delta: Delta }
    let choices: [Choice]
}
