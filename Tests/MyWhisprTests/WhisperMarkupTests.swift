import Foundation
import GRDB
import Testing
@testable import MyWhispr

/// A Whisper model emits control tokens alongside words, and whether they survive
/// into the decoded string is a library option that defaults to leaving them in.
/// It was left at its default, so an hour-long meeting was transcribed with
/// `<|startoftranscript|><|ru|><|transcribe|><|0.00|>` opening every segment and a
/// timestamp closing it.
@Suite("Whisper control tokens")
struct WhisperMarkupTests {
    @Test func removesTheOpeningPreambleAndTheClosingTimestamp() {
        let raw = "<|startoftranscript|><|en|><|transcribe|><|0.00|> Mm-hmm.<|1.48|><|endoftext|>"
        #expect(WhisperMarkup.stripped(raw) == "Mm-hmm.")
    }

    @Test func removesTimestampsFromTheMiddleOfASentence() {
        let raw = "<|15.42|> нужен продукт и и типа на 1 ссылка но<|24.44|>"
        #expect(WhisperMarkup.stripped(raw) == "нужен продукт и и типа на 1 ссылка но")
    }

    /// A token can sit hard against the words on both sides. Deleting it outright
    /// would run them together into something that is neither a word nor findable
    /// by searching for either half.
    @Test func doesNotGlueTogetherTheWordsItSatBetween() {
        #expect(WhisperMarkup.stripped("чего<|15.42|>нужен") == "чего нужен")
    }

    /// The space the token leaves behind must not be left in front of punctuation.
    @Test func doesNotStrandSpaceBeforePunctuation() {
        #expect(WhisperMarkup.stripped("Это супер<|7.56|>.") == "Это супер.")
    }

    @Test func leavesOrdinarySpeechExactlyAsItIs() {
        let spoken = "Ну да, вот с этим мы тоже понимаем, что есть такая проблема."
        #expect(WhisperMarkup.stripped(spoken) == spoken)
        #expect(!WhisperMarkup.containsMarkup(spoken))
        // Angle brackets and pipes are not markup on their own; code dictated aloud
        // must survive.
        #expect(WhisperMarkup.stripped("a < b | c > d") == "a < b | c > d")
    }

    @Test func recognisesWhenThereIsNothingToDo() {
        #expect(WhisperMarkup.containsMarkup("<|9.36|> вроде бы"))
        #expect(!WhisperMarkup.containsMarkup("вроде бы"))
    }
}

/// The engine fix only fixes the next transcript. This is about the ones already
/// stored, which the owner would otherwise have to repair by hand.
@Suite("Repairing stored transcripts")
struct ModelMarkupMigrationTests {
    @Test func rewritesTranscriptsRecordedBeforeTheEngineWasFixed() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/test-markup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)

        // Stop at the schema as it stood when the bad transcripts were written, so
        // this exercises the upgrade an existing install actually performs.
        try AppDatabase.migrator.migrate(queue, upTo: "v1")

        let sessionID = UUID()
        let dirtySegmentID = UUID()
        let cleanSegmentID = UUID()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (id, kind, title, state, startedAt, duration,
                    modelSnapshot, createdAt, updatedAt)
                VALUES (?, 'meeting', 'Meeting · 21 Aug', 'completed', ?, 60, '{}', ?, ?)
                """,
                arguments: [sessionID, Date(), Date(), Date()]
            )
            try db.execute(
                sql: """
                INSERT INTO transcriptSegments
                    (id, sessionID, position, start, end, channel, speaker, originalText, editedText)
                VALUES (?, ?, 0, 0, 9.36, 'system', 'Speaker 1', ?, ?)
                """,
                arguments: [
                    dirtySegmentID, sessionID,
                    "<|startoftranscript|><|ru|><|transcribe|><|0.00|> но я не знаю<|9.36|>",
                    "<|startoftranscript|><|ru|><|transcribe|><|0.00|> но я не знаю<|9.36|>",
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO transcriptSegments
                    (id, sessionID, position, start, end, channel, speaker, originalText, editedText)
                VALUES (?, ?, 1, 9.36, 15.42, 'microphone', 'You', 'Это супер.', 'Это супер.')
                """,
                arguments: [cleanSegmentID, sessionID]
            )
        }

        try AppDatabase.migrator.migrate(queue)

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, originalText, editedText FROM transcriptSegments ORDER BY position")
        }
        #expect(rows[0]["originalText"] == "но я не знаю")
        #expect(rows[0]["editedText"] == "но я не знаю")
        // Untouched text stays byte-for-byte what it was.
        #expect(rows[1]["editedText"] == "Это супер.")

        // The index was built over the markup too, so a word next to a control token
        // has to become findable.
        let indexed = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM sessionSearch WHERE sessionID = ?", arguments: [sessionID])
        }
        #expect(indexed?.contains("<|") == false)
        #expect(indexed?.contains("но я не знаю") == true)
    }

    @Test func repairIsSafeToRunWhenThereIsNothingToRepair() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        // A fresh database runs the migration over an empty schema and again here.
        let database = try AppDatabase(rootURL: root)
        #expect(try database.recentSessions().isEmpty)
    }
}
