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
/// paraphrased must not be rewritten on a guess, so a term only replaces an
/// expression when the two are close enough that no other configured term is nearer,
/// and short terms are matched exactly or not at all — "Sam" must never eat "same".
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
        /// Whitespace is not part of an expression's identity. Speech recognition
        /// can invent or remove word boundaries even when it heard every sound.
        let matchingKey: String

        static func prepare(_ raw: [String]) -> [Term] {
            var seen = Set<String>()
            var result: [Term] = []
            for entry in raw {
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !words.isEmpty else { continue }
                let canonicalKey = words.joined(separator: " ").lowercased()
                guard seen.insert(canonicalKey).inserted else { continue }
                result.append(Term(
                    canonical: trimmed,
                    matchingKey: words.joined().lowercased()
                ))
            }
            return result
        }

        /// How far a candidate may stray and still be considered this term. Short
        /// terms get no latitude at all because at four characters a single edit is
        /// most of the word.
        var allowedDistance: Int {
            let length = matchingKey.count
            if length >= 8 { return 2 }
            if length >= 5 { return 1 }
            return 0
        }
    }

    // MARK: - Correction

    private static func correct(_ text: String, using terms: [Term]) -> String {
        guard !text.isEmpty else { return text }
        var tokens = WordTokens.split(text)
        let wordPositions = tokens.indices.filter { tokens[$0].isWord }
        guard !wordPositions.isEmpty else { return text }

        let candidates = correctionCandidates(
            in: tokens,
            wordPositions: wordPositions,
            terms: terms
        )
        let selected = selectedEffects(from: candidates)
        for effect in selected.sorted(by: {
            $0.tokenRange.lowerBound > $1.tokenRange.lowerBound
        }) {
            tokens.replaceSubrange(
                effect.tokenRange,
                with: WordTokens.split(effect.replacement)
            )
        }
        return WordTokens.join(tokens)
    }

    private struct Effect: Hashable {
        /// Half-open so a correction can be a genuine insertion at `n..<n`.
        let tokenRange: Range<Int>
        let replacement: String
    }

    private struct Candidate {
        let term: Term
        let termIndex: Int
        let distance: Int
        let wordRange: ClosedRange<Int>
        let effect: Effect
    }

    /// Finds lexical evidence without changing the transcript. Separating discovery
    /// from mutation means an early fuzzy span cannot hide a better interior match.
    private static func correctionCandidates(
        in tokens: [WordTokens.Token],
        wordPositions: [Int],
        terms: [Term]
    ) -> [Candidate] {
        let maximumLength = terms.map { $0.matchingKey.count + $0.allowedDistance }.max() ?? 0
        let wordKeys = wordPositions.map { tokens[$0].text.lowercased() }
        var candidates: [Candidate] = []

        for start in wordPositions.indices {
            var key = ""
            var end = start
            while end < wordPositions.count {
                let tokenPosition = wordPositions[end]
                if end > start {
                    let previousPosition = wordPositions[end - 1]
                    let separator = tokens[(previousPosition + 1)..<tokenPosition]
                    guard separator.allSatisfy({ $0.text.allSatisfy(\.isWhitespace) }) else { break }
                }
                key += wordKeys[end]
                guard key.count <= maximumLength else { break }

                for (termIndex, term) in terms.enumerated() {
                    guard let distance = matchDistance(term, candidate: key) else { continue }
                    candidates.append(Candidate(
                        term: term,
                        termIndex: termIndex,
                        distance: distance,
                        wordRange: start...end,
                        effect: visibleEffect(
                            replacing: wordPositions[start]...tokenPosition,
                            with: term.canonical,
                            in: tokens
                        )
                    ))
                }
                end += 1
            }
        }
        return minimalCandidates(candidates)
    }

    private static func matchDistance(_ term: Term, candidate: String) -> Int? {
        let allowed = term.allowedDistance
        guard abs(term.matchingKey.count - candidate.count) <= allowed else { return nil }
        let distance = term.matchingKey == candidate
            ? 0
            : editDistance(term.matchingKey, candidate, limit: allowed)
        return distance <= allowed ? distance : nil
    }

    /// A span cannot own words that a smaller span explains at least as well for
    /// the same configured expression. This is what keeps articles and pronouns
    /// adjacent to an expression rather than consuming them as fuzzy edits.
    private static func minimalCandidates(_ candidates: [Candidate]) -> [Candidate] {
        let indicesByTerm = Dictionary(grouping: candidates.indices, by: { candidates[$0].termIndex })
        var dominated = Set<Int>()

        for indices in indicesByTerm.values {
            let ordered = indices.sorted {
                if candidates[$0].wordRange.lowerBound != candidates[$1].wordRange.lowerBound {
                    return candidates[$0].wordRange.lowerBound < candidates[$1].wordRange.lowerBound
                }
                return candidates[$0].wordRange.upperBound < candidates[$1].wordRange.upperBound
            }
            var firstPositionByStart: [Int: Int] = [:]
            for (position, candidateIndex) in ordered.enumerated() {
                let start = candidates[candidateIndex].wordRange.lowerBound
                if firstPositionByStart[start] == nil { firstPositionByStart[start] = position }
            }
            for outerIndex in ordered {
                let outer = candidates[outerIndex]
                let firstPosition = firstPositionByStart[outer.wordRange.lowerBound] ?? 0
                for innerPosition in firstPosition..<ordered.count {
                    let innerIndex = ordered[innerPosition]
                    let inner = candidates[innerIndex]
                    if inner.wordRange.lowerBound > outer.wordRange.upperBound { break }
                    guard innerIndex != outerIndex,
                          inner.wordRange.lowerBound >= outer.wordRange.lowerBound,
                          inner.wordRange.upperBound <= outer.wordRange.upperBound,
                          inner.distance <= outer.distance else { continue }
                    dominated.insert(outerIndex)
                    break
                }
            }
        }
        return candidates.indices.compactMap { dominated.contains($0) ? nil : candidates[$0] }
    }

    /// Reduces a candidate to the exact edit it makes to the complete token stream.
    /// Comparing the complete outcomes matters for insertions: `Post` -> `Post X`
    /// and `analytics` -> `X analytics` are two descriptions of the same insertion.
    private static func visibleEffect(
        replacing tokenRange: ClosedRange<Int>,
        with canonical: String,
        in tokens: [WordTokens.Token]
    ) -> Effect {
        let replacement = WordTokens.split(canonical)
        let sourceRange = tokenRange.lowerBound..<(tokenRange.upperBound + 1)
        if Array(tokens[sourceRange]) == replacement {
            return Effect(tokenRange: sourceRange, replacement: canonical)
        }

        var outcome = tokens
        outcome.replaceSubrange(sourceRange, with: replacement)
        var prefix = 0
        while prefix < tokens.count,
              prefix < outcome.count,
              tokens[prefix] == outcome[prefix] {
            prefix += 1
        }

        var originalEnd = tokens.count
        var replacementEnd = outcome.count
        while originalEnd > prefix,
              replacementEnd > prefix,
              tokens[originalEnd - 1] == outcome[replacementEnd - 1] {
            originalEnd -= 1
            replacementEnd -= 1
        }
        return Effect(
            tokenRange: prefix..<originalEnd,
            replacement: WordTokens.join(Array(outcome[prefix..<replacementEnd]))
        )
    }

    /// Resolves matches by evidence rather than discovery order. Stronger unique
    /// edits reserve their tokens; equally strong overlaps reserve the same region
    /// without rewriting it, so uncertainty never falls through to a weaker guess.
    private static func selectedEffects(
        from candidates: [Candidate]
    ) -> [Effect] {
        let ordered = candidates.sorted {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.wordRange.count != $1.wordRange.count {
                return $0.wordRange.count > $1.wordRange.count
            }
            if $0.wordRange.lowerBound != $1.wordRange.lowerBound {
                return $0.wordRange.lowerBound < $1.wordRange.lowerBound
            }
            if $0.wordRange.upperBound != $1.wordRange.upperBound {
                return $0.wordRange.upperBound < $1.wordRange.upperBound
            }
            return $0.term.canonical < $1.term.canonical
        }

        var protected: [Range<Int>] = []
        var selected: [Effect] = []
        var groupStart = 0
        while groupStart < ordered.count {
            let priority = ordered[groupStart]
            var groupEnd = groupStart + 1
            while groupEnd < ordered.count,
                  ordered[groupEnd].distance == priority.distance,
                  ordered[groupEnd].wordRange.count == priority.wordRange.count {
                groupEnd += 1
            }

            var seenEffects = Set<Effect>()
            let available = ordered[groupStart..<groupEnd].filter { candidate in
                let unprotected = !protected.contains {
                    effectsConflict(candidate.effect.tokenRange, $0)
                }
                return unprotected && seenEffects.insert(candidate.effect).inserted
            }.sorted {
                if $0.effect.tokenRange.lowerBound != $1.effect.tokenRange.lowerBound {
                    return $0.effect.tokenRange.lowerBound < $1.effect.tokenRange.lowerBound
                }
                return $0.effect.tokenRange.upperBound < $1.effect.tokenRange.upperBound
            }

            var componentStart = 0
            while componentStart < available.count {
                var componentEnd = componentStart + 1
                var componentRanges = [available[componentStart].effect.tokenRange]
                while componentEnd < available.count,
                      componentRanges.contains(where: {
                          effectsConflict(available[componentEnd].effect.tokenRange, $0)
                      }) {
                    componentRanges.append(available[componentEnd].effect.tokenRange)
                    componentEnd += 1
                }

                if componentEnd == componentStart + 1 {
                    selected.append(available[componentStart].effect)
                }
                protected.append(contentsOf: componentRanges)
                componentStart = componentEnd
            }
            groupStart = groupEnd
        }
        return selected
    }

    /// Empty ranges are insertion points. Insertions at the same point conflict,
    /// as does an insertion on either edge of a replacement; applying both would
    /// make their result depend on mutation order.
    private static func effectsConflict(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        if lhs.isEmpty && rhs.isEmpty { return lhs.lowerBound == rhs.lowerBound }
        if lhs.isEmpty {
            return lhs.lowerBound >= rhs.lowerBound && lhs.lowerBound <= rhs.upperBound
        }
        if rhs.isEmpty {
            return rhs.lowerBound >= lhs.lowerBound && rhs.lowerBound <= lhs.upperBound
        }
        return lhs.overlaps(rhs)
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
