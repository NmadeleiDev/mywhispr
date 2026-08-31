import Foundation
import SwiftUI

enum MarkdownColumnAlignment: Equatable {
    case leading
    case center
    case trailing
}

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
    case table(headers: [String], alignments: [MarkdownColumnAlignment], rows: [[String]])
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
        var acceptingTableRows = false

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
                acceptingTableRows = false
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                fence = (language.isEmpty ? nil : language, [])
                continue
            }

            if trimmed.isEmpty {
                acceptingTableRows = false
                flushParagraph()
                continue
            }

            if acceptingTableRows,
               let cells = tableCells(from: trimmed),
               case .table(let headers, let alignments, var rows) = blocks.last,
               cells.count == headers.count {
                rows.append(cells)
                blocks[blocks.count - 1] = .table(
                    headers: headers,
                    alignments: alignments,
                    rows: rows
                )
                continue
            }
            acceptingTableRows = false

            // A table is recognised by its separator row. The header itself was
            // accumulated as a possible paragraph on the previous line; pull just
            // that line back out while preserving any paragraph before it.
            if let alignments = tableAlignments(from: trimmed),
               let headerLine = paragraph.last,
               let headers = tableCells(from: headerLine),
               headers.count == alignments.count {
                paragraph.removeLast()
                flushParagraph()
                blocks.append(.table(headers: headers, alignments: alignments, rows: []))
                acceptingTableRows = true
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

    private static func tableCells(from line: String) -> [String]? {
        var body = line.trimmingCharacters(in: .whitespaces)
        guard body.contains("|") else { return nil }
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        let cells = body.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return cells.count >= 2 ? cells : nil
    }

    private static func tableAlignments(from line: String) -> [MarkdownColumnAlignment]? {
        guard let cells = tableCells(from: line) else { return nil }
        var alignments: [MarkdownColumnAlignment] = []
        for cell in cells {
            let marker = cell.trimmingCharacters(in: .whitespaces)
            let core = marker.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard core.count >= 3, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (marker.hasPrefix(":"), marker.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
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

        case .table(let headers, let alignments, let rows):
            markdownTable(headers: headers, alignments: alignments, rows: rows)

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func markdownTable(
        headers: [String],
        alignments: [MarkdownColumnAlignment],
        rows: [[String]]
    ) -> some View {
        let widths = headers.indices.map { column in
            tableColumnWidth(column, headers: headers, rows: rows)
        }
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, alignments: alignments, widths: widths, isHeader: true)
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, alignments: alignments, widths: widths, isHeader: false)
                        .background(index.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.025))
                    if index < rows.count - 1 { Divider().opacity(0.5) }
                }
            }
            .background(.background.secondary.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
    }

    private func tableRow(
        _ cells: [String],
        alignments: [MarkdownColumnAlignment],
        widths: [CGFloat],
        isHeader: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { column in
                Text(Self.inline(cells[column]))
                    .font(.system(size: baseSize, weight: isHeader ? .semibold : .regular))
                    .frame(
                        width: widths[column],
                        alignment: tableAlignment(alignments[column])
                    )
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .overlay(alignment: .trailing) {
                        if column < cells.count - 1 {
                            Rectangle().fill(.quaternary).frame(width: 1)
                        }
                    }
            }
        }
    }

    private func tableColumnWidth(
        _ column: Int,
        headers: [String],
        rows: [[String]]
    ) -> CGFloat {
        let contents = [headers[column]] + rows.compactMap { row in
            row.indices.contains(column) ? row[column] : nil
        }
        let longest = contents.map(\.count).max() ?? 0
        let ideal = CGFloat(longest) * 6.4
        return min(max(ideal, column == 0 ? 180 : 90), column == 0 ? 420 : 240)
    }

    private func tableAlignment(_ alignment: MarkdownColumnAlignment) -> Alignment {
        switch alignment {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
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
        let normalized = MarkdownInlineText.normalized(text)
        return (try? AttributedString(
            markdown: normalized,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(normalized)
    }
}

/// Models occasionally write TeX despite being asked for Markdown. Foundation's
/// Markdown parser does not render TeX, so a small vocabulary of notation common
/// in meeting notes is converted to native Unicode before inline Markdown parsing.
/// This deliberately does not run for fenced code blocks.
enum MarkdownInlineText {
    private static let operatorPatterns: [(String, String)] = [
        (#"\$\s*\\(?:rightarrow|to)\s*\$"#, "→"),
        (#"\$\s*\\leftarrow\s*\$"#, "←"),
        (#"\$\s*\\leftrightarrow\s*\$"#, "↔"),
        (#"\$\s*\\(?:ge|geq)\s*\$"#, "≥"),
        (#"\$\s*\\(?:le|leq)\s*\$"#, "≤"),
        (#"\$\s*\\neq\s*\$"#, "≠"),
        (#"\$\s*\\approx\s*\$"#, "≈"),
        (#"\$\s*\\times\s*\$"#, "×"),
        (#"\$\s*\\pm\s*\$"#, "±"),
    ]

    private static let bareCommands: [(String, String)] = [
        (#"\\(?:rightarrow|to)(?![A-Za-z])"#, "→"),
        (#"\\leftarrow(?![A-Za-z])"#, "←"),
        (#"\\leftrightarrow(?![A-Za-z])"#, "↔"),
        (#"\\(?:ge|geq)(?![A-Za-z])"#, "≥"),
        (#"\\(?:le|leq)(?![A-Za-z])"#, "≤"),
        (#"\\neq(?![A-Za-z])"#, "≠"),
        (#"\\approx(?![A-Za-z])"#, "≈"),
        (#"\\times(?![A-Za-z])"#, "×"),
        (#"\\pm(?![A-Za-z])"#, "±"),
    ]

    static func normalized(_ text: String) -> String {
        var result = text

        // A frequent malformed mix of TeX comparison and Markdown currency:
        // `$\ge $20,000$/month` means `≥ $20,000/month`.
        result = replacing(#"\$\s*\\(?:ge|geq)\s+\${1,2}(?=[0-9])"#, in: result, with: "≥ $")
        result = replacing(#"\$\s*\\(?:le|leq)\s+\${1,2}(?=[0-9])"#, in: result, with: "≤ $")

        for (pattern, symbol) in operatorPatterns {
            result = replacing(pattern, in: result, with: symbol)
        }
        for (pattern, symbol) in bareCommands {
            result = replacing(pattern, in: result, with: symbol)
        }

        return unwrappingCurrency(in: result)
            .replacingOccurrences(of: #"\$"#, with: "$")
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    /// Turns `$20,000$` and `$$15,000$` into ordinary currency while leaving a
    /// normal `$20,000` amount and unrelated dollar signs untouched.
    private static func unwrappingCurrency(in text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"\${1,2}([0-9][0-9,.]*)\$(?=/|\s|[.,;:)]|$)"#
        ) else { return text }
        var result = text
        let matches = expression.matches(
            in: result,
            range: NSRange(result.startIndex..<result.endIndex, in: result)
        )
        for match in matches.reversed() {
            guard let whole = Range(match.range(at: 0), in: result),
                  let amount = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(whole, with: "$" + result[amount])
        }
        return result
    }
}
