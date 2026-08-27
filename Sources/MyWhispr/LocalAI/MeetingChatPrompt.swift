import Foundation

/// What the model is told before a question about a meeting.
///
/// The whole transcript goes in the system message rather than being retrieved
/// piecemeal. A meeting is a single document that the owner was present for, and the
/// questions they ask about it — "what did we decide", "did anyone disagree", "what
/// am I on the hook for" — are answered by having read all of it, not by finding the
/// paragraph that best matches the wording of the question.
enum MeetingChatPrompt {
    static func messages(
        instruction: String,
        transcript: String,
        history: [LocalAIMessage]
    ) -> [LocalAIMessage] {
        let system = """
        \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))

        The transcript of the meeting follows. Each line is `[timestamp] Speaker: \
        what they said`. "You" is the person asking you these questions.

        <transcript>
        \(transcript)
        </transcript>
        """
        // A stored turn is only ever a question or an answer. Filtering anyway means
        // the system message below is the only one that can ever be in that role.
        return [.system(system)] + history.filter { $0.role != .system }
    }

    /// What the wrapper around the instruction and the transcript costs, so the
    /// size of a conversation can be judged without building it.
    static let framingTokens = 80

    /// Openers offered on an empty conversation.
    ///
    /// Three, because the point is to show what kind of thing can be asked, not to
    /// supply a menu the owner picks from instead of thinking of their own question.
    static let suggestions = [
        "What was decided?",
        "What am I supposed to do next?",
        "Summarise what I missed.",
    ]
}
