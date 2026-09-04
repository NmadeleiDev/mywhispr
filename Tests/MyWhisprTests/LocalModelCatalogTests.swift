import Testing
@testable import MyWhispr

@Suite("Local model catalog")
struct LocalModelCatalogTests {
    @Test("Only a successful catalog can prove a model is missing")
    func absenceRequiresAnAuthoritativeResult() {
        let source = makeSource()
        var catalog = LocalModelCatalog()

        #expect(!catalog.confirmsMissing("gemma", from: source))
        let request = catalog.begin(source: source)
        #expect(!catalog.confirmsMissing("gemma", from: source))
        let received = catalog.receive(["qwen"], for: request)
        #expect(received)
        #expect(catalog.confirmsMissing("gemma", from: source))
        #expect(!catalog.confirmsMissing("qwen", from: source))
    }

    @Test("A stale response cannot replace the current connection's catalog")
    func staleResultsAreRejected() {
        let firstSource = makeSource(baseURL: "http://127.0.0.1:11434")
        let secondSource = makeSource(baseURL: "http://127.0.0.1:1234")
        var catalog = LocalModelCatalog()
        let firstRequest = catalog.begin(source: firstSource)
        let secondRequest = catalog.begin(source: secondSource)

        let receivedStale = catalog.receive(["stale"], for: firstRequest)
        let receivedCurrent = catalog.receive(["current"], for: secondRequest)
        #expect(!receivedStale)
        #expect(receivedCurrent)
        #expect(catalog.models(for: secondSource) == ["current"])
        #expect(catalog.models(for: firstSource).isEmpty)
    }

    @Test("Changing connection invalidates a result before the next request begins")
    func sourceChangeClosesTheDebounceWindow() {
        let firstSource = makeSource(baseURL: "http://127.0.0.1:11434")
        let secondSource = makeSource(baseURL: "http://127.0.0.1:1234")
        var catalog = LocalModelCatalog()
        let firstRequest = catalog.begin(source: firstSource)

        catalog.invalidate(for: secondSource)
        let receivedOldResult = catalog.receive(["ollama-model"], for: firstRequest)

        #expect(!receivedOldResult)
        #expect(catalog.state(for: secondSource) == .notLoaded)
        #expect(catalog.models(for: secondSource).isEmpty)
    }

    @Test("A connection failure never claims that a saved model is missing")
    func failuresAreNotAbsenceEvidence() {
        let source = makeSource()
        var catalog = LocalModelCatalog()
        let request = catalog.begin(source: source)
        let failed = catalog.fail("Connection refused", for: request)

        #expect(failed)
        #expect(catalog.state(for: source) == .failed("Connection refused"))
        #expect(!catalog.confirmsMissing("gemma", from: source))
    }

    @Test("LAN policy is part of catalog authority")
    func lanPolicyChangesInvalidateTheSnapshot() {
        let localOnly = makeSource(allowLAN: false)
        let lanAllowed = makeSource(allowLAN: true)
        var catalog = LocalModelCatalog()
        let request = catalog.begin(source: localOnly)
        let received = catalog.receive(["gemma"], for: request)
        #expect(received)

        #expect(catalog.models(for: localOnly) == ["gemma"])
        #expect(catalog.state(for: lanAllowed) == .notLoaded)
        #expect(!catalog.confirmsMissing("qwen", from: lanAllowed))
    }

    private func makeSource(
        baseURL: String = "http://127.0.0.1:11434",
        allowLAN: Bool = false
    ) -> LocalModelSource {
        var configuration = LocalAIConfiguration()
        configuration.baseURL = baseURL
        configuration.allowLAN = allowLAN
        return LocalModelSource(configuration: configuration)
    }
}
