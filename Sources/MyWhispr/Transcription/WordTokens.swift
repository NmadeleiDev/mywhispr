import Foundation

/// Splits text into alternating word and separator runs, losslessly.
///
/// Shared by every pass that edits a transcript word by word. Rejoining the tokens
/// unchanged must reproduce the input exactly, which is what lets a pass delete a
/// word without disturbing the spacing or punctuation around the words it keeps.
enum WordTokens {
    struct Token: Equatable {
        var text: String
        var isWord: Bool
    }

    /// Apostrophes and hyphens stay inside a word, so "don't", "half-life" and the
    /// truncated "re-" of a false start each arrive as one token.
    static func split(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord: Bool?

        func flush() {
            guard let currentIsWord, !current.isEmpty else { return }
            tokens.append(Token(text: current, isWord: currentIsWord))
            current = ""
        }

        for character in text {
            let isWord = character.isLetter
                || character.isNumber
                || character == "'"
                || character == "\u{2019}"
                || character == "-"
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

    static func join(_ tokens: [Token]) -> String {
        tokens.map(\.text).joined()
    }

    /// The word itself, without the apostrophes or hyphens clinging to its edges,
    /// lowercased for comparison against a lexicon.
    static func folded(_ token: Token) -> String {
        token.text
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}-"))
            .lowercased()
    }
}
