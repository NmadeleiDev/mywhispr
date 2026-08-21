import Foundation

enum TextCleaner {
    static func clean(_ input: String) -> String {
        var text = input
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        if let first = text.first, first.isLetter, first.isLowercase {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }
        if let last = text.last, last.isLetter || last.isNumber { text.append(".") }
        return text
    }
}
