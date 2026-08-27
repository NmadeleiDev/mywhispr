import Foundation

/// Removes a model's reasoning scratchpad from an answer as it arrives.
///
/// Reasoning models write `<think>…</think>` into the ordinary content stream before
/// answering. Left in, it is typed into whatever app the owner was writing in, or
/// shown to them as if it were the answer to their question.
///
/// The awkward part is that this arrives in pieces. A tag routinely straddles two
/// network chunks — `<thi` in one, `nk>` in the next — so a regex over each chunk
/// sees no tag in either and lets the whole scratchpad through. This scans
/// incrementally instead, holding back only the few characters that could still turn
/// out to be the start of a tag, so text is emitted as early as it is provably text.
struct ReasoningFilter {
    /// The tag names models actually use for their scratchpad.
    private static let names = ["think", "thinking", "reasoning", "thought"]

    private var insideReasoning = false
    /// Characters withheld because they might yet complete a tag.
    private var pending = ""

    /// The visible part of one fragment. May be empty while a tag is still
    /// ambiguous, and may exceed the fragment when withheld text is released.
    mutating func consume(_ fragment: String) -> String {
        guard !fragment.isEmpty else { return "" }
        pending += fragment
        var visible = ""

        while !pending.isEmpty {
            if insideReasoning {
                guard let close = Self.firstTag(in: pending, opening: false) else {
                    // Nothing here closes the block, but the tail could be the start
                    // of the closing tag, so only the provably-inert part is dropped.
                    pending = String(pending.suffix(Self.longestTagLength - 1))
                    return visible
                }
                insideReasoning = false
                pending = String(pending[close.upperBound...])
                continue
            }

            guard let angle = pending.firstIndex(of: "<") else {
                visible += pending
                pending = ""
                return visible
            }

            visible += pending[..<angle]
            let rest = String(pending[angle...])

            if let open = Self.firstTag(in: rest, opening: true), open.lowerBound == rest.startIndex {
                insideReasoning = true
                pending = String(rest[open.upperBound...])
                continue
            }
            if Self.couldStartTag(rest) {
                // Not a tag yet, but it still could be. Wait for the next fragment.
                pending = rest
                return visible
            }
            // A literal `<` in the answer. Emit it and keep scanning past it.
            visible += "<"
            pending = String(rest.dropFirst())
        }
        return visible
    }

    /// Anything still withheld once the stream ends.
    ///
    /// Text held back for a tag that never completed is real text and is released.
    /// An unterminated reasoning block is not: the model never reached its answer,
    /// and showing the scratchpad instead would present thinking as a conclusion.
    /// The caller sees an empty answer, which is the truth.
    mutating func flush() -> String {
        defer { pending = "" }
        return insideReasoning ? "" : pending
    }

    /// Strips a whole string in one go, for callers that were never streaming.
    static func strip(_ text: String) -> String {
        var filter = ReasoningFilter()
        return filter.consume(text) + filter.flush()
    }

    // MARK: - Tag scanning

    private static let longestTagLength = names.map { $0.count }.max()! + 3 // `</` + name + `>`

    /// The range of the first opening or closing reasoning tag, if one is complete.
    private static func firstTag(in text: String, opening: Bool) -> Range<String.Index>? {
        names
            .compactMap { text.range(of: opening ? "<\($0)>" : "</\($0)>", options: .caseInsensitive) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    /// Whether `text`, which begins with `<`, is still a possible prefix of a tag.
    private static func couldStartTag(_ text: String) -> Bool {
        guard text.count < longestTagLength else { return false }
        let lowered = text.lowercased()
        return names.contains { name in
            ["<\(name)>", "</\(name)>"].contains { $0.hasPrefix(lowered) }
        }
    }
}
