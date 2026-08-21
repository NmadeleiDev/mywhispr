import Foundation
import Testing
@testable import MyWhispr

@Suite("Local AI response handling", .serialized)
struct LocalAIClientTests {
    @Test func ollamaDiscoversModels() async throws {
        let session = makeSession(status: 200, body: #"{"models":[{"name":"qwen3:4b"},{"name":"gemma3:4b"}]}"#)
        let client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "qwen3:4b",
            session: session
        )
        #expect(try await client.discoverModels() == ["gemma3:4b", "qwen3:4b"])
    }

    @Test func openAICompatibleCompletes() async throws {
        let session = makeSession(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"Clean text."}}]}"#)
        let client = OpenAICompatibleLocalClient(
            baseURL: URL(string: "http://localhost:1234")!,
            model: "local",
            session: session
        )
        #expect(try await client.complete(systemPrompt: "Clean", text: "raw", timeout: 1) == "Clean text.")
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
