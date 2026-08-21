import Foundation

/// Repairs near-misses of the owner's own words in a finished transcript.
///
/// Speech models mangle exactly the words that matter most and appear least in
/// their training data: people's names, product names, and in-house jargon. Neither
/// engine MyWhispr ships can be told about them at decode time — FluidAudio's
/// vocabulary boosting is confined to managers we do not use, and WhisperKit's
/// prompt tokens bias a *prefix* rather than a term list — so the correction is made
/// where it is both possible and verifiable: on the text that comes back.
///
/// The rule is deliberately timid. A transcript the owner did not ask to be
/// paraphrased must not be rewritten on a guess, so a term only replaces a word when
/// the two are close enough that no other configured term is nearer, and short words
/// are matched exactly or not at all — "Sam" must never eat "same".
enum VocabularyCorrector {
    static func apply(_ terms: [String], to result: TranscriptionResult) -> TranscriptionResult {
        let prepared = Term.prepare(terms)
        guard !prepared.isEmpty else { return result }
        var corrected = result
        corrected.text = correct(result.text, using: prepared)
        corrected.segments = result.segments.map { segment in
            var copy = segment
            copy.text = correct(segment.text, using: prepared)
            return copy
        }
        return corrected
    }

    static func apply(_ terms: [String], to text: String) -> String {
        let prepared = Term.prepare(terms)
        guard !prepared.isEmpty else { return text }
        return correct(text, using: prepared)
    }

    // MARK: - Terms

    struct Term {
        /// Exactly as the owner typed it; this is what gets written into the text.
        let canonical: String
        /// The canonical form split into words, so a multi-word term can be matched
        /// across the separators the transcript actually used.
        let words: [String]
        let folded: String

        static func prepare(_ raw: [String]) -> [Term] {
            var seen = Set<String>()
            var result: [Term] = []
            for entry in raw {
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !words.isEmpty else { continue }
                let folded = words.joined(separator: " ").lowercased()
                guard seen.insert(folded).inserted else { continue }
                result.append(Term(canonical: trimmed, words: words, folded: folded))
            }
            return result
        }

        /// How far a candidate may stray and still be considered this term. Short
        /// terms get no latitude at all because at four characters a single edit is
        /// most of the word.
        var allowedDistance: Int {
            let length = folded.replacingOccurrences(of: " ", with: "").count
            if length >= 8 { return 2 }
            if length >= 5 { return 1 }
            return 0
        }
    }

    // MARK: - Correction

    private static func correct(_ text: String, using terms: [Term]) -> String {
        guard !text.isEmpty else { return text }
        var tokens = tokenize(text)
        let wordPositions = tokens.indices.filter { tokens[$0].isWord }
        guard !wordPositions.isEmpty else { return text }

        let longest = terms.map(\.words.count).max() ?? 1
        var cursor = 0
        while cursor < wordPositions.count {
            var matchedLength = 0
            // Longest match wins, so a two-word term is never half-corrected by a
            // one-word term that happens to resemble its first half.
            for length in stride(from: min(longest, wordPositions.count - cursor), through: 1, by: -1) {
                let slice = (0..<length).map { tokens[wordPositions[cursor + $0]].text }
                guard let term = bestMatch(for: slice, in: terms) else { continue }
                for offset in 0..<length {
                    tokens[wordPositions[cursor + offset]].text = term.words[offset]
                }
                matchedLength = length
                break
            }
            cursor += max(matchedLength, 1)
        }
        return tokens.map(\.text).joined()
    }

    /// The single closest term, or nil when nothing is close enough or two terms are
    /// equally close. A tie is an ambiguity, and guessing at an ambiguity is how a
    /// transcript stops being a record of what was said.
    private static func bestMatch(for words: [String], in terms: [Term]) -> Term? {
        let candidate = words.joined(separator: " ").lowercased()
        guard !candidate.isEmpty else { return nil }

        var best: (term: Term, distance: Int)?
        var tied = false
        for term in terms where term.words.count == words.count {
            if term.folded == candidate {
                // An exact match still rewrites the token, which is what fixes
                // casing: "openwhispr" becomes "OpenWhispr".
                return term
            }
            let allowed = term.allowedDistance
            guard allowed > 0, abs(term.folded.count - candidate.count) <= allowed else { continue }
            let distance = editDistance(term.folded, candidate, limit: allowed)
            guard distance <= allowed else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (term, distance)
                    tied = false
                } else if distance == current.distance {
                    tied = true
                }
            } else {
                best = (term, distance)
            }
        }
        guard let best, !tied else { return nil }
        // A term that would rewrite a word into something completely different is a
        // coincidence, not a correction.
        return best.term
    }

    // MARK: - Tokenizing

    struct Token {
        var text: String
        var isWord: Bool
    }

    /// Splits into alternating word and separator runs. Apostrophes and hyphens stay
    /// inside a word so "don't" and "half-life" are single candidates.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord: Bool?

        func flush() {
            guard let currentIsWord, !current.isEmpty else { return }
            tokens.append(Token(text: current, isWord: currentIsWord))
            current = ""
        }

        for character in text {
            let isWord = character.isLetter || character.isNumber || character == "'" || character == "’" || character == "-"
            if isWord != currentIsWord {
                flush()
                currentIsWord = isWord
            }
            current.append(character)
        }
        flush()

        // A run of only apostrophes or hyphens is punctuation, not a word.
        return tokens.map { token in
            guard token.isWord else { return token }
            let hasContent = token.text.contains { $0.isLetter || $0.isNumber }
            return Token(text: token.text, isWord: hasContent)
        }
    }

    // MARK: - Distance

    /// Levenshtein distance, abandoned as soon as every cell in a row exceeds
    /// `limit`, which is what keeps this cheap on a long meeting transcript.
    static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                rowBest = min(rowBest, current[j])
            }
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
