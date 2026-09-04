import Foundation
import Testing
@testable import MyWhispr

@Suite("Local AI response handling", .serialized)
struct LocalAIClientTests {
    @Test("Summary response carries a title and Markdown notes")
    func parsesGeneratedMeetingMetadata() throws {
        let response = """
        <title>Mobile app launch plan</title>
        <summary>
        ## Decisions
        - Ship the beta on Friday.
        </summary>
        """

        #expect(try MeetingSummary.parse(response) == MeetingSummary(
            title: "Mobile app launch plan",
            markdown: "## Decisions\n- Ship the beta on Friday."
        ))
    }

    @Test("Incomplete summary responses are rejected without partial data")
    func rejectsMalformedMeetingMetadata() {
        #expect(throws: LocalAIError.invalidSummaryResponse) {
            try MeetingSummary.parse("## Summary\n- A title is missing")
        }
        #expect(throws: LocalAIError.invalidSummaryResponse) {
            try MeetingSummary.parse("<title>Title</title><summary></summary>")
        }
    }

    @Test("Chosen summary language applies to both generated fields")
    func summaryPromptIncludesLanguage() throws {
        var configuration = LocalAIConfiguration()
        configuration.summaryLanguage = .ru
        configuration.summaryPrompt = "Focus on unresolved risks."
        let messages = LocalAIService.summaryMessages("Transcript", configuration: configuration)

        let instruction = try #require(messages.first?.content)
        #expect(instruction.contains("Focus on unresolved risks."))
        #expect(instruction.contains("Write both the title and the summary in Russian."))
        #expect(instruction.contains("Do not use LaTeX or dollar-delimited math."))
        #expect(instruction.contains("<title>"))
        #expect(instruction.contains("<summary>"))
    }

    @Test func ollamaDiscoversModels() async throws {
        let session = makeSession(status: 200, body: #"{"models":[{"name":"qwen3:4b"},{"name":"gemma3:4b"}]}"#)
        let client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "qwen3:4b",
            session: session
        )
        #expect(try await client.discoverModels() == ["gemma3:4b", "qwen3:4b"])
    }

    @Test func ollamaDoesNotOfferEmbeddingOnlyModelsForTextGeneration() async throws {
        let session = makeSession(
            status: 200,
            body: #"{"models":[{"name":"qwen3:4b","capabilities":["completion","tools"]},{"name":"qwen3-embedding:4b","capabilities":["embedding"]}]}"#
        )
        let client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "qwen3:4b",
            session: session
        )

        #expect(try await client.discoverModels() == ["qwen3:4b"])
        #expect(try await client.discoverEmbeddingModels() == ["qwen3-embedding:4b"])
    }

    @Test func ollamaGeneratesBatchEmbeddings() async throws {
        let session = makeSession(
            status: 200,
            body: #"{"model":"embed","embeddings":[[0.5,0.25],[0.1,0.9]]}"#
        )
        let client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "embed",
            session: session
        )

        #expect(try await client.embed(["one", "two"]) == [[0.5, 0.25], [0.1, 0.9]])
    }

    @Test func openAIGeneratesEmbeddingsInServerIndexOrder() async throws {
        let session = makeSession(
            status: 200,
            body: #"{"data":[{"index":1,"embedding":[0.1,0.9]},{"index":0,"embedding":[0.5,0.25]}]}"#
        )
        let client = OpenAICompatibleLocalClient(
            baseURL: URL(string: "http://localhost:1234")!,
            model: "embed",
            session: session
        )

        #expect(try await client.embed(["one", "two"]) == [[0.5, 0.25], [0.1, 0.9]])
    }

    @Test func openAICompatibleCompletes() async throws {
        let session = makeSession(
            status: 200,
            body: "data: " + #"{"choices":[{"delta":{"content":"Clean text."}}]}"# + "\n\ndata: [DONE]\n\n"
        )
        let client = OpenAICompatibleLocalClient(
            baseURL: URL(string: "http://localhost:1234")!,
            model: "local",
            session: session
        )
        let request = LocalAIRequest(messages: [.system("Clean"), .user("raw")], idleTimeout: 1)
        #expect(try await client.complete(request) == "Clean text.")
    }

    private func makeSession(status: Int, body: String) -> URLSession {
        URLStub.status = status
        URLStub.body = Data(body.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class URLStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
