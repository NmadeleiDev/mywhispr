import Foundation

/// How much example evidence to show the model when suggesting tags.
struct MeetingTagSuggestionBudget: Equatable, Sendable {
    /// Recent tagged meetings shown for each catalog entry.
    var examplesPerTag: Int
    /// Truncation for each example summary in the prompt.
    var maxExampleCharacters: Int
    /// Truncation for the meeting being tagged.
    var maxSummaryCharacters: Int

    static let standard = MeetingTagSuggestionBudget(
        examplesPerTag: 2,
        maxExampleCharacters: 500,
        maxSummaryCharacters: 4_000
    )

    static let compact = MeetingTagSuggestionBudget(
        examplesPerTag: 1,
        maxExampleCharacters: 500,
        maxSummaryCharacters: 2_000
    )
}

/// One catalog tag plus short summaries of meetings already labelled with it.
struct TagCatalogExample: Equatable, Sendable {
    var tag: TagRecord
    var summaries: [String]
}

/// Names the local model returned for a meeting, already restricted to the catalog.
struct MeetingTagSuggestion: Equatable, Sendable {
    var tagNames: [String]

    /// Parses `<tags>…</tags>` and keeps only names that exist in the catalog
    /// (case-insensitive). Invented names are dropped rather than created.
    static func parse(_ response: String, catalog: [TagRecord]) throws -> MeetingTagSuggestion {
        guard let start = response.range(of: "<tags>"),
              let end = response.range(of: "</tags>", range: start.upperBound..<response.endIndex) else {
            throw LocalAIError.invalidTagSuggestionResponse
        }

        let body = response[start.upperBound..<end.lowerBound]
        let rawNames = body
            .split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let byLower = Dictionary(uniqueKeysWithValues: catalog.map {
            ($0.name.lowercased(), $0.name)
        })
        var seen = Set<String>()
        var resolved: [String] = []
        for raw in rawNames {
            let key = raw.lowercased()
            guard let canonical = byLower[key], seen.insert(key).inserted else { continue }
            resolved.append(canonical)
        }
        return MeetingTagSuggestion(tagNames: resolved)
    }
}

enum AutomaticMeetingTagPolicy {
    static func shouldSuggest(
        enabled: Bool,
        configuration: LocalAIConfiguration,
        existingTags: [TagRecord],
        catalog: [TagRecord],
        summary: String?
    ) -> Bool {
        let model = configuration.effectiveSummaryModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return enabled
            && !model.isEmpty
            && existingTags.isEmpty
            && !catalog.isEmpty
            && !notes.isEmpty
    }
}

extension LocalAIService {
    /// Picks zero or more existing tags for a meeting from its summary and
    /// examples of how those tags have been used on other meetings.
    func suggestTags(
        title: String,
        summary: String,
        catalog: [TagRecord],
        examples: [TagCatalogExample],
        configuration: LocalAIConfiguration,
        budget: MeetingTagSuggestionBudget = .standard
    ) async throws -> MeetingTagSuggestion {
        let model = configuration.effectiveSummaryModel
        guard !model.isEmpty else { throw LocalAIError.modelNotSelected }
        guard !catalog.isEmpty else { return MeetingTagSuggestion(tagNames: []) }
        try Self.validate(configuration: configuration)

        let messages = Self.tagSuggestionMessages(
            title: title,
            summary: summary,
            catalog: catalog,
            examples: examples,
            budget: budget
        )
        let request = LocalAIRequest(
            messages: messages,
            idleTimeout: 180,
            temperature: 0.1,
            contextTokens: TokenBudget.context(for: messages, limit: configuration.maxContextTokens)
        )
        let answer = try await client(configuration: configuration, model: model).complete(request)
        return try MeetingTagSuggestion.parse(answer, catalog: catalog)
    }

    static func tagSuggestionMessages(
        title: String,
        summary: String,
        catalog: [TagRecord],
        examples: [TagCatalogExample],
        budget: MeetingTagSuggestionBudget
    ) -> [LocalAIMessage] {
        let catalogLines = catalog
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { "- \($0)" }
            .joined(separator: "\n")

        var exampleBlocks: [String] = []
        for example in examples where !example.summaries.isEmpty {
            let bodies = example.summaries.map { summary in
                let clipped = Self.clip(summary, limit: budget.maxExampleCharacters)
                return "<example>\n\(clipped)\n</example>"
            }.joined(separator: "\n")
            exampleBlocks.append(
                """
                <tag name="\(example.tag.name)">
                \(bodies)
                </tag>
                """
            )
        }
        let examplesSection = exampleBlocks.isEmpty
            ? "(No tagged meetings yet — choose only when the summary clearly matches a catalog name.)"
            : exampleBlocks.joined(separator: "\n\n")

        let clippedSummary = Self.clip(summary, limit: budget.maxSummaryCharacters)
        let clippedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        return [
            .system("""
            You assign library tags to a meeting. Choose only from the catalog \
            below. Do not invent tags, rename tags, or translate tag names. Prefer \
            precision over coverage: if nothing fits, return an empty list. A \
            meeting may receive multiple tags when several clearly apply.

            Catalog:
            \(catalogLines)

            Examples of meetings already labelled with each tag:
            \(examplesSection)

            Return exactly this envelope, with no text outside it:
            <tags>
            exact-catalog-name
            </tags>

            Put one catalog name per line inside the tags element. Leave the \
            element empty when no catalog tag fits.
            """),
            .user("""
            <meeting>
            <title>\(clippedTitle)</title>
            <summary>
            \(clippedSummary)
            </summary>
            </meeting>
            """),
        ]
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
