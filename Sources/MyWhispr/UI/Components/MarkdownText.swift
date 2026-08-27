import SwiftUI

/// One block of a Markdown document, flattened.
///
/// Nesting is carried as a depth rather than as a tree. A meeting summary is a
/// short document of headings, bullets, and paragraphs — the tree would exist only
/// to be walked straight back into a flat stack of views.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(depth: Int, text: String)
    case numbered(depth: Int, number: String, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case rule

    /// Splits a Markdown document into blocks.
    ///
    /// Deliberately not a full CommonMark implementation. It covers what a model
    /// asked for "meeting notes in Markdown" actually writes, and anything it does
    /// not recognise becomes a paragraph — which renders as the author's own text
    /// rather than as an error or as nothing.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: (language: String?, lines: [String])?

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph.removeAll()
            guard !joined.isEmpty else { return }
            blocks.append(.paragraph(joined))
        }

        /// A plain line under a list item belongs to that item: Markdown wraps long
        /// items across lines, and splitting one into a bullet plus an orphaned
        /// paragraph is how a wrapped sentence loses its bullet.
        func continueListItem(with line: String) -> Bool {
            guard paragraph.isEmpty, let last = blocks.last else { return false }
            switch last {
            case .bullet(let depth, let text):
                blocks[blocks.count - 1] = .bullet(depth: depth, text: text + " " + line)
                return true
            case .numbered(let depth, let number, let text):
                blocks[blocks.count - 1] = .numbered(depth: depth, number: number, text: text + " " + line)
                return true
            default:
                return false
            }
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Inside a fence everything is literal, including blank lines and any
            // character that would otherwise open a block.
            if var open = fence {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(rawLine)
                    fence = open
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                fence = (language.isEmpty ? nil : language, [])
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            let depth = indentDepth(of: line)

            if let text = bulletText(trimmed) {
                flushParagraph()
                blocks.append(.bullet(depth: depth, text: text))
                continue
            }

            if let (number, text) = numberedText(trimmed) {
                flushParagraph()
                blocks.append(.numbered(depth: depth, number: number, text: text))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case .quote(let existing) = blocks.last {
                    blocks[blocks.count - 1] = .quote(existing.isEmpty ? text : existing + " " + text)
                } else {
                    blocks.append(.quote(text))
                }
                continue
            }

            if continueListItem(with: trimmed) { continue }
            paragraph.append(trimmed)
        }

        // An unterminated fence is still content; the owner should see it.
        if let open = fence {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func heading(from trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        // `#hashtag` is a word, `# Heading` is a heading. The space is the whole
        // difference, and Markdown says so.
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes.count, text: text)
    }

    /// `* item` is a bullet; `**Bold:** …` is not. Requiring the space after a
    /// single marker character is what separates them, and a summary whose lines
    /// open in bold hits this constantly.
    private static func bulletText(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedText(_ trimmed: String) -> (String, String)? {
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits), String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for character in ["-", "*", "_"] where trimmed.allSatisfy({ String($0) == character }) {
            return true
        }
        return false
    }

    private static func indentDepth(of line: String) -> Int {
        let spaces = line.prefix { $0 == " " }.count
        return min(spaces / 2, 3)
    }
}

/// Renders Markdown with its block structure intact.
///
/// `Text` understands Markdown, but only the inline half of it — emphasis, code
/// spans, links. Headings, bullets, quotes, and code blocks are block-level, and
/// `Text` prints their syntax literally, so notes written by a model asked for
/// Markdown arrived on screen as a wall of `##` and `*`. Blocks are laid out here;
/// each block's inline content still goes through the same parser `Text` uses, so
/// nothing about emphasis or links is reimplemented.
struct MarkdownText: View {
    var markdown: String
    var baseSize: CGFloat = 13

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(level >= 4 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.top, level <= 2 ? 4 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.system(size: baseSize))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let depth, let text):
            marked(depth: depth, marker: Text(Self.bulletMarker(depth)), text: text)

        case .numbered(let depth, let number, let text):
            marked(depth: depth, marker: Text("\(number)."), text: text)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Palette.accent.opacity(0.5))
                    .frame(width: 2)
                Text(Self.inline(text))
                    .font(.system(size: baseSize))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(_, let text):
            Text(text)
                .font(.system(size: baseSize - 1, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    /// A list row: the marker keeps its own column so wrapped text lines up under
    /// itself rather than under the bullet.
    private func marked(depth: Int, marker: Text, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
                .font(.system(size: baseSize))
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
            Text(Self.inline(text))
                .font(.system(size: baseSize))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: baseSize + 3
        case 2: baseSize + 1
        case 3: baseSize
        default: baseSize - 1
        }
    }

    private static func bulletMarker(_ depth: Int) -> String {
        switch depth {
        case 0: "•"
        case 1: "◦"
        default: "–"
        }
    }

    /// Inline emphasis, code spans, and links — parsed by the same Foundation
    /// parser `Text` uses for its own Markdown support. Malformed inline syntax
    /// falls back to the literal text rather than losing the line.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
