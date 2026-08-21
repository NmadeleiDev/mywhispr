import Foundation

/// Removes the noises of speaking from text that was meant to be written.
///
/// Dictation and a meeting transcript want opposite things here. A meeting is a
/// record of what someone said, and quietly deleting words from a record is wrong.
/// Dictation is composition — the "uh" was never meant to be text — so this runs on
/// dictation only. See ``AppRuntime``.
///
/// Every operation can only *delete*. Nothing here rewrites, reorders, or supplies a
/// word, so the result is always a subsequence of what was actually said. That is
/// the property that makes it safe to run without review: at worst it drops
/// something, and it can never put words in the owner's mouth.
enum DisfluencyFilter {
    /// The sounds people make while thinking. Written forms vary by model, so the
    /// common spellings of each are all listed.
    private static let fillers: Set<String> = [
        // English
        "uh", "uhh", "uhhh", "uhm", "um", "umm", "ummm",
        "er", "err", "erm", "mm", "mmm", "hm", "hmm", "hmmm", "mhm",
        // Russian
        "э", "ээ", "эээ", "эм", "эмм", "мм", "ммм",
    ]

    /// Words English genuinely doubles, which must survive the stutter pass.
    ///
    /// "I had had enough" and "very very good" are not stutters. The list is short on
    /// purpose: every entry is a word that repeats meaningfully often enough to be
    /// worth protecting, and everything else is far more likely to be a stumble.
    private static let legitimateDoubles: Set<String> = [
        "had", "that", "very", "no", "yes", "ha",
    ]

    /// Short real words that happen to be prefixes of longer ones, so "in inside"
    /// and "a about" are left alone while "re- rewrite" is repaired.
    private static let realShortWords: Set<String> = [
        "a", "i", "an", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is",
        "it", "me", "my", "no", "of", "on", "or", "so", "to", "up", "us", "we",
        "and", "the", "for", "but", "not", "you", "all", "can", "her", "him", "his",
        "out", "own", "see", "she", "too", "two", "use", "was", "way", "who", "why",
    ]

    static func apply(to text: String) -> String {
        let tokens = WordTokens.split(text)
        guard tokens.contains(where: \.isWord) else { return text }

        // Passes mark words for deletion rather than removing them, so no pass has
        // to reason about indices shifting under a previous one. Each pass sees the
        // words its predecessors left behind, which is what lets "just uh just"
        // become "just": the filler goes first, and the stutter is then adjacent.
        var keep = [Bool](repeating: true, count: tokens.count)
        removeFillers(tokens, &keep)
        collapseStutters(tokens, &keep)
        repairFalseStarts(tokens, &keep)
        dropOrphanedSpacing(tokens, &keep)

        let surviving = tokens.indices.filter { keep[$0] }.map { tokens[$0] }
        return tidyPunctuation(WordTokens.join(surviving))
    }

    // MARK: - Passes

    private static func removeFillers(_ tokens: [WordTokens.Token], _ keep: inout [Bool]) {
        for index in words(in: tokens, keep) where fillers.contains(WordTokens.folded(tokens[index])) {
            keep[index] = false
        }
    }

    /// Collapses a word repeated immediately after itself, keeping the first so the
    /// original capitalisation survives.
    private static func collapseStutters(_ tokens: [WordTokens.Token], _ keep: inout [Bool]) {
        let present = words(in: tokens, keep)
        for position in present.indices where position > 0 {
            let current = present[position]
            let previous = present[position - 1]
            let word = WordTokens.folded(tokens[current])
            guard !word.isEmpty,
                  keep[previous],
                  word == WordTokens.folded(tokens[previous]),
                  !legitimateDoubles.contains(word),
                  // Only an unbroken repetition is a stutter. "Stop, stop!" is
                  // emphasis and keeps its comma; "stop stop" is not.
                  separator(from: previous, to: current, in: tokens, keep).allSatisfy(\.isWhitespace)
            else { continue }
            keep[current] = false
        }
    }

    /// Drops an abandoned word restarted as a longer one: "re- rewrite" → "rewrite".
    private static func repairFalseStarts(_ tokens: [WordTokens.Token], _ keep: inout [Bool]) {
        let present = words(in: tokens, keep)
        for position in present.indices where position < present.count - 1 {
            let current = present[position]
            let next = present[position + 1]
            guard separator(from: current, to: next, in: tokens, keep).allSatisfy(\.isWhitespace) else { continue }

            let fragment = WordTokens.folded(tokens[current])
            let complete = WordTokens.folded(tokens[next])
            guard fragment.count >= 2,
                  complete.count > fragment.count,
                  complete.hasPrefix(fragment)
            else { continue }

            // A trailing hyphen is the model stating the word was cut off, which is
            // evidence rather than inference. Without it, only fragments that are not
            // words in their own right are treated as false starts.
            let wasTruncated = tokens[current].text.hasSuffix("-")
            guard wasTruncated || !realShortWords.contains(fragment) else { continue }
            keep[current] = false
        }
    }

    /// Removes the whitespace a deleted word left behind, so its neighbours end up
    /// correctly spaced rather than separated by a gap.
    private static func dropOrphanedSpacing(_ tokens: [WordTokens.Token], _ keep: inout [Bool]) {
        for index in tokens.indices where !keep[index] && tokens[index].isWord {
            if let after = tokens.indices[(index + 1)...].first(where: { keep[$0] }),
               !tokens[after].isWord,
               tokens[after].text.allSatisfy(\.isWhitespace) {
                keep[after] = false
            } else if let before = tokens.indices[..<index].last(where: { keep[$0] }),
                      !tokens[before].isWord,
                      tokens[before].text.allSatisfy(\.isWhitespace) {
                keep[before] = false
            }
        }
    }

    // MARK: - Helpers

    private static func words(in tokens: [WordTokens.Token], _ keep: [Bool]) -> [Int] {
        tokens.indices.filter { keep[$0] && tokens[$0].isWord }
    }

    /// The text still standing between two surviving words.
    private static func separator(
        from first: Int,
        to second: Int,
        in tokens: [WordTokens.Token],
        _ keep: [Bool]
    ) -> String {
        guard second > first + 1 else { return "" }
        return tokens[(first + 1)..<second].indices
            .filter { keep[$0] }
            .map { tokens[$0].text }
            .joined()
    }

    /// Repairs the punctuation a deletion can strand — the comma in "Uh, so we can"
    /// belonged to the filler, not to the sentence.
    private static func tidyPunctuation(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"^[\s,;:]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([,;:])\s*\1"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }
}
