import Foundation
import Testing
@testable import MyWhispr

@Suite("Vocabulary correction")
struct VocabularyCorrectorTests {
    @Test("Leaves text untouched when no words are configured")
    func noTermsIsIdentity() {
        let text = "The quick brown fox."
        #expect(VocabularyCorrector.apply([], to: text) == text)
    }

    @Test("Fixes the spelling of a mangled name")
    func repairsNearMiss() {
        let corrected = VocabularyCorrector.apply(["Kubernetes"], to: "We deployed to kubernetis today.")
        #expect(corrected == "We deployed to Kubernetes today.")
    }

    @Test("Fixes capitalisation even on an exact match")
    func normalisesCasing() {
        let corrected = VocabularyCorrector.apply(["OpenWhispr"], to: "openwhispr is the other app.")
        #expect(corrected == "OpenWhispr is the other app.")
    }

    @Test("Keeps the punctuation that surrounded the word")
    func preservesPunctuation() {
        let corrected = VocabularyCorrector.apply(["Anthropic"], to: "Ask anthropick, then stop.")
        #expect(corrected == "Ask Anthropic, then stop.")
    }

    @Test("Matches a multi-word term across the words it spans")
    func multiWordTerm() {
        let corrected = VocabularyCorrector.apply(["Neural Engine"], to: "It runs on the nueral engine.")
        #expect(corrected == "It runs on the Neural Engine.")
    }

    @Test("A model-inserted word boundary does not change an expression's identity")
    func joinsASRSplitTerms() {
        let corrected = VocabularyCorrector.apply(
            ["posthog", "glitchtip", "n8n"],
            to: "Use post hoc, check glitch tip, then n 8 n."
        )
        #expect(corrected == "Use posthog, check glitchtip, then n8n.")
    }

    @Test("A model-removed word boundary is restored from the configured spelling")
    func restoresConfiguredWordBoundaries() {
        let corrected = VocabularyCorrector.apply(["Claude Code"], to: "Ask claudecode about it.")
        #expect(corrected == "Ask Claude Code about it.")
    }

    @Test("A boundary-insensitive match keeps punctuation outside the expression")
    func boundaryMatchPreservesSurroundingPunctuation() {
        let corrected = VocabularyCorrector.apply(["PostHog"], to: "Try (post hoc), please.")
        #expect(corrected == "Try (PostHog), please.")
    }

    @Test("A match never consumes punctuation as if it were a word boundary")
    func boundaryMatchDoesNotCrossPunctuation() {
        let text = "This is a post, hoc analysis."
        #expect(VocabularyCorrector.apply(["PostHog"], to: text) == text)
    }

    @Test("Two configured spellings with the same compact identity are ambiguous")
    func compactIdentityAmbiguityIsNotGuessed() {
        let text = "Open post hog now."
        #expect(VocabularyCorrector.apply(["PostHog", "Post Hog"], to: text) == text)
    }

    @Test("The longest eligible expression wins across an inserted boundary")
    func longestBoundaryMatchWins() {
        let corrected = VocabularyCorrector.apply(["Post", "PostHog"], to: "Open post hog now.")
        #expect(corrected == "Open PostHog now.")
    }

    @Test("Whole expressions beat their components while equal overlaps stay ambiguous")
    func expressionPriorityAndOverlapAmbiguity() {
        let splitTerms = VocabularyCorrector.apply(
            ["Post", "Hog", "PostHog"],
            to: "Open post hog now."
        )
        let shiftedTerms = VocabularyCorrector.apply(
            ["New York", "York New"],
            to: "new york new"
        )
        #expect(splitTerms == "Open PostHog now.")
        #expect(shiftedTerms == "new york new")
    }

    @Test("Equivalent component terms do not make a whole expression ambiguous")
    func equivalentComponentTermsHaveOneVisibleResult() {
        let corrected = VocabularyCorrector.apply(
            ["New York", "New", "York"],
            to: "Meet me in new york."
        )
        #expect(corrected == "Meet me in New York.")
    }

    @Test("Shifted overlapping phrases that make the same edit are not ambiguous")
    func shiftedEquivalentPhrasesHaveOneVisibleResult() {
        let corrected = VocabularyCorrector.apply(
            ["check PostHog", "PostHog analytics"],
            to: "check posthog analytics"
        )
        #expect(corrected == "check PostHog analytics")
    }

    @Test("Equivalent insertion evidence inserts the missing word only once")
    func equivalentInsertionsComposeOnce() {
        let corrected = VocabularyCorrector.apply(
            ["Post X", "X analytics"],
            to: "Post analytics"
        )
        #expect(corrected == "Post X analytics")
    }

    @Test("An ambiguous overlap does not suppress an independent correction")
    func ambiguityStaysLocal() {
        let corrected = VocabularyCorrector.apply(
            ["New York", "York New", "Kubernetes"],
            to: "new york new and kubernetis"
        )
        #expect(corrected == "new york new and Kubernetes")
    }

    @Test("An exact component outranks a fuzzy compound")
    func exactEvidenceOutranksFuzzyCoverage() {
        let corrected = VocabularyCorrector.apply(
            ["Post", "PostHog"],
            to: "Open post hock now."
        )
        #expect(corrected == "Open Post hock now.")
    }

    @Test("A boundary match does not consume a neighbouring word")
    func boundaryMatchStopsAtTheExpressionOnBothSides() {
        let corrected = VocabularyCorrector.apply(
            ["posthog", "OpenWhispr", "glitchtip"],
            to: "Why a post hog API? The open whispr is ready; check my glitch tip dashboard."
        )
        #expect(
            corrected
                == "Why a posthog API? The OpenWhispr is ready; check my glitchtip dashboard."
        )
    }

    @Test("A short term never swallows a similar ordinary word")
    func shortTermsRequireAnExactMatch() {
        // "Sam" and "same" are one edit apart. Correcting that would rewrite a
        // sentence the owner actually said.
        let corrected = VocabularyCorrector.apply(["Sam"], to: "It is the same thing.")
        #expect(corrected == "It is the same thing.")
    }

    @Test("A word that resembles nothing configured is left alone")
    func unrelatedWordsSurvive() {
        let text = "Completely ordinary sentence about carpentry."
        #expect(VocabularyCorrector.apply(["Kubernetes", "Anthropic"], to: text) == text)
    }

    @Test("Two equally close terms are treated as ambiguous and neither is applied")
    func ambiguityIsNotGuessed() {
        // "Marten" and "Martin" are each exactly one edit from "martan"; picking one
        // would be a coin flip written into a transcript.
        let corrected = VocabularyCorrector.apply(["Marten", "Martin"], to: "Then martan spoke.")
        #expect(corrected == "Then martan spoke.")
    }

    @Test("Unequal spelling lengths do not break an equal-distance tie")
    func ambiguityDoesNotPreferTheLongerSpelling() {
        let corrected = VocabularyCorrector.apply(
            ["PostHog", "PostHogs"],
            to: "Open posthogx now."
        )
        #expect(corrected == "Open posthogx now.")
    }

    @Test("Corrects every segment as well as the joined text")
    func appliesToSegments() {
        let result = TranscriptionResult(
            text: "kubernetis and anthropick near post hoc",
            detectedLanguage: nil,
            segments: [
                TranscriptSegment(
                    id: UUID(), start: 0, end: 1, text: "kubernetis",
                    speaker: "You", channel: .microphone
                ),
                TranscriptSegment(
                    id: UUID(), start: 1, end: 2, text: "anthropick",
                    speaker: "You", channel: .microphone
                ),
                TranscriptSegment(
                    id: UUID(), start: 2, end: 3, text: "post hoc",
                    speaker: "You", channel: .microphone
                ),
            ]
        )
        let corrected = VocabularyCorrector.apply(["Kubernetes", "Anthropic", "PostHog"], to: result)
        #expect(corrected.text == "Kubernetes and Anthropic near PostHog")
        #expect(corrected.segments.map(\.text) == ["Kubernetes", "Anthropic", "PostHog"])
    }

    @Test("Words containing apostrophes and hyphens stay whole")
    func wordsKeepTheirInternalPunctuation() {
        let text = "Don't touch the half-life value."
        #expect(VocabularyCorrector.apply(["Kubernetes"], to: text) == text)
    }

    @Test("Blank and duplicate entries are ignored")
    func ignoresEmptyEntries() {
        let corrected = VocabularyCorrector.apply(
            ["", "   ", "Kubernetes", "kubernetes"],
            to: "one kubernetis here"
        )
        #expect(corrected == "one Kubernetes here")
    }

    @Test("Edit distance stops counting once it passes the limit")
    func distanceRespectsItsLimit() {
        #expect(VocabularyCorrector.editDistance("kitten", "sitting", limit: 5) == 3)
        #expect(VocabularyCorrector.editDistance("kitten", "sitting", limit: 1) == 2)
        #expect(VocabularyCorrector.editDistance("same", "same", limit: 1) == 0)
    }

    @Test("Tokenizing round-trips the original text exactly")
    func tokenizingIsLossless() {
        let text = "  Hello, world — it's 42 half-life…  "
        #expect(WordTokens.join(WordTokens.split(text)) == text)
    }
}
