import Foundation
import Testing
@testable import MyWhispr

@Suite("Dictation tidying")
struct DisfluencyFilterTests {
    // MARK: - The real transcripts this was built from

    @Test("Cleans an actual dictated sentence")
    func realTranscript() {
        #expect(
            DisfluencyFilter.apply(to: "I mean we can uh git ignore the u x directory at all.")
                == "I mean we can git ignore the u x directory at all."
        )
    }

    @Test("Repairs a false start marked with a trailing hyphen")
    func hyphenatedFalseStart() {
        #expect(
            DisfluencyFilter.apply(to: "I don't want to re- rewrite it uh wholesale.")
                == "I don't want to rewrite it wholesale."
        )
    }

    // MARK: - Fillers

    @Test("Removes filler sounds wherever they appear")
    func removesFillers() {
        #expect(DisfluencyFilter.apply(to: "So um we should go") == "So we should go")
        #expect(DisfluencyFilter.apply(to: "That is er fine") == "That is fine")
        #expect(DisfluencyFilter.apply(to: "Well hmm maybe") == "Well maybe")
    }

    @Test("Takes the punctuation that belonged to the filler with it")
    func removesStrandedPunctuation() {
        // Capitalisation is not this type's job — `TextCleaner` owns it, and having
        // two passes decide the same thing is how they start disagreeing.
        #expect(DisfluencyFilter.apply(to: "Uh, so we can ship it.") == "so we can ship it.")
    }

    @Test("Composed with the cleaner, as the app composes them, the sentence is whole")
    func composesWithTheCleaner() {
        let tidied = DisfluencyFilter.apply(to: "Uh, so we can ship it")
        #expect(TextCleaner.clean(tidied) == "So we can ship it.")
    }

    @Test("Removes Russian filler sounds too")
    func removesRussianFillers() {
        #expect(DisfluencyFilter.apply(to: "Ну э давай сделаем это") == "Ну давай сделаем это")
    }

    @Test("Leaves real words that merely resemble fillers")
    func doesNotEatRealWords() {
        // "Erm" is a filler; "ermine", "hum" and "ummm" spelled as words are not.
        #expect(DisfluencyFilter.apply(to: "The ermine hums softly") == "The ermine hums softly")
    }

    // MARK: - Stutters

    @Test("Collapses a word repeated immediately")
    func collapsesStutters() {
        #expect(DisfluencyFilter.apply(to: "maybe just just polish a bit") == "maybe just polish a bit")
        #expect(DisfluencyFilter.apply(to: "I I think so") == "I think so")
        #expect(DisfluencyFilter.apply(to: "the the file") == "the file")
    }

    @Test("Keeps the first occurrence, so capitalisation survives")
    func keepsFirstCasing() {
        #expect(DisfluencyFilter.apply(to: "The the file") == "The file")
    }

    @Test("Leaves words English genuinely doubles")
    func protectsLegitimateDoubles() {
        #expect(DisfluencyFilter.apply(to: "I had had enough") == "I had had enough")
        #expect(DisfluencyFilter.apply(to: "that that thing is odd") == "that that thing is odd")
        #expect(DisfluencyFilter.apply(to: "it was very very good") == "it was very very good")
    }

    @Test("A repetition across punctuation is emphasis, not a stutter")
    func punctuationMeansEmphasis() {
        #expect(DisfluencyFilter.apply(to: "Stop, stop!") == "Stop, stop!")
    }

    // MARK: - False starts

    @Test("Drops an abandoned fragment restarted as a longer word")
    func repairsFalseStarts() {
        #expect(DisfluencyFilter.apply(to: "we need trans transcription") == "we need transcription")
        #expect(DisfluencyFilter.apply(to: "the conf- configuration file") == "the configuration file")
    }

    @Test("A real short word is never mistaken for a fragment")
    func protectsRealShortWords() {
        #expect(DisfluencyFilter.apply(to: "look in inside the box") == "look in inside the box")
        #expect(DisfluencyFilter.apply(to: "it is a about time") == "it is a about time")
        #expect(DisfluencyFilter.apply(to: "he can cancel it") == "he can cancel it")
    }

    @Test("An explicit truncation is repaired even when it spells a real word")
    func hyphenOverridesTheWordList() {
        // The trailing hyphen is the model stating the word was cut off, which beats
        // any guess made from the letters alone.
        #expect(DisfluencyFilter.apply(to: "the in- interface is ready") == "the interface is ready")
    }

    // MARK: - Safety properties

    @Test("The result is always a subsequence of what was said")
    func onlyEverDeletes() {
        let inputs = [
            "I mean we can uh git ignore the u x directory at all.",
            "I don't want to re- rewrite it uh wholesale.",
            "maybe just just polish a bit",
            "Uh, so we can ship it.",
            "Ну э давай сделаем это",
        ]
        for input in inputs {
            let output = DisfluencyFilter.apply(to: input)
            let originalWords = input.split(whereSeparator: \.isWhitespace).map {
                $0.trimmingCharacters(in: .punctuationCharacters).lowercased()
            }
            var remaining = originalWords[...]
            for word in output.split(whereSeparator: \.isWhitespace).map({
                $0.trimmingCharacters(in: .punctuationCharacters).lowercased()
            }) {
                guard let match = remaining.firstIndex(of: word) else {
                    Issue.record("“\(word)” is not in the original: \(input)")
                    break
                }
                remaining = remaining[remaining.index(after: match)...]
            }
        }
    }

    @Test("Text with nothing to fix is returned unchanged")
    func cleanTextIsUntouched() {
        let text = "The quick brown fox jumps over the lazy dog."
        #expect(DisfluencyFilter.apply(to: text) == text)
    }

    @Test("Empty and whitespace-only input is handled")
    func handlesEmptyInput() {
        #expect(DisfluencyFilter.apply(to: "") == "")
        #expect(DisfluencyFilter.apply(to: "   ") == "   ")
    }

    @Test("A dictation that is nothing but fillers collapses to nothing")
    func allFillers() {
        #expect(DisfluencyFilter.apply(to: "uh um er").isEmpty)
    }
}
