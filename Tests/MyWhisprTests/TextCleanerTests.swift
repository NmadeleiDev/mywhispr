import Testing
@testable import MyWhispr

@Suite("Faithful dictation cleanup")
struct TextCleanerTests {
    @Test func normalizesSpacingAndCapitalization() {
        #expect(TextCleaner.clean("  hello   world  ! ") == "Hello world!")
    }

    @Test func addsTerminalPunctuationWithoutChangingExistingPunctuation() {
        #expect(TextCleaner.clean("already done?") == "Already done?")
        #expect(TextCleaner.clean("a number 42") == "A number 42.")
    }

    @Test func preservesEmptyInput() {
        #expect(TextCleaner.clean(" \n ") == "")
    }
}
