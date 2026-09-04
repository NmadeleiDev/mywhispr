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
        migrator.registerMigration("v4-scoped-conversations-and-meeting-passages") { db in
            try db.create(table: "conversations") { table in
                table.column("id", .text).primaryKey()
                table.column("kind", .text).notNull()
                table.column("sessionID", .text)
                    .unique()
                    .references("sessions", onDelete: .cascade)
                table.check(sql: """
                    (kind = 'allMeetings' AND sessionID IS NULL AND id = 'all-meetings')
                    OR (kind = 'meeting' AND sessionID IS NOT NULL AND id <> 'all-meetings')
                    """)
            }
            try db.execute(
                sql: "INSERT INTO conversations (id, kind, sessionID) VALUES (?, 'allMeetings', NULL)",
                arguments: [ConversationScope.allMeetingsID]
            )
            try db.execute(sql: "ALTER TABLE chatMessages RENAME TO legacyChatMessages")
            try db.execute(sql: """
                INSERT INTO conversations (id, kind, sessionID)
                SELECT DISTINCT
                    CASE typeof(sessionID)
                        WHEN 'blob' THEN
                            substr(hex(sessionID), 1, 8) || '-' ||
                            substr(hex(sessionID), 9, 4) || '-' ||
                            substr(hex(sessionID), 13, 4) || '-' ||
                            substr(hex(sessionID), 17, 4) || '-' ||
                            substr(hex(sessionID), 21, 12)
                        ELSE upper(sessionID)
                    END,
                    'meeting',
                    sessionID
                FROM legacyChatMessages
                """)
            try db.create(table: "chatMessages") { table in
                table.column("id", .text).primaryKey()
                table.column("conversationID", .text)
                    .notNull()
                    .indexed()
                    .references("conversations", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("role", .text).notNull()
                table.column("content", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.uniqueKey(["conversationID", "position"])
            }
            try db.execute(sql: """
                INSERT INTO chatMessages (id, conversationID, position, role, content, createdAt)
                SELECT id,
                    CASE typeof(sessionID)
                        WHEN 'blob' THEN
                            substr(hex(sessionID), 1, 8) || '-' ||
                            substr(hex(sessionID), 9, 4) || '-' ||
                            substr(hex(sessionID), 13, 4) || '-' ||
                            substr(hex(sessionID), 17, 4) || '-' ||
                            substr(hex(sessionID), 21, 12)
                        ELSE upper(sessionID)
                    END,
                    position, role, content, createdAt
                FROM legacyChatMessages
                """)
            try db.drop(table: "legacyChatMessages")

            try db.create(virtualTable: "meetingPassageSearch", using: FTS5()) { table in
                table.tokenizer = .porter()
                table.column("passageID").notIndexed()
                table.column("sessionID").notIndexed()
                table.column("position").notIndexed()
                table.column("start").notIndexed()
                table.column("end").notIndexed()
                table.column("title")
                table.column("body")
                table.column("speakers")
                table.column("summary")
            }
            let meetingIDs = try UUID.fetchAll(
                db,
                sql: "SELECT id FROM sessions WHERE kind = ? AND state = ?",
                arguments: [WorkflowKind.meeting, SessionState.completed]
            )
            for id in meetingIDs { try Self.rebuildSearchIndex(for: id, db: db) }
        }
        migrator.registerMigration("v5-chat-sources") { db in
            try db.create(table: "chatSources") { table in
                table.column("id", .text).primaryKey()
                table.column("messageID", .text)
                    .notNull()
                    .indexed()
                    .references("chatMessages", onDelete: .cascade)
                table.column("position", .integer).notNull()
                // A cited excerpt is an immutable snapshot. Deleting its meeting
                // only severs navigation; it must not rewrite an answer's evidence.
                table.column("sessionID", .text)
                    .indexed()
                    .references("sessions", onDelete: .setNull)
                table.column("title", .text).notNull()
                table.column("startedAt", .datetime).notNull()
                table.column("start", .double).notNull()
                table.column("end", .double).notNull()
                table.column("text", .text).notNull()
                table.column("speakers", .text).notNull()
                table.uniqueKey(["messageID", "position"])
            }
        }
        migrator.registerMigration("v6-meeting-level-chat-sources") { db in
            try db.rename(table: "chatSources", to: "legacyChatSources")
            // SQLite keeps explicit index names when a table is renamed. Release
            // the v5 names before GRDB creates the corresponding v6 indexes.
            try db.execute(sql: "DROP INDEX IF EXISTS chatSources_on_messageID")
            try db.execute(sql: "DROP INDEX IF EXISTS chatSources_on_sessionID")
            try db.create(table: "chatSources") { table in
                table.column("id", .text).primaryKey()
                table.column("messageID", .text)
                    .notNull()
                    .indexed()
                    .references("chatMessages", onDelete: .cascade)
                table.column("position", .integer).notNull()
                // This snapshot identity survives deletion; `sessionID` below is
                // only the live navigation link and is intentionally nullable.
                table.column("meetingID", .text).notNull()
                table.column("sessionID", .text)
                    .indexed()
                    .references("sessions", onDelete: .setNull)
                table.column("title", .text).notNull()
                table.column("startedAt", .datetime).notNull()
                table.column("summary", .text)
                table.uniqueKey(["messageID", "meetingID"])
                table.uniqueKey(["messageID", "position"])
            }
            try db.create(table: "chatSourcePassages") { table in
                table.column("id", .text).primaryKey()
                table.column("sourceID", .text)
                    .notNull()
                    .indexed()
                    .references("chatSources", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("start", .double).notNull()
                table.column("end", .double).notNull()
                table.column("text", .text).notNull()
                table.column("speakers", .text).notNull()
                table.uniqueKey(["sourceID", "position"])
            }
            try Self.migrateLegacyChatSources(db)
            try db.drop(table: "legacyChatSources")
        }
        migrator.registerMigration("v7-grounded-hybrid-meeting-search") { db in
            // Meeting-level generated metadata is useful for discovering a
            // recording, but it must not rank an arbitrary transcript passage.
            // Rebuild the passage index from transcript-owned fields only.
            try db.drop(table: "meetingPassageSearch")
            try db.create(virtualTable: "meetingPassageSearch", using: FTS5()) { table in
                table.tokenizer = .porter()
                table.column("passageID").notIndexed()
                table.column("sessionID").notIndexed()
                table.column("position").notIndexed()
                table.column("start").notIndexed()
                table.column("end").notIndexed()
                table.column("body")
                table.column("speakers")
            }
            try db.create(virtualTable: "meetingMetadataSearch", using: FTS5()) { table in
                table.tokenizer = .unicode61()
                table.column("sessionID").notIndexed()
                table.column("title")
                table.column("speakers")
                table.column("summary")
            }
            try db.create(table: "meetingPassageEmbeddings") { table in
                table.column("passageID", .text).notNull()
                table.column("sessionID", .text)
                    .notNull()
                    .indexed()
                    .references("sessions", onDelete: .cascade)
                table.column("model", .text).notNull().indexed()
                table.column("textHash", .text).notNull()
                table.column("dimensions", .integer).notNull()
                table.column("vector", .blob).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.primaryKey(["passageID", "model"])
            }
            let meetingIDs = try UUID.fetchAll(
                db,
                sql: "SELECT id FROM sessions WHERE kind = ? AND state = ?",
                arguments: [WorkflowKind.meeting, SessionState.completed]
            )
            for id in meetingIDs { try Self.rebuildSearchIndex(for: id, db: db) }
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

    /// Converts v5's passage-shaped sources into meeting sources without guessing
    /// identity that the old schema has already lost.
    ///
    /// A live row still carries `sessionID`, so every passage from that meeting can
    /// be grouped exactly and its current summary can be snapshotted. A row whose
    /// meeting was deleted has no recoverable identity; preserving it independently
    /// is safer than merging two recordings that happened to share a title or date.
    private static func migrateLegacyChatSources(_ db: Database) throws {
        struct LegacySource {
            var id: String
            var messageID: UUID
            var position: Int
            var sessionID: UUID?
            var title: String
            var startedAt: Date
            var summary: String?
            var start: TimeInterval
            var end: TimeInterval
            var text: String
            var speakers: String

            var groupingKey: String {
                sessionID?.uuidString ?? "legacy:\(id)"
            }
        }

        let legacy: [LegacySource] = try Row.fetchAll(
            db,
            sql: """
                SELECT legacyChatSources.*, sessions.summary AS meetingSummary
                FROM legacyChatSources
                LEFT JOIN sessions ON sessions.id = legacyChatSources.sessionID
                ORDER BY legacyChatSources.messageID, legacyChatSources.position
                """
        ).map { row in
            LegacySource(
                id: row["id"],
                messageID: row["messageID"],
                position: row["position"],
                sessionID: row["sessionID"],
                title: row["title"],
                startedAt: row["startedAt"],
                summary: row["meetingSummary"],
                start: row["start"],
                end: row["end"],
                text: row["text"],
                speakers: row["speakers"]
            )
        }

        var grouped: [[LegacySource]] = []
        var groupIndex: [String: Int] = [:]
        for item in legacy {
            let key = "\(item.messageID.uuidString):\(item.groupingKey)"
            if let index = groupIndex[key] {
                grouped[index].append(item)
            } else {
                groupIndex[key] = grouped.count
                grouped.append([item])
            }
        }

        for group in grouped {
            guard let first = group.first else { continue }
            let source = ChatSourceRecord(
                id: first.id,
                messageID: first.messageID,
                position: first.position,
                meetingID: first.groupingKey,
                sessionID: first.sessionID,
                title: first.title,
                startedAt: first.startedAt,
                summary: first.summary,
                passages: group.enumerated().map { passagePosition, item in
                    ChatSourcePassage(
                        id: "\(first.id):passage:\(passagePosition)",
                        position: passagePosition,
                        start: item.start,
                        end: item.end,
                        text: item.text,
                        speakers: item.speakers
                    )
                }
            )
            try insert(source, db: db)
        }
    }

    private static func insert(_ source: ChatSourceRecord, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO chatSources
                    (id, messageID, position, meetingID, sessionID, title, startedAt, summary)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                source.id, source.messageID, source.position, source.meetingID,
                source.sessionID, source.title, source.startedAt, source.summary,
            ]
        )
        for passage in source.passages {
            try db.execute(
                sql: """
                    INSERT INTO chatSourcePassages
                        (id, sourceID, position, start, end, text, speakers)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    passage.id, source.id, passage.position, passage.start,
                    passage.end, passage.text, passage.speakers,
                ]
            )
        }
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

    // MARK: - Conversations

    func chatMessages(for sessionID: UUID) throws -> [ChatMessageRecord] {
        try chatMessages(for: .meeting(sessionID))
    }

    func chatMessages(for scope: ConversationScope) throws -> [ChatMessageRecord] {
        try queue.read { db in
            try ChatMessageRecord
                .filter(Column("conversationID") == scope.conversationID)
                .order(Column("position"))
                .fetchAll(db)
        }
    }

    func appendChatMessage(_ message: ChatMessageRecord, scope: ConversationScope) throws {
        guard message.conversationID == scope.conversationID else {
            throw AppDatabaseError.invalidConversationID
        }
        try queue.write { db in
            try Self.ensureConversation(scope, db: db)
            try message.insert(db)
        }
    }

    /// Stores an assistant turn and the exact evidence it cited in one transaction.
    /// This keeps source rows from ever getting ahead of, or detached from, the
    /// answer visible in the conversation.
    @discardableResult
    func appendAssistantMessage(
        _ message: ChatMessageRecord,
        scope: ConversationScope,
        evidence: [MeetingEvidence]
    ) throws -> [ChatSourceRecord] {
        guard message.conversationID == scope.conversationID,
              message.role == .assistant else {
            throw AppDatabaseError.invalidConversationID
        }
        let sources = evidence.enumerated().map { position, item in
            ChatSourceRecord(
                id: "\(message.id.uuidString):\(item.sessionID.uuidString)",
                messageID: message.id,
                position: position,
                meetingID: item.sessionID.uuidString,
                sessionID: item.sessionID,
                title: item.title,
                startedAt: item.startedAt,
                summary: item.summary,
                passages: item.passages.enumerated().map { passagePosition, passage in
                    ChatSourcePassage(
                        id: "\(message.id.uuidString):\(item.sessionID.uuidString):\(passagePosition)",
                        position: passagePosition,
                        start: passage.start,
                        end: passage.end,
                        text: passage.text,
                        speakers: passage.speakers
                    )
                }
            )
        }
        try queue.write { db in
            try Self.ensureConversation(scope, db: db)
            try message.insert(db)
            for source in sources { try Self.insert(source, db: db) }
        }
        return sources
    }

    func chatSources(for scope: ConversationScope) throws -> [ChatSourceRecord] {
        try queue.read { db in
            let sourceRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT chatSources.*
                    FROM chatSources
                    JOIN chatMessages ON chatMessages.id = chatSources.messageID
                    WHERE chatMessages.conversationID = ?
                    ORDER BY chatMessages.position, chatSources.position
                """,
                arguments: [scope.conversationID]
            )
            let passageRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT chatSourcePassages.*
                    FROM chatSourcePassages
                    JOIN chatSources ON chatSources.id = chatSourcePassages.sourceID
                    JOIN chatMessages ON chatMessages.id = chatSources.messageID
                    WHERE chatMessages.conversationID = ?
                    ORDER BY chatMessages.position, chatSources.position, chatSourcePassages.position
                    """,
                arguments: [scope.conversationID]
            )
            let passagesBySourceID = Dictionary(grouping: passageRows, by: { $0["sourceID"] as String })
            return sourceRows.map { row in
                let sourceID: String = row["id"]
                return ChatSourceRecord(
                    id: sourceID,
                    messageID: row["messageID"],
                    position: row["position"],
                    meetingID: row["meetingID"],
                    sessionID: row["sessionID"],
                    title: row["title"],
                    startedAt: row["startedAt"],
                    summary: row["summary"],
                    passages: (passagesBySourceID[sourceID] ?? []).map { passage in
                        ChatSourcePassage(
                            id: passage["id"],
                            position: passage["position"],
                            start: passage["start"],
                            end: passage["end"],
                            text: passage["text"],
                            speakers: passage["speakers"]
                        )
                    }
                )
            }
        }
    }

    func appendChatMessage(_ message: ChatMessageRecord) throws {
        let scope: ConversationScope
        if message.conversationID == ConversationScope.allMeetingsID {
            scope = .allMeetings
        } else if let meetingID = UUID(uuidString: message.conversationID) {
            scope = .meeting(meetingID)
        } else {
            throw AppDatabaseError.invalidConversationID
        }
        try appendChatMessage(message, scope: scope)
    }

    /// Removes the whole conversation about one meeting, leaving the meeting alone.
    func deleteChatMessages(for sessionID: UUID) throws {
        try deleteChatMessages(for: .meeting(sessionID))
    }

    func deleteChatMessages(for scope: ConversationScope) throws {
        try queue.write { db in
            _ = try ChatMessageRecord
                .filter(Column("conversationID") == scope.conversationID)
                .deleteAll(db)
        }
    }

    private static func ensureConversation(_ scope: ConversationScope, db: Database) throws {
        switch scope {
        case .allMeetings:
            try db.execute(
                sql: "INSERT INTO conversations (id, kind, sessionID) VALUES (?, 'allMeetings', NULL) ON CONFLICT(id) DO NOTHING",
                arguments: [scope.conversationID]
            )
        case .meeting(let sessionID):
            try db.execute(
                sql: "INSERT INTO conversations (id, kind, sessionID) VALUES (?, 'meeting', ?) ON CONFLICT(id) DO NOTHING",
                // Session UUIDs use GRDB's native representation; conversation IDs
                // stay text so the all-meetings sentinel and meeting IDs share one
                // stable key type without weakening the session foreign key.
                arguments: [scope.conversationID, sessionID]
            )
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

    /// Passage-sized evidence for the all-meetings conversation.
    ///
    /// The membership test lives in SQL rather than at the prompt call site: a
    /// dictation or unfinished recording cannot accidentally become model context.
    func meetingPassageEvidence(
        matching query: String,
        within timeRange: DateInterval? = nil,
        limit: Int = 24
    ) throws -> [MeetingPassageEvidence] {
        guard let pattern = MeetingCorpusSearch.ftsPattern(for: query) else { return [] }
        return try queue.read { db in
            var rangeSQL = ""
            var arguments: [any DatabaseValueConvertible] = [
                pattern, WorkflowKind.meeting, SessionState.completed,
            ]
            if let timeRange {
                rangeSQL = "AND sessions.startedAt >= ? AND sessions.startedAt < ?"
                arguments.append(timeRange.start)
                arguments.append(timeRange.end)
            }
            arguments.append(limit)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        meetingPassageSearch.passageID,
                        meetingPassageSearch.sessionID,
                        meetingPassageSearch.start,
                        meetingPassageSearch.end,
                        meetingPassageSearch.body,
                        meetingPassageSearch.speakers,
                        sessions.title,
                        sessions.startedAt,
                        sessions.summary
                    FROM meetingPassageSearch
                    JOIN sessions ON sessions.id = meetingPassageSearch.sessionID
                    WHERE meetingPassageSearch MATCH ?
                      AND sessions.kind = ?
                      AND sessions.state = ?
                      \(rangeSQL)
                    ORDER BY bm25(meetingPassageSearch, 0, 0, 0, 0, 0, 1, 2), sessions.startedAt DESC
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments)
            )
            return rows.map(Self.meetingPassage)
        }
    }

    /// Every current transcript passage eligible for a planned corpus query.
    /// Unlike top-k retrieval this is also the source for semantic indexing and
    /// exhaustive questions, so its date constraint is applied in SQL first.
    func meetingPassages(within timeRange: DateInterval? = nil) throws -> [MeetingPassageEvidence] {
        try queue.read { db in
            var rangeSQL = ""
            var arguments: [any DatabaseValueConvertible] = [
                WorkflowKind.meeting, SessionState.completed,
            ]
            if let timeRange {
                rangeSQL = "AND sessions.startedAt >= ? AND sessions.startedAt < ?"
                arguments.append(timeRange.start)
                arguments.append(timeRange.end)
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT meetingPassageSearch.passageID, meetingPassageSearch.sessionID,
                           meetingPassageSearch.start, meetingPassageSearch.end,
                           meetingPassageSearch.body, meetingPassageSearch.speakers,
                           sessions.title, sessions.startedAt, sessions.summary
                    FROM meetingPassageSearch
                    JOIN sessions ON sessions.id = meetingPassageSearch.sessionID
                    WHERE sessions.kind = ? AND sessions.state = ?
                      \(rangeSQL)
                    ORDER BY sessions.startedAt DESC, CAST(meetingPassageSearch.position AS INTEGER)
                    """,
                arguments: StatementArguments(arguments)
            )
            return rows.map(Self.meetingPassage)
        }
    }

    func meetingIDsMatchingMetadata(
        _ query: String,
        within timeRange: DateInterval? = nil,
        limit: Int = 12
    ) throws -> [UUID] {
        guard let pattern = MeetingCorpusSearch.ftsPattern(for: query) else { return [] }
        return try queue.read { db in
            var rangeSQL = ""
            var arguments: [any DatabaseValueConvertible] = [
                pattern, WorkflowKind.meeting, SessionState.completed,
            ]
            if let timeRange {
                rangeSQL = "AND sessions.startedAt >= ? AND sessions.startedAt < ?"
                arguments.append(timeRange.start)
                arguments.append(timeRange.end)
            }
            arguments.append(limit)
            return try UUID.fetchAll(
                db,
                sql: """
                    SELECT meetingMetadataSearch.sessionID
                    FROM meetingMetadataSearch
                    JOIN sessions ON sessions.id = meetingMetadataSearch.sessionID
                    WHERE meetingMetadataSearch MATCH ?
                      AND sessions.kind = ? AND sessions.state = ?
                      \(rangeSQL)
                    ORDER BY bm25(meetingMetadataSearch, 0, 5, 2, 3), sessions.startedAt DESC
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    func meetingPassages(ids: [String]) throws -> [MeetingPassageEvidence] {
        guard !ids.isEmpty else { return [] }
        return try queue.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT meetingPassageSearch.passageID, meetingPassageSearch.sessionID,
                           meetingPassageSearch.start, meetingPassageSearch.end,
                           meetingPassageSearch.body, meetingPassageSearch.speakers,
                           sessions.title, sessions.startedAt, sessions.summary
                    FROM meetingPassageSearch
                    JOIN sessions ON sessions.id = meetingPassageSearch.sessionID
                    WHERE meetingPassageSearch.passageID IN (\(placeholders))
                      AND sessions.kind = ? AND sessions.state = ?
                    """,
                arguments: StatementArguments(
                    ids.map { $0 as any DatabaseValueConvertible }
                        + [WorkflowKind.meeting, SessionState.completed]
                )
            )
            let byID = Dictionary(uniqueKeysWithValues: rows.map { row in
                let passage = Self.meetingPassage(row)
                return (passage.id, passage)
            })
            return ids.compactMap { byID[$0] }
        }
    }

    func meetingEmbeddingRows(
        model: String,
        within timeRange: DateInterval? = nil
    ) throws -> [MeetingStoredEmbedding] {
        try queue.read { db in
            var rangeSQL = ""
            var arguments: [any DatabaseValueConvertible] = [model]
            if let timeRange {
                rangeSQL = "AND sessions.startedAt >= ? AND sessions.startedAt < ?"
                arguments.append(timeRange.start)
                arguments.append(timeRange.end)
            }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT meetingPassageEmbeddings.*
                    FROM meetingPassageEmbeddings
                    JOIN sessions ON sessions.id = meetingPassageEmbeddings.sessionID
                    WHERE meetingPassageEmbeddings.model = ?
                      AND sessions.kind = 'meeting' AND sessions.state = 'completed'
                      \(rangeSQL)
                    """,
                arguments: StatementArguments(arguments)
            ).map {
                MeetingStoredEmbedding(
                    passageID: $0["passageID"],
                    sessionID: $0["sessionID"],
                    model: $0["model"],
                    textHash: $0["textHash"],
                    dimensions: $0["dimensions"],
                    vector: $0["vector"]
                )
            }
        }
    }

    func storeMeetingEmbeddings(_ embeddings: [MeetingStoredEmbedding]) throws {
        guard !embeddings.isEmpty else { return }
        try queue.write { db in
            for embedding in embeddings {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT sessionID, body FROM meetingPassageSearch WHERE passageID = ?",
                    arguments: [embedding.passageID]
                ) else { continue }
                let sessionID: UUID = row["sessionID"]
                let body: String = row["body"]
                guard sessionID == embedding.sessionID,
                      MeetingSemanticIndex.textHash(body) == embedding.textHash else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO meetingPassageEmbeddings
                            (passageID, sessionID, model, textHash, dimensions, vector, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(passageID, model) DO UPDATE SET
                            sessionID = excluded.sessionID,
                            textHash = excluded.textHash,
                            dimensions = excluded.dimensions,
                            vector = excluded.vector,
                            updatedAt = excluded.updatedAt
                        """,
                    arguments: [
                        embedding.passageID, embedding.sessionID, embedding.model,
                        embedding.textHash, embedding.dimensions, embedding.vector, Date(),
                    ]
                )
            }
        }
    }

    private static func meetingPassage(_ row: Row) -> MeetingPassageEvidence {
        MeetingPassageEvidence(
            id: row["passageID"],
            sessionID: row["sessionID"],
            title: row["title"],
            startedAt: row["startedAt"],
            summary: row["summary"],
            start: Double(row["start"] as String) ?? 0,
            end: Double(row["end"] as String) ?? 0,
            text: row["body"],
            speakers: row["speakers"]
        )
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
            try db.execute(sql: "DELETE FROM meetingPassageSearch WHERE sessionID = ?", arguments: [id])
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
        try queue.write { db in
            _ = try ChatMessageRecord.deleteAll(db)
            try db.execute(sql: "DELETE FROM conversations WHERE kind = 'meeting'")
            try Self.ensureConversation(.allMeetings, db: db)
        }
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
        guard let session = try SessionRecord.fetchOne(db, key: sessionID) else {
            try db.execute(sql: "DELETE FROM sessionSearch WHERE sessionID = ?", arguments: [sessionID])
            if try db.tableExists("meetingPassageSearch") {
                try db.execute(sql: "DELETE FROM meetingPassageSearch WHERE sessionID = ?", arguments: [sessionID])
            }
            if try db.tableExists("meetingMetadataSearch") {
                try db.execute(sql: "DELETE FROM meetingMetadataSearch WHERE sessionID = ?", arguments: [sessionID])
            }
            if try db.tableExists("meetingPassageEmbeddings") {
                try db.execute(sql: "DELETE FROM meetingPassageEmbeddings WHERE sessionID = ?", arguments: [sessionID])
            }
            return
        }
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
        guard try db.tableExists("meetingPassageSearch") else { return }
        try db.execute(sql: "DELETE FROM meetingPassageSearch WHERE sessionID = ?", arguments: [sessionID])
        if try db.tableExists("meetingMetadataSearch") {
            try db.execute(sql: "DELETE FROM meetingMetadataSearch WHERE sessionID = ?", arguments: [sessionID])
        }
        if try db.tableExists("meetingPassageEmbeddings") {
            // Passage text is the source of an embedding. Invalidate the complete
            // meeting atomically with transcript edits; the semantic indexer will
            // refill only current passage hashes.
            try db.execute(sql: "DELETE FROM meetingPassageEmbeddings WHERE sessionID = ?", arguments: [sessionID])
        }
        guard session.kind == .meeting, session.state == .completed else { return }
        if try db.tableExists("meetingMetadataSearch") {
            try db.execute(
                sql: "INSERT INTO meetingMetadataSearch (sessionID, title, speakers, summary) VALUES (?, ?, ?, ?)",
                arguments: [
                    sessionID,
                    session.title,
                    Set(segments.map(\.speaker)).sorted().joined(separator: " "),
                    session.summary ?? "",
                ]
            )
        }
        for passage in MeetingPassageBuilder.build(from: segments) {
            try db.execute(
                sql: """
                    INSERT INTO meetingPassageSearch
                        (passageID, sessionID, position, start, end, body, speakers)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "\(sessionID.uuidString):\(passage.position)",
                    sessionID,
                    passage.position,
                    String(passage.start),
                    String(passage.end),
                    passage.text,
                    passage.speakers,
                ]
            )
        }
    }
}

private enum AppDatabaseError: Error {
    case invalidConversationID
}
