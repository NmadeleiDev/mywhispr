import Foundation
import Testing
@testable import MyWhispr

@Suite("Meeting row status")
struct SessionRowStatusTests {
    @Test("A completed meeting shows when its notes are being written")
    func summaryGenerationIsVisibleOnItsMeeting() {
        #expect(SessionRowStatus(sessionState: .completed, isGeneratingSummary: true) == .writingNotes)
        #expect(SessionRowStatus(sessionState: .completed, isGeneratingSummary: false) == nil)
    }

    @Test("Recording lifecycle status takes precedence over note generation")
    func lifecycleStatusRemainsAuthoritative() {
        #expect(SessionRowStatus(sessionState: .recording, isGeneratingSummary: true) == .recording)
        #expect(SessionRowStatus(sessionState: .processing, isGeneratingSummary: true) == .processing)
        #expect(SessionRowStatus(sessionState: .failed, isGeneratingSummary: true) == .failed)
        #expect(SessionRowStatus(sessionState: .interrupted, isGeneratingSummary: true) == .interrupted)
    }
}
