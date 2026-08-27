import Foundation
import Testing
@testable import MyWhispr

/// `Text` renders only the inline half of Markdown. A model asked for meeting
/// notes writes the other half — headings and bullets — and those arrived on
/// screen as literal `##` and `*`.
@Suite("Markdown blocks")
struct MarkdownBlockTests {
    @Test func readsHeadingLevels() {
        #expect(MarkdownBlock.parse("# Meeting Notes") == [.heading(level: 1, text: "Meeting Notes")])
        #expect(MarkdownBlock.parse("## Overview") == [.heading(level: 2, text: "Overview")])
        #expect(MarkdownBlock.parse("### Product Positioning & UX")
            == [.heading(level: 3, text: "Product Positioning & UX")])
    }

    /// The space is the whole difference between a heading and a word that starts
    /// with a hash, and Markdown says so.
    @Test func aHashtagIsNotAHeading() {
        #expect(MarkdownBlock.parse("#retro was useful") == [.paragraph("#retro was useful")])
    }

    @Test func closingHashesAreNotPartOfTheTitle() {
        #expect(MarkdownBlock.parse("## Overview ##") == [.heading(level: 2, text: "Overview")])
    }

    /// The case that made this necessary: a bulleted line whose content opens in
    /// bold. `*` then a space is a bullet; `**` is emphasis. Getting this wrong
    /// either eats the bullet or turns every bold line into one.
    @Test func tellsABulletApartFromBoldAtTheStartOfALine() {
        #expect(MarkdownBlock.parse("* **Core Value Gap:** Liza noted that the landing page is vague.")
            == [.bullet(depth: 0, text: "**Core Value Gap:** Liza noted that the landing page is vague.")])
        #expect(MarkdownBlock.parse("**Participants:** Misha, Grisha, and Liza")
            == [.paragraph("**Participants:** Misha, Grisha, and Liza")])
    }

    @Test func acceptsEveryBulletMarker() {
        #expect(MarkdownBlock.parse("- one\n* two\n+ three") == [
            .bullet(depth: 0, text: "one"),
            .bullet(depth: 0, text: "two"),
            .bullet(depth: 0, text: "three"),
        ])
    }

    @Test func readsNumberedItemsAndKeepsTheirNumbers() {
        #expect(MarkdownBlock.parse("1. First\n2) Second") == [
            .numbered(depth: 0, number: "1", text: "First"),
            .numbered(depth: 0, number: "2", text: "Second"),
        ])
        // A sentence that opens with a year is not a list.
        #expect(MarkdownBlock.parse("2026. was mentioned") == [.paragraph("2026. was mentioned")])
    }

    @Test func nestsByIndentation() {
        #expect(MarkdownBlock.parse("- top\n  - nested\n    - deeper") == [
            .bullet(depth: 0, text: "top"),
            .bullet(depth: 1, text: "nested"),
            .bullet(depth: 2, text: "deeper"),
        ])
    }

    /// Markdown wraps long items across lines. Splitting one into a bullet plus an
    /// orphaned paragraph is how a wrapped sentence loses its bullet.
    @Test func keepsAWrappedListItemWhole() {
        #expect(MarkdownBlock.parse("* Use Cases: There is a lack of clear use cases.\n  Misha highlighted price monitoring.")
            == [.bullet(depth: 0, text: "Use Cases: There is a lack of clear use cases. Misha highlighted price monitoring.")])
    }

    @Test func joinsSoftWrappedParagraphsAndSplitsOnBlankLines() {
        #expect(MarkdownBlock.parse("The meeting focused on\npositioning.\n\nLiza gave a view.") == [
            .paragraph("The meeting focused on positioning."),
            .paragraph("Liza gave a view."),
        ])
    }

    @Test func keepsCodeBlocksLiteral() {
        let document = "```swift\nlet x = 1\n\n# not a heading\n```"
        #expect(MarkdownBlock.parse(document)
            == [.code(language: "swift", text: "let x = 1\n\n# not a heading")])
    }

    /// An unterminated fence is still the owner's content and must not vanish.
    @Test func keepsAnUnclosedCodeBlock() {
        #expect(MarkdownBlock.parse("```\nstranded") == [.code(language: nil, text: "stranded")])
    }

    @Test func mergesConsecutiveQuoteLines() {
        #expect(MarkdownBlock.parse("> first\n> second") == [.quote("first second")])
    }

    @Test func readsThematicBreaks() {
        #expect(MarkdownBlock.parse("---") == [.rule])
        #expect(MarkdownBlock.parse("***") == [.rule])
        // Three dashes are a break; two are a sentence.
        #expect(MarkdownBlock.parse("--") == [.paragraph("--")])
    }

    @Test func anEmptySummaryProducesNothingToRender() {
        #expect(MarkdownBlock.parse("").isEmpty)
        #expect(MarkdownBlock.parse("\n\n   \n").isEmpty)
    }

    /// The real thing, in the shape the model actually produced it.
    @Test func parsesAWholeMeetingSummary() {
        let summary = """
        # Meeting Notes: dEssense.ai Positioning & Product Review

        **Participants:** Misha, Grisha, and Liza

        ## Overview
        The meeting focused on the current positioning challenges of dEssense.ai.

        ### Product Positioning & UX
        * **Core Value Gap:** Liza noted that the landing page is vague.
        * **Use Cases:** There is a lack of clear, interactive use cases.
        """
        #expect(MarkdownBlock.parse(summary) == [
            .heading(level: 1, text: "Meeting Notes: dEssense.ai Positioning & Product Review"),
            .paragraph("**Participants:** Misha, Grisha, and Liza"),
            .heading(level: 2, text: "Overview"),
            .paragraph("The meeting focused on the current positioning challenges of dEssense.ai."),
            .heading(level: 3, text: "Product Positioning & UX"),
            .bullet(depth: 0, text: "**Core Value Gap:** Liza noted that the landing page is vague."),
            .bullet(depth: 0, text: "**Use Cases:** There is a lack of clear, interactive use cases."),
        ])
    }

    /// Emphasis inside a block is still Foundation's job, not this parser's.
    @Test func inlineEmphasisSurvivesIntoTheRenderedRun() {
        let attributed = MarkdownText.inline("**Core Value Gap:** the landing page is vague")
        #expect(String(attributed.characters) == "Core Value Gap: the landing page is vague")
    }
}
