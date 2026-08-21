import Foundation
import Testing
@testable import MyWhispr

@Suite("Search behaviour", .serialized)
struct SearchTests {
    private func makeDatabase() throws -> (AppDatabase, URL) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (try AppDatabase(rootURL: root), root)
    }

    private func insert(
        _ database: AppDatabase,
        kind: WorkflowKind,
        title: String,
        body: String
    ) throws -> UUID {
        let now = Date()
        let session = SessionRecord(
            id: UUID(), kind: kind, title: title, state: .completed,
            startedAt: now, endedAt: now, duration: 3,
            sourceApplication: nil, sourceBundleIdentifier: nil,
            modelSnapshot: "{}", audioRelativePath: nil, summary: nil,
            errorMessage: nil, createdAt: now, updatedAt: now
        )
        try database.insertSession(session)
        try database.replaceSegments([TranscriptSegmentRecord(
            id: UUID(), sessionID: session.id, position: 0, start: 0, end: 3,
            channel: .microphone, speaker: "You", originalText: body, editedText: body
        )], for: session)
        return session.id
    }

    @Test func punctuationDoesNotBreakTheQuery() throws {
        let (database, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try insert(database, kind: .dictation, title: "Note", body: "Rewrite it in C++ today")

        // Bare `C++` is FTS5 syntax. Quoting each term is what keeps this a search
        // instead of a parse error thrown in the owner's face.
        #expect(try database.search("C++").count == 1)
        #expect(try database.search("don't").isEmpty)
    }

    @Test func searchStaysWithinTheChosenWorkflow() throws {
        let (database, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let dictation = try insert(database, kind: .dictation, title: "A", body: "shared keyword here")
        let meeting = try insert(database, kind: .meeting, title: "B", body: "shared keyword here")

        #expect(try database.search("keyword", kind: .dictation).map(\.id) == [dictation])
        #expect(try database.search("keyword", kind: .meeting).map(\.id) == [meeting])
        #expect(try database.search("keyword").count == 2)
    }

    @Test func recentDictationsExcludeFailuresAndMeetings() throws {
        let (database, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try insert(database, kind: .dictation, title: "Good", body: "usable text")
        _ = try insert(database, kind: .meeting, title: "Meeting", body: "not insertable")
        let now = Date()
        try database.insertSession(SessionRecord(
            id: UUID(), kind: .dictation, title: "Broken", state: .failed,
            startedAt: now, endedAt: now, duration: 1,
            sourceApplication: nil, sourceBundleIdentifier: nil,
            modelSnapshot: "{}", audioRelativePath: nil, summary: nil,
            errorMessage: "x", createdAt: now, updatedAt: now
        ))

        // The palette inserts text; an item with no usable text does not belong.
        #expect(try database.recentDictations().map(\.id) == [good])
    }

    @Test func renamingASpeakerRewritesTheWholeMeetingAndStaysSearchable() throws {
        let (database, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let session = SessionRecord(
            id: UUID(), kind: .meeting, title: "Standup", state: .completed,
            startedAt: now, endedAt: now, duration: 30,
            sourceApplication: nil, sourceBundleIdentifier: nil,
            modelSnapshot: "{}", audioRelativePath: nil, summary: nil,
            errorMessage: nil, createdAt: now, updatedAt: now
        )
        try database.insertSession(session)
        try database.replaceSegments([
            TranscriptSegmentRecord(
                id: UUID(), sessionID: session.id, position: 0, start: 0, end: 2,
                channel: .system, speaker: "Speaker 1", originalText: "one", editedText: "one"
            ),
            TranscriptSegmentRecord(
                id: UUID(), sessionID: session.id, position: 1, start: 2, end: 4,
                channel: .system, speaker: "Speaker 1", originalText: "two", editedText: "two"
            ),
            TranscriptSegmentRecord(
                id: UUID(), sessionID: session.id, position: 2, start: 4, end: 6,
                channel: .microphone, speaker: "You", originalText: "three", editedText: "three"
            ),
        ], for: session)

        try database.renameSpeaker(from: "Speaker 1", to: "Anna", in: session.id)

        let detail = try #require(try database.sessionDetail(id: session.id))
        #expect(detail.segments.map(\.speaker) == ["Anna", "Anna", "You"])
        // Speakers are indexed, so a renamed person is findable by their real name.
        #expect(try database.search("Anna", kind: .meeting).map(\.id) == [session.id])
    }

    @Test func emptyOrUnchangedRenamesAreIgnored() throws {
        let (database, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try insert(database, kind: .meeting, title: "M", body: "text")

        try database.renameSpeaker(from: "You", to: "   ", in: id)

        // A blank name would leave the transcript with an unlabelled speaker.
        #expect(try database.sessionDetail(id: id)?.segments.first?.speaker == "You")
    }

    @Test func deletingEverythingLeavesNoSessionsOrAudio() throws {
        let (database, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try insert(database, kind: .dictation, title: "A", body: "one")
        _ = try insert(database, kind: .meeting, title: "B", body: "two")
        let stray = database.audioRootURL.appending(path: "orphan.caf")
        try FileManager.default.createDirectory(at: database.audioRootURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stray)

        try database.deleteEverything()

        #expect(try database.recentSessions().isEmpty)
        // Files orphaned by an earlier crash must not survive "delete everything".
        #expect(!FileManager.default.fileExists(atPath: stray.path))
    }
}

@MainActor
@Suite("Live level meter")
struct AudioLevelMeterTests {
    @Test func risesFasterThanItFalls() {
        let meter = AudioLevelMeter()
        meter.push(1)
        let afterOnset = meter.level
        meter.push(0)
        let afterSilence = meter.level

        // Speech onset must be immediate; decay is slow so the waveform reads as a
        // shape rather than a strobe.
        #expect(afterOnset > 0.5)
        #expect(afterSilence > afterOnset * 0.8)
    }

    @Test func keepsAFixedWindowOfSamples() {
        let meter = AudioLevelMeter()
        for _ in 0..<200 { meter.push(0.4) }
        #expect(meter.samples.count == AudioLevelMeter.barCount)
    }

    @Test func reportsSilenceOnlyOnceItIsInformative() {
        let meter = AudioLevelMeter()
        for _ in 0..<50 { meter.push(0.001) }

        // Early silence just means they have not started talking yet.
        #expect(!meter.looksSilent(after: 0.5))
        // Later, it means the microphone is muted or wrong — worth saying.
        #expect(meter.looksSilent(after: 3))
    }

    @Test func realSpeechIsNeverReportedAsSilence() {
        let meter = AudioLevelMeter()
        for _ in 0..<50 { meter.push(0.3) }
        #expect(!meter.looksSilent(after: 5))
    }

    @Test func resetClearsPeakSoTheNextTakeStartsClean() {
        let meter = AudioLevelMeter()
        meter.push(0.9)
        meter.reset()
        #expect(meter.peak == 0)
        #expect(meter.samples.allSatisfy { $0 == 0 })
        #expect(!meter.looksSilent(after: 0.1))
    }
}

@Suite("Speaker colours")
struct SpeakerColourTests {
    @Test func areStableAcrossCalls() {
        // `Hasher` is seeded per process, so a naive hash would repaint every
        // speaker on relaunch. The colour must be a function of the name alone.
        #expect(Palette.speaker("Anna") == Palette.speaker("Anna"))
        #expect(Palette.speaker("Speaker 2") == Palette.speaker("Speaker 2"))
    }

    @Test func theOwnerIsAlwaysTheSameWarmTone() {
        #expect(Palette.speaker("You") == Palette.selfSpeaker)
    }
}

@Suite("Clock formatting")
struct ClockTests {
    @Test func showsMinutesUntilAnHourThenHours() {
        #expect(Clock.string(7) == "0:07")
        #expect(Clock.string(64) == "1:04")
        #expect(Clock.string(3_862) == "1:04:22")
    }

    @Test func guardsAgainstNonFiniteAndNegativeValues() {
        #expect(Clock.string(.nan) == "0:00")
        #expect(Clock.string(-5) == "0:00")
        #expect(Clock.compact(.infinity) == "—")
    }
}
