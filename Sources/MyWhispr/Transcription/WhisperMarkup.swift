import Foundation

/// Removes a Whisper model's own control tokens from text it produced.
///
/// Whisper does not emit words; it emits tokens, and some of them are instructions
/// to the decoder rather than anything anybody said: `<|startoftranscript|>`,
/// `<|ru|>`, `<|transcribe|>`, `<|endoftext|>`, and a timestamp token such as
/// `<|9.36|>` at each segment boundary. Whether those survive into the decoded
/// string is a decoding option that defaults to leaving them in — a sensible
/// default for a library whose callers may want the timing, and the wrong one for
/// every caller here, since the text goes on screen, into the search index, and
/// into whatever the owner pastes it into.
///
/// The option is set. This exists because the option is not the only way text
/// reaches a transcript, and markup that gets as far as the database is markup the
/// owner has to edit out of an hour-long meeting by hand.
enum WhisperMarkup {
    /// Anything of the form `<|…|>`. Speech does not contain it, and Whisper's
    /// control tokens are all of this shape, so the pattern needs no vocabulary of
    /// individual token names to stay correct as models add them.
    private static let pattern = try! NSRegularExpression(pattern: #"<\|[^|>]*\|>"#)

    static func containsMarkup(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.firstMatch(in: text, range: range) != nil
    }

    static func stripped(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard pattern.firstMatch(in: text, range: range) != nil else { return text }
        // Replaced with a space rather than deleted: a token can sit directly
        // between two words, and removing it outright would glue them together into
        // something that is not a word and cannot be searched for.
        let bare = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        return bare
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?…])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
