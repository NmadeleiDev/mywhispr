import Foundation
import Testing
@testable import MyWhispr

@Suite("Meeting tag suggestions")
struct MeetingTagSuggestionTests {
    @Test func parseKeepsOnlyCatalogNamesCaseInsensitively() throws {
        let catalog = [
            TagRecord(id: UUID(), name: "Work", createdAt: Date()),
            TagRecord(id: UUID(), name: "Client", createdAt: Date()),
        ]
        let suggestion = try MeetingTagSuggestion.parse(
            """
            preamble the model should not keep
            <tags>
            work
            Invented
            Client
            work
            </tags>
            trailing noise
            """,
            catalog: catalog
        )
        #expect(suggestion.tagNames == ["Work", "Client"])
    }

    @Test func parseAcceptsEmptyTagList() throws {
        let catalog = [TagRecord(id: UUID(), name: "Work", createdAt: Date())]
        let suggestion = try MeetingTagSuggestion.parse("<tags>\n</tags>", catalog: catalog)
        #expect(suggestion.tagNames.isEmpty)
    }

    @Test func parseRejectsMissingEnvelope() {
        #expect(throws: LocalAIError.invalidTagSuggestionResponse) {
            try MeetingTagSuggestion.parse("Work\nClient", catalog: [
                TagRecord(id: UUID(), name: "Work", createdAt: Date()),
            ])
        }
    }

    @Test func promptIncludesCatalogExamplesAndClippedSummary() {
        let catalog = [
            TagRecord(id: UUID(), name: "darwin", createdAt: Date()),
            TagRecord(id: UUID(), name: "trading", createdAt: Date()),
        ]
        let examples = [
            TagCatalogExample(
                tag: catalog[0],
                summaries: [String(repeating: "a", count: 600)]
            ),
        ]
        let budget = MeetingTagSuggestionBudget(
            examplesPerTag: 1,
            maxExampleCharacters: 500,
            maxSummaryCharacters: 100
        )
        let messages = LocalAIService.tagSuggestionMessages(
            title: "Weekly sync",
            summary: String(repeating: "b", count: 250),
            catalog: catalog,
            examples: examples,
            budget: budget
        )

        let system = messages[0].content
        #expect(system.contains("- darwin"))
        #expect(system.contains("- trading"))
        #expect(system.contains(#"<tag name="darwin">"#))
        #expect(system.contains(String(repeating: "a", count: 500) + "…"))
        #expect(!system.contains(String(repeating: "a", count: 501)))

        let user = messages[1].content
        #expect(user.contains("<title>Weekly sync</title>"))
        #expect(user.contains(String(repeating: "b", count: 100) + "…"))
    }

    @Test func policySkipsTaggedMeetingsEmptyCatalogAndMissingNotes() {
        var configuration = LocalAIConfiguration()
        configuration.summaryModel = "local"
        let tag = TagRecord(id: UUID(), name: "Work", createdAt: Date())

        #expect(AutomaticMeetingTagPolicy.shouldSuggest(
            enabled: true,
            configuration: configuration,
            existingTags: [],
            catalog: [tag],
            summary: "Notes"
        ))
        #expect(!AutomaticMeetingTagPolicy.shouldSuggest(
            enabled: false,
            configuration: configuration,
            existingTags: [],
            catalog: [tag],
            summary: "Notes"
        ))
        #expect(!AutomaticMeetingTagPolicy.shouldSuggest(
            enabled: true,
            configuration: configuration,
            existingTags: [tag],
            catalog: [tag],
            summary: "Notes"
        ))
        #expect(!AutomaticMeetingTagPolicy.shouldSuggest(
            enabled: true,
            configuration: configuration,
            existingTags: [],
            catalog: [],
            summary: "Notes"
        ))
        #expect(!AutomaticMeetingTagPolicy.shouldSuggest(
            enabled: true,
            configuration: configuration,
            existingTags: [],
            catalog: [tag],
            summary: "   "
        ))
    }
}

@Suite("Tag suggestion persistence")
struct MeetingTagSuggestionDatabaseTests {
    @Test func eligibleMeetingsAndExamplesRespectTaggedCatalog() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(rootURL: root)
        let now = Date()

        func meeting(_ title: String, summary: String?) -> SessionRecord {
            SessionRecord(
                id: UUID(), kind: .meeting, title: title, state: .completed,
                startedAt: now, endedAt: now, duration: 30,
                sourceApplication: nil, sourceBundleIdentifier: nil,
                modelSnapshot: "{}", audioRelativePath: nil, summary: summary,
                errorMessage: nil, createdAt: now, updatedAt: now
            )
        }

        let tagged = meeting("Tagged", summary: "Already labelled notes about Work.")
        let eligible = meeting("Eligible", summary: "Needs labels from the catalog.")
        let noNotes = meeting("No notes", summary: nil)
        try database.insertSession(tagged)
        try database.insertSession(eligible)
        try database.insertSession(noNotes)
        _ = try database.addTag(named: "Work", to: tagged.id)

        let candidates = try database.meetingsEligibleForTagSuggestion()
        #expect(candidates.map(\.id) == [eligible.id])

        let examples = try database.tagCatalogExamples(
            examplesPerTag: 2,
            maxSummaryCharacters: 500,
            excludingSessionID: eligible.id
        )
        #expect(examples.map(\.tag.name) == ["Work"])
        #expect(examples[0].summaries == ["Already labelled notes about Work."])
    }
}
