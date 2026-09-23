import Foundation
import Testing
@testable import MyWhispr

@Suite("Session persistence", .serialized)
struct AppDatabaseTests {
    @Test func storesSearchesEditsAndDeletesMeeting() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(rootURL: root)
        let now = Date()
        let session = SessionRecord(
            id: UUID(), kind: .meeting, title: "Design review", state: .completed,
            startedAt: now, endedAt: now, duration: 60,
            sourceApplication: nil, sourceBundleIdentifier: nil,
            modelSnapshot: "{}", audioRelativePath: nil, summary: "Ship the recorder",
            errorMessage: nil, createdAt: now, updatedAt: now
        )
        let segment = TranscriptSegmentRecord(
            id: UUID(), sessionID: session.id, position: 0, start: 0, end: 4,
            channel: .system, speaker: "Speaker 1", originalText: "Original words",
            editedText: "Approve MyWhispr"
        )

        try database.insertSession(session)
        try database.replaceSegments([segment], for: session)
        #expect(try database.search("MyWhispr").map(\.id) == [session.id])

        try database.updateSegment(id: segment.id, text: "Approved locally", speaker: "Speaker 2")
        let detail = try #require(try database.sessionDetail(id: session.id))
        #expect(detail.transcript == "Approved locally")
        #expect(detail.segments.first?.speaker == "Speaker 2")
        #expect(try database.search("locally").first?.id == session.id)

        let transcriptFile = try database.exportMeetingFile(id: session.id, kind: .transcript)
        let notesFile = try database.exportMeetingFile(id: session.id, kind: .notes)
        #expect(transcriptFile.pathExtension == "txt")
        #expect(notesFile.pathExtension == "md")
        #expect(try String(contentsOf: transcriptFile, encoding: .utf8) == detail.annotatedTranscript)
        #expect(try String(contentsOf: notesFile, encoding: .utf8) == "Ship the recorder")
        try database.updateSegment(id: segment.id, text: "Обновлённый текст", speaker: "Гриша")
        let refreshedFile = try database.exportMeetingFile(id: session.id, kind: .transcript)
        #expect(refreshedFile == transcriptFile)
        #expect(try String(contentsOf: refreshedFile, encoding: .utf8).contains("Обновлённый текст"))
        #expect(try String(contentsOf: refreshedFile, encoding: .utf8).contains("Гриша"))

        // A failed write propagates instead of returning a nonexistent file path.
        try FileManager.default.removeItem(at: notesFile)
        try FileManager.default.createDirectory(at: notesFile, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try database.exportMeetingFile(id: session.id, kind: .notes)
        }

        try database.deleteSession(id: session.id)
        #expect(try database.sessionDetail(id: session.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: transcriptFile.path))
        #expect(!FileManager.default.fileExists(atPath: notesFile.path))
        #expect(throws: (any Error).self) {
            try database.exportMeetingFile(id: session.id, kind: .transcript)
        }
    }

    @Test func marksInFlightRecordingInterruptedAfterRestart() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(rootURL: root)
        let now = Date()
        let session = SessionRecord(
            id: UUID(), kind: .meeting, title: "Interrupted", state: .recording,
            startedAt: now, endedAt: nil, duration: 0,
            sourceApplication: nil, sourceBundleIdentifier: nil,
            modelSnapshot: "{}", audioRelativePath: "Audio/test", summary: nil,
            errorMessage: nil, createdAt: now, updatedAt: now
        )
        try database.insertSession(session)

        try database.markInterruptedRecordings()

        #expect(try database.sessionDetail(id: session.id)?.session.state == .interrupted)
    }

    /// A meeting the last run was still transcribing is recoverable too.
    ///
    /// It used to be left claiming to be processing, which no process was: the
    /// screen showed a progress notice that could never move and offered no way to
    /// restart, so an hour of audio sat on disk unreachable. Both live states are
    /// the same claim about a process that no longer exists.
    @Test func marksInFlightProcessingInterruptedAfterRestart() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(rootURL: root)
        let now = Date()
        func session(_ state: SessionState) -> SessionRecord {
            SessionRecord(
                id: UUID(), kind: .meeting, title: "Meeting", state: state,
                startedAt: now, endedAt: now, duration: 60,
                sourceApplication: nil, sourceBundleIdentifier: nil,
                modelSnapshot: "{}", audioRelativePath: "Audio/test", summary: nil,
                errorMessage: nil, createdAt: now, updatedAt: now
            )
        }
        let transcribing = session(.processing)
        let finished = session(.completed)
        try database.insertSession(transcribing)
        try database.insertSession(finished)

        try database.markInterruptedRecordings()

        #expect(try database.sessionDetail(id: transcribing.id)?.session.state == .interrupted)
        // Only what was mid-flight. A finished meeting is not reopened.
        #expect(try database.sessionDetail(id: finished.id)?.session.state == .completed)
    }

    @Test func expiresFailedDictationAndItsRetainedAudio() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(rootURL: root)
        let id = UUID()
        let relativePath = "Audio/FailedDictations/\(id.uuidString).caf"
        let audioURL = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: audioURL)
        let old = Date().addingTimeInterval(-90_000)
        try database.insertSession(SessionRecord(
            id: id, kind: .dictation, title: "Failed", state: .failed,
            startedAt: old, endedAt: old, duration: 1,
            sourceApplication: nil, sourceBundleIdentifier: nil,
            modelSnapshot: "{}", audioRelativePath: relativePath,
            summary: nil, errorMessage: "test", createdAt: old, updatedAt: old
        ))

        try database.pruneFailedDictations(olderThan: Date().addingTimeInterval(-86_400))

        #expect(try database.sessionDetail(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test func clearsOnlyCompletedMeetingAudioAndPreservesContent() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(rootURL: root)
        let now = Date()
        let cases: [(WorkflowKind, SessionState)] = [
            (.meeting, .completed), (.meeting, .failed), (.meeting, .interrupted),
            (.meeting, .recording), (.meeting, .processing),
            (.dictation, .completed), (.dictation, .failed),
        ]
        var fixtures: [SessionRecord] = []
        for (kind, state) in cases {
            let id = UUID()
            let relativePath = "Audio/\(id.uuidString)"
            let directory = root.appending(path: relativePath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for track in ["microphone.caf", "system.caf"] {
                try Data("audio".utf8).write(to: directory.appending(path: track))
            }
            let session = SessionRecord(
                id: id, kind: kind, title: "Meeting", state: state,
                startedAt: now, endedAt: now, duration: 60,
                sourceApplication: nil, sourceBundleIdentifier: nil,
                modelSnapshot: "{}", audioRelativePath: relativePath, summary: "Keep these notes",
                errorMessage: nil, createdAt: now, updatedAt: now
            )
            try database.insertSession(session)
            try database.replaceSegments([TranscriptSegmentRecord(
                id: UUID(), sessionID: id, position: 0, start: 0, end: 4,
                channel: .system, speaker: "Speaker 1", originalText: "Keep these words",
                editedText: "Keep these words"
            )], for: session)
            fixtures.append(session)
        }

        // A filesystem failure is reported, and the audio reference remains retryable.
        #expect(throws: (any Error).self) {
            try database.clearCompletedMeetingRecordings(fileManager: RefusingAudioRemoval())
        }
        #expect(try database.sessionDetail(id: fixtures[0].id)?.session.audioRelativePath == fixtures[0].audioRelativePath)

        #expect(try database.clearCompletedMeetingRecordings() == 1)
        for session in fixtures {
            let detail = try #require(try database.sessionDetail(id: session.id))
            let cleared = session.kind == .meeting && session.state == .completed
            #expect(detail.session.audioRelativePath == (cleared ? nil : session.audioRelativePath))
            #expect(detail.session.state == session.state)
            #expect(detail.session.summary == "Keep these notes")
            #expect(detail.transcript == "Keep these words")
            let directory = root.appending(path: try #require(session.audioRelativePath))
            for track in ["microphone.caf", "system.caf"] {
                #expect(FileManager.default.fileExists(atPath: directory.appending(path: track).path) == !cleared)
            }
        }
        #expect(try database.search("words").count == fixtures.count)
        #expect(try database.clearCompletedMeetingRecordings() == 0)

        // A stale reference to already-missing audio is cleared without losing text.
        var missing = fixtures[0]
        missing.audioRelativePath = "Audio/already-missing"
        try database.updateSession(missing)
        #expect(try database.clearCompletedMeetingRecordings() == 1)
        #expect(try database.sessionDetail(id: missing.id)?.session.audioRelativePath == nil)
        #expect(try database.sessionDetail(id: missing.id)?.transcript == "Keep these words")
    }

    @Test func tagsAttachFilterAndPruneWhenUnused() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(rootURL: root)
        let now = Date()

        func meeting(_ title: String) -> SessionRecord {
            SessionRecord(
                id: UUID(), kind: .meeting, title: title, state: .completed,
                startedAt: now, endedAt: now, duration: 30,
                sourceApplication: nil, sourceBundleIdentifier: nil,
                modelSnapshot: "{}", audioRelativePath: nil, summary: nil,
                errorMessage: nil, createdAt: now, updatedAt: now
            )
        }

        let design = meeting("Design review")
        let standup = meeting("Standup")
        let planning = meeting("Planning")
        try database.insertSession(design)
        try database.insertSession(standup)
        try database.insertSession(planning)

        let work = try #require(try database.addTag(named: "  Work  ", to: design.id))
        #expect(work.name == "Work")
        // Case-insensitive reuse keeps the first-seen casing.
        let again = try #require(try database.addTag(named: "work", to: standup.id))
        #expect(again.id == work.id)
        #expect(again.name == "Work")
        let client = try #require(try database.addTag(named: "Client", to: design.id))
        _ = try database.addTag(named: "Client", to: planning.id)

        #expect(try database.addTag(named: "   ", to: design.id) == nil)

        let designDetail = try #require(try database.sessionDetail(id: design.id))
        #expect(designDetail.tags.map(\.name).sorted() == ["Client", "Work"])

        let byWork = try database.recentSessions(kind: .meeting, matchingAnyTagIDs: [work.id])
        #expect(Set(byWork.map(\.id)) == [design.id, standup.id])

        let byEither = try database.recentSessions(
            kind: .meeting,
            matchingAnyTagIDs: [work.id, client.id]
        )
        #expect(Set(byEither.map(\.id)) == [design.id, standup.id, planning.id])

        try database.replaceSegments([
            TranscriptSegmentRecord(
                id: UUID(), sessionID: design.id, position: 0, start: 0, end: 2,
                channel: .system, speaker: "A", originalText: "ship it",
                editedText: "ship it"
            )
        ], for: design)
        let searched = try database.search(
            "ship",
            kind: .meeting,
            matchingAnyTagIDs: [client.id]
        )
        #expect(searched.map(\.id) == [design.id])

        try database.removeTag(id: work.id, from: design.id)
        #expect(try database.allTags().map(\.name).sorted() == ["Client", "Work"])
        try database.removeTag(id: work.id, from: standup.id)
        #expect(try database.allTags().map(\.name) == ["Client"])

        try database.deleteSession(id: design.id)
        try database.deleteSession(id: planning.id)
        #expect(try database.allTags().isEmpty)
    }
}

private final class RefusingAudioRemoval: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
