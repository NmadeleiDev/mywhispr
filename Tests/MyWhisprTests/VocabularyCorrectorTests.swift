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

    @Test("Corrects every segment as well as the joined text")
    func appliesToSegments() {
        let result = TranscriptionResult(
            text: "kubernetis and anthropick",
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
            ]
        )
        let corrected = VocabularyCorrector.apply(["Kubernetes", "Anthropic"], to: result)
        #expect(corrected.text == "Kubernetes and Anthropic")
        #expect(corrected.segments.map(\.text) == ["Kubernetes", "Anthropic"])
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
        let tokens = VocabularyCorrector.tokenize(text)
        #expect(tokens.map(\.text).joined() == text)
    }
}
