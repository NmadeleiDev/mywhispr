import Foundation
import GRDB

final class AppDatabase: @unchecked Sendable {
    let queue: DatabaseQueue
    let rootURL: URL
    let audioRootURL: URL
    let databaseURL: URL

    convenience init(fileManager: FileManager = .default) throws {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try self.init(
            rootURL: applicationSupport.appending(path: "MyWhispr", directoryHint: .isDirectory),
            fileManager: fileManager
        )
    }

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        audioRootURL = rootURL.appending(path: "Audio", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: audioRootURL, withIntermediateDirectories: true)

        let databaseURL = rootURL.appending(path: "MyWhispr.sqlite")
        self.databaseURL = databaseURL
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try Self.migrator.migrate(queue)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "sessions") { table in
                table.column("id", .text).primaryKey()
                table.column("kind", .text).notNull().indexed()
                table.column("title", .text).notNull()
                table.column("state", .text).notNull().indexed()
                table.column("startedAt", .datetime).notNull().indexed()
                table.column("endedAt", .datetime)
                table.column("duration", .double).notNull().defaults(to: 0)
                table.column("sourceApplication", .text)
                table.column("sourceBundleIdentifier", .text)
                table.column("modelSnapshot", .text).notNull()
                table.column("audioRelativePath", .text)
                table.column("summary", .text)
                table.column("errorMessage", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "transcriptSegments") { table in
                table.column("id", .text).primaryKey()
                table.column("sessionID", .text)
                    .notNull()
                    .indexed()
                    .references("sessions", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("start", .double).notNull()
                table.column("end", .double).notNull()
                table.column("channel", .text).notNull()
                table.column("speaker", .text).notNull()
                table.column("originalText", .text).notNull()
                table.column("editedText", .text).notNull()
                table.uniqueKey(["sessionID", "position"])
            }

            try db.create(virtualTable: "sessionSearch", using: FTS5()) { table in
                table.tokenizer = .porter()
                table.column("sessionID").notIndexed()
                table.column("title")
                table.column("body")
                table.column("speakers")
                table.column("summary")
            }
        }
        // Transcripts recorded before the Whisper engine was told to skip the
        // model's control tokens have them sitting in the text — a
        // `<|startoftranscript|>` opening every segment and a `<|9.36|>` closing it.
        // Fixing the engine only fixes the next transcript; an hour-long meeting
        // already stored would otherwise have to be edited by hand, segment by
        // segment, which is not a repair anyone should be asked to perform.
        migrator.registerMigration("v2-strip-model-markup") { db in
            try removeModelMarkup(in: db)
        }
        // Questions asked about a meeting, and the answers given.
        //
        // Not indexed for search. Searching meetings is a search for what was *said*,
        // and folding one's own questions into that would return a meeting because of
        // a word the owner typed rather than a word anyone spoke.
        migrator.registerMigration("v3-meeting-chat") { db in
            try db.create(table: "chatMessages") { table in
                table.column("id", .text).primaryKey()
                table.column("sessionID", .text)
                    .notNull()
                    .indexed()
                    .references("sessions", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("role", .text).notNull()
                table.column("content", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.uniqueKey(["sessionID", "position"])
            }
        }
        return migrator
    }

    /// Rewrites stored text that carries a speech model's own control tokens.
    ///
    /// Both texts of a segment are rewritten. `originalText` is what the engine
    /// heard and is shown when the owner asks what was really said — markup was
    /// never part of that either — and `editedText` is what everything else reads.
    /// The search index is rebuilt for whatever changed, since it was indexed on
    /// the markup too.
    @discardableResult
    static func removeModelMarkup(in db: Database) throws -> Int {
        var touchedSessions: Set<UUID> = []

        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, sessionID, originalText, editedText FROM transcriptSegments"
        )
        for row in rows {
            let original: String = row["originalText"]
            let edited: String = row["editedText"]
            guard WhisperMarkup.containsMarkup(original) || WhisperMarkup.containsMarkup(edited) else { continue }
            let sessionID: UUID = row["sessionID"]
            try db.execute(
                sql: "UPDATE transcriptSegments SET originalText = ?, editedText = ? WHERE id = ?",
                arguments: [WhisperMarkup.stripped(original), WhisperMarkup.stripped(edited), row["id"] as UUID]
            )
            touchedSessions.insert(sessionID)
        }

        // A dictation's title is made from its own text, and a summary is made from
        // the transcript, so both can carry the same markup.
        let sessions = try Row.fetchAll(db, sql: "SELECT id, title, summary FROM sessions")
        for row in sessions {
            let id: UUID = row["id"]
            let title: String = row["title"]
            let summary: String? = row["summary"]
            let dirtyTitle = WhisperMarkup.containsMarkup(title)
            let dirtySummary = summary.map(WhisperMarkup.containsMarkup) ?? false
            guard dirtyTitle || dirtySummary else { continue }
            try db.execute(
                sql: "UPDATE sessions SET title = ?, summary = ? WHERE id = ?",
                arguments: [
                    dirtyTitle ? WhisperMarkup.stripped(title) : title,
                    dirtySummary ? summary.map(WhisperMarkup.stripped) : summary,
                    id,
                ]
            )
            touchedSessions.insert(id)
        }

        for sessionID in touchedSessions {
            try Self.rebuildSearchIndex(for: sessionID, db: db)
        }
        return touchedSessions.count
    }

    func insertSession(_ session: SessionRecord) throws {
        try queue.write { db in try session.insert(db) }
    }

    func updateSession(_ session: SessionRecord) throws {
        try queue.write { db in
            try session.update(db)
            if session.state == .completed {
                try Self.rebuildSearchIndex(for: session.id, db: db)
            }
        }
    }

    func replaceSegments(_ segments: [TranscriptSegmentRecord], for session: SessionRecord) throws {
        try queue.write { db in
            try TranscriptSegmentRecord.filter(Column("sessionID") == session.id).deleteAll(db)
            for segment in segments { try segment.insert(db) }
            try Self.rebuildSearchIndex(for: session.id, db: db)
        }
    }

    func updateSegment(id: UUID, text: String, speaker: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE transcriptSegments SET editedText = ?, speaker = ? WHERE id = ?",
                arguments: [text, speaker, id]
            )
            if let sessionID = try UUID.fetchOne(
                db,
                sql: "SELECT sessionID FROM transcriptSegments WHERE id = ?",
                arguments: [id]
            ) {
                try Self.rebuildSearchIndex(for: sessionID, db: db)
            }
        }
    }

    // MARK: - Meeting conversations

    func chatMessages(for sessionID: UUID) throws -> [ChatMessageRecord] {
        try queue.read { db in
            try ChatMessageRecord
                .filter(Column("sessionID") == sessionID)
                .order(Column("position"))
                .fetchAll(db)
        }
    }

    func appendChatMessage(_ message: ChatMessageRecord) throws {
        try queue.write { db in try message.insert(db) }
    }

    /// Removes the whole conversation about one meeting, leaving the meeting alone.
    func deleteChatMessages(for sessionID: UUID) throws {
        try queue.write { db in
            _ = try ChatMessageRecord.filter(Column("sessionID") == sessionID).deleteAll(db)
        }
    }

    func recentSessions(kind: WorkflowKind? = nil, limit: Int = 200) throws -> [SessionRecord] {
        try queue.read { db in
            var request = SessionRecord.order(Column("startedAt").desc)
            if let kind { request = request.filter(Column("kind") == kind) }
            return try request.limit(limit).fetchAll(db)
        }
    }

    func sessionDetail(id: UUID) throws -> SessionDetail? {
        try queue.read { db in
            guard let session = try SessionRecord.fetchOne(db, key: id) else { return nil }
            let segments = try TranscriptSegmentRecord
                .filter(Column("sessionID") == id)
                .order(Column("position"))
                .fetchAll(db)
            return SessionDetail(session: session, segments: segments)
        }
    }

    func search(_ query: String, kind: WorkflowKind? = nil, limit: Int = 100) throws -> [SessionRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return try recentSessions(kind: kind, limit: limit) }
        // FTS5 treats bare punctuation as syntax. Quoting each term keeps a search
        // for `C++` or `don't` from failing with a parse error instead of results.
        let pattern = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
        return try queue.read { db in
            try SessionRecord.fetchAll(
                db,
                sql: """
                SELECT sessions.* FROM sessionSearch
                JOIN sessions ON sessions.id = sessionSearch.sessionID
                WHERE sessionSearch MATCH ?
                \(kind == nil ? "" : "AND sessions.kind = ?")
                ORDER BY rank LIMIT ?
                """,
                arguments: kind == nil
                    ? StatementArguments([pattern, limit] as [any DatabaseValueConvertible])
                    : StatementArguments([pattern, kind!, limit] as [any DatabaseValueConvertible])
            )
        }
    }

    func deleteSession(id: UUID, fileManager: FileManager = .default) throws {
        let relativePath = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT audioRelativePath FROM sessions WHERE id = ?", arguments: [id])
        }
        if let relativePath {
            let fileURL = rootURL.appending(path: relativePath)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
        try queue.write { db in
            try db.execute(sql: "DELETE FROM sessionSearch WHERE sessionID = ?", arguments: [id])
            _ = try SessionRecord.deleteOne(db, key: id)
        }
    }

    /// Recovers everything the last run left mid-flight.
    ///
    /// Both live states are the same claim — "a process is working on this right
    /// now" — and that claim is false the moment the app starts, because the process
    /// that made it is gone. `recording` was already handled; `processing` was not,
    /// and a meeting stranded in it showed a progress notice that would never move,
    /// with no way to restart the work: the audio was on disk and unreachable.
    /// Both become `interrupted`, which is the state the meeting screen offers to
    /// retry from.
    func markInterruptedRecordings() throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET state = ?, updatedAt = ? WHERE state IN (?, ?)",
                arguments: [SessionState.interrupted, Date(), SessionState.recording, SessionState.processing]
            )
        }
    }

    func pruneDictations(olderThan date: Date) throws {
        let ids = try queue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT id FROM sessions WHERE kind = ? AND startedAt < ?",
                arguments: [WorkflowKind.dictation, date]
            )
        }
        for id in ids { try deleteSession(id: id) }
    }

    func pruneFailedDictations(olderThan date: Date) throws {
        let ids = try queue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT id FROM sessions WHERE kind = ? AND state = ? AND createdAt < ?",
                arguments: [WorkflowKind.dictation, SessionState.failed, date]
            )
        }
        for id in ids { try deleteSession(id: id) }
    }

    /// Renames one speaker across every passage of a meeting.
    ///
    /// Renaming is a whole-meeting operation because that is what it means to the
    /// owner: "Speaker 2 is Anna" is a fact about the meeting, not about one line.
    func renameSpeaker(from original: String, to updated: String, in sessionID: UUID) throws {
        let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != original else { return }
        try queue.write { db in
            try db.execute(
                sql: "UPDATE transcriptSegments SET speaker = ? WHERE sessionID = ? AND speaker = ?",
                arguments: [trimmed, sessionID, original]
            )
            try Self.rebuildSearchIndex(for: sessionID, db: db)
        }
    }

    /// Most recent completed dictations, for the menu bar and the quick-paste
    /// palette. Failed and in-flight items are excluded — there is nothing to
    /// insert from them.
    func recentDictations(limit: Int = 40) throws -> [SessionRecord] {
        try queue.read { db in
            try SessionRecord
                .filter(Column("kind") == WorkflowKind.dictation)
                .filter(Column("state") == SessionState.completed)
                .order(Column("startedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Deletes every session, its passages, its search rows, and every audio file
    /// the store owns.
    func deleteEverything(fileManager: FileManager = .default) throws {
        let ids = try queue.read { db in try UUID.fetchAll(db, sql: "SELECT id FROM sessions") }
        for id in ids { try deleteSession(id: id, fileManager: fileManager) }
        // Sweep the audio root as well, so files orphaned by an earlier crash do not
        // survive a "delete everything" the owner reasonably expects to be total.
        if fileManager.fileExists(atPath: audioRootURL.path) {
            for entry in (try? fileManager.contentsOfDirectory(at: audioRootURL, includingPropertiesForKeys: nil)) ?? [] {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    /// Bytes used by the SQLite store, including its write-ahead log.
    func storeSize() -> Int64 {
        let manager = FileManager.default
        return ["", "-wal", "-shm"].reduce(into: Int64(0)) { total, suffix in
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int64 else { return }
            total += size
        }
    }

    /// Deletes only a meeting's audio tracks, keeping its transcript and summary.
    func discardAudio(for sessionID: UUID, fileManager: FileManager = .default) throws {
        guard var session = try queue.read({ db in try SessionRecord.fetchOne(db, key: sessionID) }),
              let relativePath = session.audioRelativePath else { return }
        let url = rootURL.appending(path: relativePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        session.audioRelativePath = nil
        session.updatedAt = Date()
        try updateSession(session)
    }

    /// Static because the migrator needs it too, and it reads nothing but the
    /// database handle it is given.
    private static func rebuildSearchIndex(for sessionID: UUID, db: Database) throws {
        guard let session = try SessionRecord.fetchOne(db, key: sessionID) else { return }
        let segments = try TranscriptSegmentRecord
            .filter(Column("sessionID") == sessionID)
            .order(Column("position"))
            .fetchAll(db)
        try db.execute(sql: "DELETE FROM sessionSearch WHERE sessionID = ?", arguments: [sessionID])
        try db.execute(
            sql: "INSERT INTO sessionSearch (sessionID, title, body, speakers, summary) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                sessionID,
                session.title,
                segments.map(\.editedText).joined(separator: " "),
                Set(segments.map(\.speaker)).sorted().joined(separator: " "),
                session.summary ?? "",
            ]
        )
    }
}
