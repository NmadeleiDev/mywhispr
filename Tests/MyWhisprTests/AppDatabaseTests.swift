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

        try database.deleteSession(id: session.id)
        #expect(try database.sessionDetail(id: session.id) == nil)
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
}
