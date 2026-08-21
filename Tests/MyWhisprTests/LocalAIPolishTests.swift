import Foundation
import Testing
@testable import MyWhispr

@Suite("Local AI polishing")
struct LocalAIPolishTests {
    // MARK: - Cleaning what a model returns

    @Test("A reasoning model's scratchpad never reaches the transcript")
    func stripsThinkingBlocks() {
        let raw = "<think>The user said uh, so I should remove it.</think>So we can ship it."
        #expect(LocalAIService.plainText(raw, fallback: "x") == "So we can ship it.")
    }

    @Test("Multi-line and alternative thinking tags are stripped too")
    func stripsMultilineThinking() {
        let raw = """
        <thinking>
        Line one.
        Line two.
        </thinking>
        The finished sentence.
        """
        #expect(LocalAIService.plainText(raw, fallback: "x") == "The finished sentence.")
    }

    @Test("Code fences are removed")
    func stripsCodeFences() {
        #expect(LocalAIService.plainText("```\nHello there.\n```", fallback: "x") == "Hello there.")
        #expect(LocalAIService.plainText("```text\nHello there.\n```", fallback: "x") == "Hello there.")
    }

    @Test("Quotation marks a model wrapped around its answer are removed")
    func stripsWrappingQuotes() {
        #expect(LocalAIService.plainText("\"So we can ship it.\"", fallback: "x") == "So we can ship it.")
        #expect(LocalAIService.plainText("“So we can ship it.”", fallback: "x") == "So we can ship it.")
    }

    @Test("A sentence that merely contains a quote keeps it")
    func keepsInternalQuotes() {
        let text = "He said \"no\" and left."
        #expect(LocalAIService.plainText(text, fallback: "x") == text)
    }

    @Test("An empty or thinking-only reply falls back to what was said")
    func fallsBackWhenNothingUsableComesBack() {
        #expect(LocalAIService.plainText("", fallback: "the original") == "the original")
        #expect(LocalAIService.plainText("   ", fallback: "the original") == "the original")
        #expect(LocalAIService.plainText("<think>hmm</think>", fallback: "the original") == "the original")
    }

    // MARK: - Rejecting a rewrite that is not a polish

    @Test("Tidying of the same sentence is accepted")
    func acceptsATidyUp() {
        let said = "I mean we can just git ignore the u x directory at all"
        let polished = "I mean we can just gitignore the .ux directory at all."
        #expect(LocalAIService.isPlausiblePolish(of: said, result: polished))
    }

    @Test("A summary of the dictation is rejected")
    func rejectsASummary() {
        let said = """
        So I was thinking that we should probably move the whole vocabulary list out \
        of the per workflow settings and into one shared place, because otherwise you \
        have to add every name twice and it silently does not work in whichever one \
        you forgot about.
        """
        #expect(!LocalAIService.isPlausiblePolish(of: said, result: "Move the vocabulary to a shared setting."))
    }

    @Test("A model that answers the dictation instead of cleaning it is rejected")
    func rejectsAnAnswer() {
        let said = "Which approaches exist out there to polish my message just a bit"
        let answer = """
        There are several approaches you could consider. First, rule-based filtering \
        removes filler words using a fixed lexicon. Second, you could suppress tokens \
        at decode time. Third, a local language model can rewrite the text. Each has \
        different trade-offs in latency and fidelity, and the right choice depends on \
        your requirements and how much you value determinism.
        """
        #expect(!LocalAIService.isPlausiblePolish(of: said, result: answer))
    }

    @Test("An empty result is never a polish")
    func rejectsEmptyResults() {
        #expect(!LocalAIService.isPlausiblePolish(of: "Something was said", result: ""))
    }

    @Test("A short dictation is judged by absolute change, not ratio")
    func shortDictationsGetLatitude() {
        // "Yes" to "Yes." is a 33% change by ratio and obviously fine.
        #expect(LocalAIService.isPlausiblePolish(of: "yes", result: "Yes."))
        #expect(LocalAIService.isPlausiblePolish(of: "uh ok", result: "Okay."))
    }

    // MARK: - The default instruction

    @Test("The default prompt forbids the transformations that are not polishing")
    func defaultPromptClosesTheLoopholes() {
        let prompt = LocalAIConfiguration.defaultRewritePrompt.lowercased()
        for forbidden in ["paraphrase", "summarise", "translate", "reorder", "shorten"] {
            #expect(prompt.contains(forbidden), "the prompt should rule out \(forbidden)")
        }
        #expect(prompt.contains("unchanged"))
        #expect(!prompt.contains("concise prose"))
    }

    @MainActor
    @Test("An install still on a retired default is moved to the current one")
    func migratesAnUneditedPrompt() throws {
        let suite = "MyWhisprTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var stored = SettingsStore.Payload()
        stored.localAI.rewritePrompt = try #require(LocalAIConfiguration.retiredRewritePrompts.first)
        defaults.set(try JSONEncoder().encode(stored), forKey: "settings.payload.v2")

        let store = SettingsStore(defaults: defaults)
        #expect(store.payload.localAI.rewritePrompt == LocalAIConfiguration.defaultRewritePrompt)
    }

    @MainActor
    @Test("A prompt the owner wrote themselves is left alone")
    func keepsACustomPrompt() throws {
        let suite = "MyWhisprTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var stored = SettingsStore.Payload()
        stored.localAI.rewritePrompt = "Translate everything into pirate speak."
        defaults.set(try JSONEncoder().encode(stored), forKey: "settings.payload.v2")

        let store = SettingsStore(defaults: defaults)
        #expect(store.payload.localAI.rewritePrompt == "Translate everything into pirate speak.")
    }
}
