import Foundation

/// How much room a conversation needs, and how much to ask the server for.
///
/// A local model server has to be told how large a context window to load, and the
/// defaults are small — a few thousand tokens on most machines. Sending an hour of
/// speech into that window does not fail: the server silently drops whatever does
/// not fit and answers from the remainder, so the model confidently discusses the
/// last ten minutes of a meeting as though it were the whole thing. Asking for the
/// right window up front is what makes "the model has read all of it" true rather
/// than merely intended.
enum TokenBudget {
    /// Deliberately below the ~4 characters a token usually holds in English.
    ///
    /// The two errors are not symmetrical. Over-estimating asks for a larger window
    /// than needed and costs some memory; under-estimating silently truncates the
    /// meeting. So the estimate leans high.
    static let charactersPerToken = 3.5
    /// Role framing and separators the server adds around each message.
    static let messageOverhead = 8
    /// Room left for the answer inside the same window.
    static let answerReserve = 1_024
    /// Never ask for less than this: below it, even a short meeting is truncated.
    static let minimumContext = 4_096
    static let step = 1_024

    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / charactersPerToken).rounded(.up))
    }

    static func estimate(_ messages: [LocalAIMessage]) -> Int {
        messages.reduce(0) { $0 + estimate($1.content) + messageOverhead }
    }

    /// The window to ask for: what the conversation needs, rounded up, but never
    /// beyond the ceiling the owner set.
    static func context(for messages: [LocalAIMessage], limit: Int) -> Int {
        let needed = estimate(messages) + answerReserve
        let rounded = ((needed + step - 1) / step) * step
        return min(max(rounded, minimumContext), max(limit, minimumContext))
    }

    /// Whether the whole conversation fits under the ceiling with room to answer.
    static func fits(_ messages: [LocalAIMessage], limit: Int) -> Bool {
        estimate(messages) + answerReserve <= limit
    }

    /// `32K`, `1.5K` — for stating a size next to a limit the owner can change.
    static func describe(_ tokens: Int) -> String {
        guard tokens >= 1_000 else { return "\(tokens)" }
        let thousands = Double(tokens) / 1_024
        return thousands < 10
            ? String(format: "%.1fK", thousands)
            : "\(Int(thousands.rounded()))K"
    }
}
