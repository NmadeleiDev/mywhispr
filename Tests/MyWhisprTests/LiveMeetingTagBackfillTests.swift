import Foundation
import Testing
@testable import MyWhispr

/// Live Ollama pass over the owner's Application Support library.
///
/// Opt in with `MYWHISPR_LIVE_TAG_BACKFILL=1`. Optional `MYWHISPR_LIVE_TAG_LIMIT`
/// caps how many untagged meetings are processed (default 5).
@Suite("Live meeting tag backfill", .serialized)
struct LiveMeetingTagBackfillTests {
    @Test func assignsCatalogTagsToUntaggedSummarizedMeetings() async throws {
        guard ProcessInfo.processInfo.environment["MYWHISPR_LIVE_TAG_BACKFILL"] == "1" else {
            return
        }

        let limit = Int(ProcessInfo.processInfo.environment["MYWHISPR_LIVE_TAG_LIMIT"] ?? "5") ?? 5
        let useCompact = ProcessInfo.processInfo.environment["MYWHISPR_LIVE_TAG_COMPACT"] == "1"
        let budget: MeetingTagSuggestionBudget = useCompact ? .compact : .standard

        let configuration = try Self.loadConfigurationFromPreferences()
        #expect(!configuration.effectiveSummaryModel.isEmpty)

        let database = try AppDatabase()
        let catalog = try database.allTags()
        #expect(!catalog.isEmpty)

        let alreadyTagged = try database.recentSessions(kind: .meeting, limit: 500).filter { session in
            let tags = try database.tags(for: [session.id])[session.id] ?? []
            return !tags.isEmpty
        }
        let taggedBefore = Set(alreadyTagged.map(\.id))

        let candidates = try database.meetingsEligibleForTagSuggestion(limit: limit)
        #expect(!candidates.isEmpty)

        let service = LocalAIService()
        var assigned: [(String, [String])] = []
        var empty = 0
        var failed = 0

        for session in candidates {
            let detail = try #require(try database.sessionDetail(id: session.id))
            #expect(detail.tags.isEmpty)
            let examples = try database.tagCatalogExamples(
                examplesPerTag: budget.examplesPerTag,
                maxSummaryCharacters: budget.maxExampleCharacters,
                excludingSessionID: session.id
            )
            do {
                let suggestion = try await service.suggestTags(
                    title: detail.session.title,
                    summary: detail.session.summary ?? "",
                    catalog: catalog,
                    examples: examples,
                    configuration: configuration,
                    budget: budget
                )
                if suggestion.tagNames.isEmpty {
                    empty += 1
                    print("BACKFILL empty: \(detail.session.title)")
                    continue
                }
                for name in suggestion.tagNames {
                    _ = try database.addTag(named: name, to: session.id)
                }
                assigned.append((detail.session.title, suggestion.tagNames))
                print("BACKFILL tagged: \(detail.session.title) -> \(suggestion.tagNames.joined(separator: ", "))")
            } catch {
                failed += 1
                print("BACKFILL failed: \(detail.session.title): \(error.localizedDescription)")
            }
        }

        for id in taggedBefore {
            let tags = try database.tags(for: [id])[id] ?? []
            #expect(!tags.isEmpty)
        }

        print(
            "BACKFILL done budget=\(useCompact ? "compact" : "standard") "
                + "assigned=\(assigned.count) empty=\(empty) failed=\(failed)"
        )
        #expect(failed == 0)
        #expect(assigned.count + empty == candidates.count)
    }

    private static func loadConfigurationFromPreferences() throws -> LocalAIConfiguration {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/app.mywhispr.mac.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let payloadData = plist?["settings.payload.v2"] as? Data else {
            throw LocalAIError.modelNotSelected
        }
        let payload = try JSONDecoder().decode(SettingsStore.Payload.self, from: payloadData)
        return payload.localAI
    }
}
