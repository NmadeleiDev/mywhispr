import CryptoKit
import Foundation

/// Builds stable evidence units from transcript segments.
///
/// The database indexes these passages, not arbitrary character slices, so source
/// timestamps and speaker turns survive retrieval. One-turn overlap keeps a thought
/// that crosses a boundary readable without making every passage a second transcript.
enum MeetingPassageBuilder {
    static let targetCharacters = 1_400

    struct Passage: Equatable, Sendable {
        var position: Int
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var speakers: String
    }

    static func build(from segments: [TranscriptSegmentRecord]) -> [Passage] {
        let spoken = segments.filter {
            !$0.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !spoken.isEmpty else { return [] }

        var result: [Passage] = []
        var current: [TranscriptSegmentRecord] = []

        for segment in spoken {
            let proposed = rendered(current + [segment]).count
            if !current.isEmpty, proposed > targetCharacters {
                result.append(passage(current, position: result.count))
                current = current.last.map { [$0] } ?? []
            }
            if current.last?.id != segment.id { current.append(segment) }
        }
        if !current.isEmpty { result.append(passage(current, position: result.count)) }
        return result
    }

    private static func passage(_ segments: [TranscriptSegmentRecord], position: Int) -> Passage {
        Passage(
            position: position,
            start: segments.first?.start ?? 0,
            end: segments.last?.end ?? 0,
            text: rendered(segments),
            speakers: Set(segments.map(\.speaker)).sorted().joined(separator: " ")
        )
    }

    private static func rendered(_ segments: [TranscriptSegmentRecord]) -> String {
        segments.map {
            "[\(Clock.string($0.start))] \($0.speaker): \($0.editedText.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")
    }
}

struct MeetingQueryPlan: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case topical
        case exhaustive
        case comparison
    }

    var originalQuestion: String
    var standaloneQuestion: String
    var searchText: String
    var mode: Mode
    var timeRange: DateInterval?

    var requiresCompleteCoverage: Bool { mode != .topical }
}

/// Turns conversation language and wall-clock language into constraints the
/// database can enforce before retrieval. This remains deterministic: dates and
/// corpus coverage must not depend on whether a model follows a planning prompt.
enum MeetingQueryPlanner {
    private static let followUpOpeners = [
        "and ", "what about", "how about", "who else", "when was that",
        "а ", "а что", "что насчет", "кто еще", "когда это",
    ]
    private static let exhaustiveMarkers = [
        "all ", "every ", "each ", "list ", "across ", "everything",
        "which meetings", "what meetings", "все ", "всё ", "кажд", "перечисл",
        "список", "за весь", "какие встречи", "сколько встреч",
    ]
    private static let comparisonMarkers = [
        "compare", "difference", "changed between", "versus", " vs ",
        "сравн", "разниц", "изменилось между", "против",
    ]

    static func plan(
        question: String,
        history: [ChatMessageRecord],
        context: MeetingChatRequestContext
    ) -> MeetingQueryPlan {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let previous = history.last(where: { $0.role == .user })?.content
        let needsContext = followUpOpeners.contains(where: lower.hasPrefix)
            || MeetingCorpusSearch.terms(in: trimmed).count < 2
        let standalone = needsContext && previous != nil
            ? "\(previous!) \(trimmed)"
            : trimmed
        var mode: MeetingQueryPlan.Mode
        if comparisonMarkers.contains(where: lower.contains) {
            mode = .comparison
        } else if exhaustiveMarkers.contains(where: lower.contains) {
            mode = .exhaustive
        } else {
            mode = .topical
        }
        let range = timeRange(in: lower, context: context)
        let searchText = MeetingCorpusSearch.contentText(from: standalone)
        if mode == .topical, range != nil, searchText.isEmpty { mode = .exhaustive }
        return MeetingQueryPlan(
            originalQuestion: trimmed,
            standaloneQuestion: standalone,
            searchText: searchText,
            mode: mode,
            timeRange: range
        )
    }

    private static func timeRange(
        in question: String,
        context: MeetingChatRequestContext
    ) -> DateInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        let today = calendar.startOfDay(for: context.now)

        func day(_ offset: Int) -> DateInterval? {
            guard let start = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        if question.contains("yesterday") || question.contains("вчера") { return day(-1) }
        if question.contains("today") || question.contains("сегодня") { return day(0) }

        if question.contains("last week") || question.contains("прошлую неделю")
            || question.contains("прошлой неделе") {
            guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: context.now),
                  let start = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start) else { return nil }
            return DateInterval(start: start, end: thisWeek.start)
        }
        if question.contains("this week") || question.contains("на этой неделе") {
            return calendar.dateInterval(of: .weekOfYear, for: context.now)
        }
        if question.contains("last month") || question.contains("прошлый месяц")
            || question.contains("прошлом месяце") {
            guard let thisMonth = calendar.dateInterval(of: .month, for: context.now),
                  let start = calendar.date(byAdding: .month, value: -1, to: thisMonth.start) else { return nil }
            return DateInterval(start: start, end: thisMonth.start)
        }
        if question.contains("this month") || question.contains("в этом месяце") {
            return calendar.dateInterval(of: .month, for: context.now)
        }
        if question.contains("this quarter") || question.contains("в этом квартале") {
            let components = calendar.dateComponents([.year, .month], from: context.now)
            guard let year = components.year, let month = components.month else { return nil }
            let quarterMonth = ((month - 1) / 3) * 3 + 1
            guard let start = calendar.date(from: DateComponents(year: year, month: quarterMonth, day: 1)),
                  let end = calendar.date(byAdding: .month, value: 3, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }

        let matches = question.matches(of: /\b(20\d\d)-(\d\d)-(\d\d)\b/)
        guard let first = matches.first,
              let year = Int(first.1), let month = Int(first.2), let dayValue = Int(first.3),
              let start = calendar.date(from: DateComponents(year: year, month: month, day: dayValue)) else {
            return nil
        }
        let last = matches.last ?? first
        guard let lastYear = Int(last.1), let lastMonth = Int(last.2), let lastDay = Int(last.3),
              let finalDay = calendar.date(from: DateComponents(year: lastYear, month: lastMonth, day: lastDay)),
              let end = calendar.date(byAdding: .day, value: 1, to: finalDay), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
}

struct MeetingRetrievalResult: Equatable, Sendable {
    var evidence: [MeetingEvidence]
    var eligibleMeetingCount: Int
    var completeCoverage: Bool
}

enum MeetingCorpusError: LocalizedError, Equatable {
    case exhaustiveScopeTooLarge(meetings: Int)

    var errorDescription: String? {
        switch self {
        case .exhaustiveScopeTooLarge(let meetings):
            "This question requires reading all \(meetings) matching meetings, but their transcripts do not fit in the configured context. Narrow the date range or raise the context limit."
        }
    }
}

/// The only path by which the all-meetings conversation can receive recordings.
/// Sparse and semantic rankers end here; the prompt only receives typed evidence.
struct MeetingCorpus: Sendable {
    let database: AppDatabase

    func retrieve(
        question: String,
        history: [ChatMessageRecord],
        tokenLimit: Int
    ) throws -> [MeetingEvidence] {
        let context = MeetingChatRequestContext(now: Date(), timeZone: .current)
        let plan = MeetingQueryPlanner.plan(question: question, history: history, context: context)
        return try retrieve(plan: plan, densePassageIDs: [], tokenLimit: tokenLimit).evidence
    }

    func retrieve(
        plan: MeetingQueryPlan,
        densePassageIDs: [String],
        tokenLimit: Int
    ) throws -> MeetingRetrievalResult {
        let allEligible = try database.meetingPassages(within: plan.timeRange)
        let eligibleMeetingCount = Set(allEligible.map(\.sessionID)).count
        let evidenceBudget = max(1_024, tokenLimit - TokenBudget.answerReserve - 1_024)

        if plan.requiresCompleteCoverage {
            let cost = allEligible.reduce(0) { $0 + TokenBudget.estimate($1.text) + 32 }
            guard cost <= evidenceBudget else {
                throw MeetingCorpusError.exhaustiveScopeTooLarge(meetings: eligibleMeetingCount)
            }
            return MeetingRetrievalResult(
                evidence: grouped(allEligible),
                eligibleMeetingCount: eligibleMeetingCount,
                completeCoverage: true
            )
        }

        let lexical = plan.searchText.isEmpty ? [] : try database.meetingPassageEvidence(
            matching: plan.searchText,
            within: plan.timeRange,
            limit: 40
        )
        let metadataMeetingIDs = plan.searchText.isEmpty ? [] : try database.meetingIDsMatchingMetadata(
            plan.searchText,
            within: plan.timeRange
        )
        if metadataMeetingIDs.count == 1 {
            let meetingPassages = allEligible.filter { $0.sessionID == metadataMeetingIDs[0] }
            let cost = meetingPassages.reduce(0) { $0 + TokenBudget.estimate($1.text) + 32 }
            if !meetingPassages.isEmpty, cost <= evidenceBudget {
                return MeetingRetrievalResult(
                    evidence: grouped(meetingPassages),
                    eligibleMeetingCount: eligibleMeetingCount,
                    completeCoverage: false
                )
            }
        }
        let dense = try database.meetingPassages(ids: densePassageIDs)
        let eligibleIDs = Set(allEligible.map(\.id))
        let lexicalEligible = lexical.filter { eligibleIDs.contains($0.id) }
        let denseEligible = dense.filter { eligibleIDs.contains($0.id) }
        let metadataRank = Dictionary(uniqueKeysWithValues: metadataMeetingIDs.enumerated().map { ($1, $0) })
        let metadataPassages = allEligible.filter { metadataRank[$0.sessionID] != nil }.sorted {
            let left = metadataRank[$0.sessionID, default: .max]
            let right = metadataRank[$1.sessionID, default: .max]
            return left == right ? $0.start < $1.start : left < right
        }
        let ranked = fused(lanes: [lexicalEligible, denseEligible, metadataPassages])
        let expanded = neighbors(of: ranked, within: allEligible)
        let kept = admitted(expanded, budget: evidenceBudget)
        return MeetingRetrievalResult(
            evidence: grouped(kept),
            eligibleMeetingCount: eligibleMeetingCount,
            completeCoverage: false
        )
    }

    private func fused(lanes: [[MeetingPassageEvidence]]) -> [MeetingPassageEvidence] {
        var scores: [String: Double] = [:]
        var values: [String: MeetingPassageEvidence] = [:]
        for lane in lanes {
            for (rank, passage) in lane.enumerated() {
                scores[passage.id, default: 0] += 1 / Double(60 + rank + 1)
                values[passage.id] = passage
            }
        }
        return scores.keys.sorted {
            let left = scores[$0, default: 0]
            let right = scores[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        }.compactMap { values[$0] }
    }

    private func neighbors(
        of ranked: [MeetingPassageEvidence],
        within all: [MeetingPassageEvidence]
    ) -> [MeetingPassageEvidence] {
        let byMeeting = Dictionary(grouping: all, by: \.sessionID)
        var seen: Set<String> = []
        var result: [MeetingPassageEvidence] = []
        for passage in ranked {
            guard seen.insert(passage.id).inserted else { continue }
            result.append(passage)
            guard let meeting = byMeeting[passage.sessionID],
                  let index = meeting.firstIndex(where: { $0.id == passage.id }) else { continue }
            for neighbor in [index - 1, index + 1] where meeting.indices.contains(neighbor) {
                let candidate = meeting[neighbor]
                if seen.insert(candidate.id).inserted { result.append(candidate) }
            }
        }
        return result
    }

    private func admitted(
        _ candidates: [MeetingPassageEvidence],
        budget: Int
    ) -> [MeetingPassageEvidence] {
        var used = 0
        var kept: [MeetingPassageEvidence] = []
        var perMeeting: [UUID: Int] = [:]
        for candidate in candidates {
            guard perMeeting[candidate.sessionID, default: 0] < 3 else { continue }
            let cost = TokenBudget.estimate(candidate.text) + 32
            guard cost <= budget, used + cost <= budget else { continue }
            kept.append(candidate)
            used += cost
            perMeeting[candidate.sessionID, default: 0] += 1
            if kept.count == 12 { break }
        }
        return kept
    }

    private func grouped(_ passages: [MeetingPassageEvidence]) -> [MeetingEvidence] {
        var meetings: [MeetingEvidence] = []
        var indexBySessionID: [UUID: Int] = [:]
        for passage in passages {
            if let index = indexBySessionID[passage.sessionID] {
                meetings[index].passages.append(passage)
            } else {
                indexBySessionID[passage.sessionID] = meetings.count
                meetings.append(MeetingEvidence(
                    sessionID: passage.sessionID,
                    title: passage.title,
                    startedAt: passage.startedAt,
                    summary: passage.summary,
                    passages: [passage]
                ))
            }
        }
        return meetings
    }
}

struct MeetingStoredEmbedding: Equatable, Sendable {
    var passageID: String
    var sessionID: UUID
    var model: String
    var textHash: String
    var dimensions: Int
    var vector: Data
}

struct MeetingSemanticSearchResult: Equatable, Sendable {
    var passageIDs: [String]
    var indexedPassages: Int
    var eligiblePassages: Int
}

struct MeetingSemanticIndex: Sendable {
    let database: AppDatabase
    let service: LocalAIService

    func backfill(
        model: String,
        configuration: LocalAIConfiguration,
        onProgress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws {
        guard !model.isEmpty else { return }
        let modelIdentity = try await service.embeddingModelIdentity(
            model: model,
            configuration: configuration
        )
        let passages = try database.meetingPassages()
        var stored = Dictionary(
            uniqueKeysWithValues: try database.meetingEmbeddingRows(model: modelIdentity)
                .map { ($0.passageID, $0) }
        )
        let missing = passages.filter { passage in
            stored[passage.id]?.textHash != Self.textHash(passage.text)
        }
        await onProgress(passages.count - missing.count, passages.count)
        var completed = passages.count - missing.count
        for batch in missing.chunked(into: 32) {
            try Task.checkCancellation()
            let vectors = try await service.embed(
                batch.map(\.text),
                model: model,
                configuration: configuration
            )
            let rows = zip(batch, vectors).map { passage, vector in
                MeetingStoredEmbedding(
                    passageID: passage.id,
                    sessionID: passage.sessionID,
                    model: modelIdentity,
                    textHash: Self.textHash(passage.text),
                    dimensions: vector.count,
                    vector: Self.data(vector)
                )
            }
            try database.storeMeetingEmbeddings(rows)
            for row in rows { stored[row.passageID] = row }
            completed += rows.count
            await onProgress(completed, passages.count)
        }
    }

    func rankedPassageIDs(
        for plan: MeetingQueryPlan,
        model: String,
        configuration: LocalAIConfiguration
    ) async throws -> MeetingSemanticSearchResult {
        guard !model.isEmpty, !plan.standaloneQuestion.isEmpty else {
            return MeetingSemanticSearchResult(passageIDs: [], indexedPassages: 0, eligiblePassages: 0)
        }
        let modelIdentity = try await service.embeddingModelIdentity(
            model: model,
            configuration: configuration
        )
        let passages = try database.meetingPassages(within: plan.timeRange)
        let stored = Dictionary(
            uniqueKeysWithValues: try database.meetingEmbeddingRows(
                model: modelIdentity,
                within: plan.timeRange
            ).map { ($0.passageID, $0) }
        )
        let current = passages.filter { stored[$0.id]?.textHash == Self.textHash($0.text) }
        guard !current.isEmpty else {
            return MeetingSemanticSearchResult(
                passageIDs: [],
                indexedPassages: 0,
                eligiblePassages: passages.count
            )
        }
        let query = try await service.embed(
            [plan.standaloneQuestion],
            model: model,
            configuration: configuration
        )[0]
        let ids = current.compactMap { passage -> (String, Double)? in
            guard let row = stored[passage.id],
                  row.dimensions == query.count,
                  let vector = Self.vector(row.vector), vector.count == query.count else { return nil }
            return (passage.id, Self.cosine(query, vector))
        }.sorted { $0.1 > $1.1 }
            .prefix(40)
            .map(\.0)
        return MeetingSemanticSearchResult(
            passageIDs: ids,
            indexedPassages: current.count,
            eligiblePassages: passages.count
        )
    }

    static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    static func vector(_ data: Data) -> [Float]? {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else { return nil }
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: data.count, by: MemoryLayout<Float>.size).map {
                bytes.loadUnaligned(fromByteOffset: $0, as: Float.self)
            }
        }
    }

    private static func cosine(_ left: [Float], _ right: [Float]) -> Double {
        var dot = 0.0
        var leftNorm = 0.0
        var rightNorm = 0.0
        for index in left.indices {
            let l = Double(left[index])
            let r = Double(right[index])
            dot += l * r
            leftNorm += l * l
            rightNorm += r * r
        }
        guard leftNorm > 0, rightNorm > 0 else { return -.infinity }
        return dot / (leftNorm.squareRoot() * rightNorm.squareRoot())
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

enum MeetingCorpusSearch {
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "did", "do",
        "does", "for", "from", "had", "has", "have", "how", "i", "in", "is",
        "it", "me", "my", "of", "on", "or", "our", "that", "the", "their",
        "them", "there", "they", "this", "to", "was", "we", "were", "what",
        "when", "where", "which", "who", "why", "with", "you", "meeting",
        "meetings", "about", "today", "yesterday", "week", "month", "quarter",
        "все", "всё", "что", "где", "когда", "кто", "как", "про", "об", "о",
        "на", "за", "это", "эта", "этот", "эти", "сегодня", "вчера", "неделе",
        "неделю", "месяце", "месяц", "квартале", "встреча", "встречи", "встречах",
        "были", "был", "была", "какие", "какая", "какой"
    ]

    static func terms(in text: String, limit: Int = 16) -> [String] {
        var seen: Set<String> = []
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .filter { seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }

    static func ftsPattern(for text: String) -> String? {
        let terms = terms(in: text)
        guard !terms.isEmpty else { return nil }
        return terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    static func contentText(from text: String) -> String {
        terms(in: text)
            .filter { !$0.hasPrefix("сегодня") && !$0.hasPrefix("вчераш") }
            .joined(separator: " ")
    }
}
