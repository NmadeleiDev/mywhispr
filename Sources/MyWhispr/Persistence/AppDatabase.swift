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
        return migrator
    }

    func insertSession(_ session: SessionRecord) throws {
        try queue.write { db in try session.insert(db) }
    }

    func updateSession(_ session: SessionRecord) throws {
        try queue.write { db in
            try session.update(db)
            if session.state == .completed {
                try rebuildSearchIndex(for: session.id, db: db)
            }
        }
    }

    func replaceSegments(_ segments: [TranscriptSegmentRecord], for session: SessionRecord) throws {
        try queue.write { db in
            try TranscriptSegmentRecord.filter(Column("sessionID") == session.id).deleteAll(db)
            for segment in segments { try segment.insert(db) }
            try rebuildSearchIndex(for: session.id, db: db)
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
                try rebuildSearchIndex(for: sessionID, db: db)
            }
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

    func markInterruptedRecordings() throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET state = ?, updatedAt = ? WHERE state = ?",
                arguments: [SessionState.interrupted, Date(), SessionState.recording]
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
            try rebuildSearchIndex(for: sessionID, db: db)
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

    private func rebuildSearchIndex(for sessionID: UUID, db: Database) throws {
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
