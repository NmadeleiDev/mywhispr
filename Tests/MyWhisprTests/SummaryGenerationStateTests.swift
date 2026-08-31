import Foundation
import Testing
@testable import MyWhispr

@Suite("Summary generation ownership")
struct SummaryGenerationStateTests {
    @Test("Progress belongs only to the recording that started it")
    func scopesProgressToOneRecording() {
        let active = UUID()
        let other = UUID()
        var state = SummaryGenerationState()

        let started = state.start(for: active)
        #expect(started)
        #expect(state.isGenerating(for: active))
        #expect(!state.isGenerating(for: other))
        let startedOther = state.start(for: other)
        #expect(!startedOther)
    }

    @Test("A stale recording cannot clear another recording's progress")
    func finishesOnlyTheOwner() {
        let active = UUID()
        var state = SummaryGenerationState()
        let started = state.start(for: active)
        #expect(started)

        state.finish(for: UUID())
        #expect(state.isGenerating(for: active))

        state.finish(for: active)
        #expect(!state.isActive)
    }
}
