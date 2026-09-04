import AppKit
import SwiftUI
import Testing
@testable import MyWhispr

@Suite("Main workspace rendering", .serialized)
@MainActor
struct UIRenderTests {
    @Test func meetingDetailSelectionSurvivesRefreshesOfTheSameMeeting() {
        let firstMeeting = UUID()
        let secondMeeting = UUID()
        var selection = MeetingDetailSelection()

        let loadedFirstMeeting = selection.load(sessionID: firstMeeting)
        #expect(loadedFirstMeeting)
        selection.select(.notes)

        let reloadedNotes = selection.load(sessionID: firstMeeting)
        #expect(!reloadedNotes)
        #expect(selection.mode == .notes)

        selection.select(.ask)
        let reloadedAsk = selection.load(sessionID: firstMeeting)
        #expect(!reloadedAsk)
        #expect(selection.mode == .ask)

        let loadedSecondMeeting = selection.load(sessionID: secondMeeting)
        #expect(loadedSecondMeeting)
        #expect(selection.mode == .transcript)
    }

    @Test func workspaceSurfacesRenderAtWindowSize() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/render-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFixture(at: root)
        let runtime = try AppRuntime(databaseRootURL: root)
        for (destination, filename) in [
            (MainWindow.InitialDestination.home, "mywhispr-home.png"),
            (.workspaceConversation, "mywhispr-conversation.png"),
            (.library, "mywhispr-library.png"),
        ] {
            try render(destination, runtime: runtime, filename: filename)
        }
    }

    @Test func summaryGeneratingMeetingRowRenders() throws {
        let now = Date()
        let session = SessionRecord(
            id: UUID(), kind: .meeting, title: "Product sync", state: .completed,
            startedAt: now, endedAt: now, duration: 2_626,
            sourceApplication: nil, sourceBundleIdentifier: nil,
            modelSnapshot: "{}", audioRelativePath: nil,
            summary: nil, errorMessage: nil,
            createdAt: now, updatedAt: now
        )
        try renderView(
            SessionRow(session: session, isSelected: false, isGeneratingSummary: true)
                .padding(.horizontal, 10)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark),
            size: NSSize(width: 320, height: 72),
            filename: "mywhispr-writing-notes-row.png"
        )
    }

    @Test func expandedMeetingSourceRendersSummaryFirst() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/render-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try AppRuntime(databaseRootURL: root)
        let meetingID = UUID()
        let messageID = UUID()
        let now = Date()
        let source = ChatSourceRecord(
            id: "\(messageID.uuidString):\(meetingID.uuidString)",
            messageID: messageID,
            position: 0,
            meetingID: meetingID.uuidString,
            sessionID: meetingID,
            title: "Product sync",
            startedAt: now,
            summary: "## Decision\nKeep the private beta to twenty teams.",
            passages: [ChatSourcePassage(
                id: "passage-0",
                position: 0,
                start: 42,
                end: 55,
                text: "[0:42] You: Keep the private beta to twenty teams.",
                speakers: "You"
            )]
        )
        try renderView(
            ChatSourceRow(source: source, runtime: runtime, initiallyExpanded: true)
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark),
            size: NSSize(width: 760, height: 260),
            filename: "mywhispr-expanded-source.png"
        )
    }

    private func render(
        _ destination: MainWindow.InitialDestination,
        runtime: AppRuntime,
        filename: String
    ) throws {
        let size = NSSize(width: 1_020, height: 660)
        try renderView(
            MainWindow(initialDestination: destination)
                .environment(runtime),
            size: size,
            filename: filename
        )
    }

    private func renderView<Content: View>(
        _ content: Content,
        size: NSSize,
        filename: String
    ) throws {
        let host = NSHostingView(
            rootView: content
                .frame(width: size.width, height: size.height)
        )
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        #expect(representation.size == size)

        // Kept in .build for the post-build visual evidence gate; it is never part
        // of the product or the owner's Application Support data.
        let png = try #require(representation.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: ".build/\(filename)"), options: .atomic)
    }

    private func makeFixture(at root: URL) throws {
        let database = try AppDatabase(rootURL: root)
        let now = Date()
        let session = SessionRecord(
            id: UUID(), kind: .meeting, title: "Product sync", state: .completed,
            startedAt: now, endedAt: now, duration: 2_526,
            sourceApplication: nil, sourceBundleIdentifier: nil,
            modelSnapshot: "{}", audioRelativePath: nil,
            summary: "Keep the private beta to twenty teams.", errorMessage: nil,
            createdAt: now, updatedAt: now
        )
        try database.insertSession(session)
        try database.replaceSegments([
            TranscriptSegmentRecord(
                id: UUID(), sessionID: session.id, position: 0, start: 0, end: 8,
                channel: .microphone, speaker: "You", originalText: "Move the public launch to October.",
                editedText: "Move the public launch to October."
            ),
        ], for: session)
        let scope = ConversationScope.allMeetings
        try database.appendChatMessage(
            ChatMessageRecord(
                id: UUID(), conversationID: scope.conversationID, position: 0,
                role: .user, content: "What did we decide about launch?", createdAt: now
            ),
            scope: scope
        )
        try database.appendAssistantMessage(
            ChatMessageRecord(
                id: UUID(), conversationID: scope.conversationID, position: 1,
                role: .assistant,
                content: "Keep the private beta to twenty teams and move the public launch to October [S1].",
                createdAt: now
            ),
            scope: scope,
            evidence: [MeetingEvidence(
                sessionID: session.id,
                title: session.title,
                startedAt: session.startedAt,
                summary: session.summary,
                passages: [MeetingPassageEvidence(
                    id: "\(session.id.uuidString):0",
                    sessionID: session.id,
                    title: session.title,
                    startedAt: session.startedAt,
                    summary: session.summary,
                    start: 0,
                    end: 8,
                    text: "[0:00] You: Move the public launch to October.",
                    speakers: "You"
                )]
            )]
        )
    }
}
