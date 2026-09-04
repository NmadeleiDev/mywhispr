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

    @Test("Automatic summaries wait for the model and run in meeting order")
    func queuesAutomaticSummaries() {
        let manual = UUID()
        let firstAutomatic = UUID()
        let secondAutomatic = UUID()
        var state = SummaryGenerationState()
        let startedManual = state.start(for: manual)
        #expect(startedManual)

        let startedFirstImmediately = state.startAutomatically(for: firstAutomatic)
        let startedSecondImmediately = state.startAutomatically(for: secondAutomatic)
        let startedDuplicateImmediately = state.startAutomatically(for: firstAutomatic)
        #expect(!startedFirstImmediately)
        #expect(!startedSecondImmediately)
        #expect(!startedDuplicateImmediately)

        let firstNext = state.finish(for: manual)
        #expect(firstNext == firstAutomatic)
        #expect(state.isGenerating(for: firstAutomatic))
        let secondNext = state.finish(for: firstAutomatic)
        #expect(secondNext == secondAutomatic)
        #expect(state.isGenerating(for: secondAutomatic))
        let noNext = state.finish(for: secondAutomatic)
        #expect(noNext == nil)
        #expect(!state.isActive)
    }

    @Test("An automatic summary starts immediately when the model is free")
    func startsAutomaticSummaryImmediately() {
        let meeting = UUID()
        var state = SummaryGenerationState()

        let startedImmediately = state.startAutomatically(for: meeting)

        #expect(startedImmediately)
        #expect(state.isGenerating(for: meeting))
    }

    @Test("Turning automatic summaries off discards only waiting work")
    func discardsAutomaticQueue() {
        let active = UUID()
        var state = SummaryGenerationState()
        let startedActive = state.start(for: active)
        let startedAutomaticImmediately = state.startAutomatically(for: UUID())
        #expect(startedActive)
        #expect(!startedAutomaticImmediately)

        state.discardAutomaticQueue()
        #expect(state.isGenerating(for: active))
        let noNext = state.finish(for: active)
        #expect(noNext == nil)
        #expect(!state.isActive)
    }
}

@Suite("Automatic meeting summary policy")
struct AutomaticMeetingSummaryPolicyTests {
    @Test func requiresOptInAndAConfiguredModel() {
        var configuration = LocalAIConfiguration()
        #expect(!AutomaticMeetingSummaryPolicy.shouldGenerate(
            enabled: true, configuration: configuration, existingSummary: nil
        ))

        configuration.summaryModel = "qwen3:8b"
        #expect(!AutomaticMeetingSummaryPolicy.shouldGenerate(
            enabled: false, configuration: configuration, existingSummary: nil
        ))
        #expect(AutomaticMeetingSummaryPolicy.shouldGenerate(
            enabled: true, configuration: configuration, existingSummary: nil
        ))
    }

    @Test func acceptsTheInheritedRewriteModelButPreservesExistingNotes() {
        var configuration = LocalAIConfiguration()
        configuration.model = "gemma3:4b"
        #expect(AutomaticMeetingSummaryPolicy.shouldGenerate(
            enabled: true, configuration: configuration, existingSummary: "  "
        ))
        #expect(!AutomaticMeetingSummaryPolicy.shouldGenerate(
            enabled: true, configuration: configuration, existingSummary: "Owner-edited notes"
        ))
    }
}
