import Carbon.HIToolbox
import Foundation
import Testing
@testable import MyWhispr

@Suite("Keyboard shortcuts")
struct ShortcutBindingTests {
    @Test func rendersModifiersInMacOrder() {
        // macOS always prints modifiers ⌃⌥⇧⌘, regardless of the order they were
        // pressed, so a binding must render the same way menus do.
        //
        // Only the modifier prefix is asserted. The key name is resolved through the
        // *active* keyboard layout by design — the physical M key prints "Ь" while a
        // Russian layout is selected, which is both correct and what the system does
        // — so pinning the letter here would only assert which layout the machine
        // running the tests happens to be using.
        let binding = ShortcutBinding(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey)
        )
        #expect(binding.displayString.hasPrefix("⌃⌥⇧⌘"))
        #expect(binding.displayString.count == 5)
    }

    @Test func modifierGlyphsAppearOnlyWhenTheModifierIsSet() {
        let commandOnly = ShortcutBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey))
        #expect(commandOnly.displayString == "⌘Space")

        let controlOption = ShortcutBinding(
            keyCode: UInt32(kVK_Escape),
            carbonModifiers: UInt32(controlKey | optionKey)
        )
        #expect(controlOption.displayString == "⌃⌥⎋")
    }

    @Test func namesSpecialKeysWithGlyphs() {
        #expect(ShortcutBinding.keyName(for: UInt32(kVK_Space)) == "Space")
        #expect(ShortcutBinding.keyName(for: UInt32(kVK_Escape)) == "⎋")
        #expect(ShortcutBinding.keyName(for: UInt32(kVK_Return)) == "↩")
    }

    @Test func defaultsAreDistinctAndModified() {
        let defaults = [
            ShortcutBinding.meetingToggle,
            ShortcutBinding.quickPaste,
            ShortcutBinding.openMainWindow,
        ]
        // A binding with no modifier would swallow ordinary typing system-wide.
        #expect(defaults.allSatisfy { $0.carbonModifiers != 0 })
        #expect(Set(defaults.map { "\($0.keyCode)-\($0.carbonModifiers)" }).count == defaults.count)
    }

    @Test func eventModifiersMirrorCarbonMask() {
        let binding = ShortcutBinding.quickPaste
        #expect(binding.eventModifiers.contains(.command))
        #expect(binding.eventModifiers.contains(.option))
        #expect(!binding.eventModifiers.contains(.control))
    }
}

@Suite("Retention policy")
struct RetentionTests {
    @Test func foreverNeverExpires() {
        #expect(HistoryRetention.forever.cutoff() == nil)
    }

    @Test func noneExpiresEverythingImmediately() throws {
        let now = Date()
        let cutoff = try #require(HistoryRetention.none.cutoff(from: now))
        #expect(cutoff == now)
    }

    @Test func dayCountsMapToPastDates() throws {
        let now = Date()
        let cutoff = try #require(HistoryRetention.thirtyDays.cutoff(from: now))
        let days = Calendar.current.dateComponents([.day], from: cutoff, to: now).day
        #expect(days == 30)
    }
}

@MainActor
@Suite("Permission wording")
struct PermissionSummaryTests {
    @Test func namesLostCapabilitiesRatherThanPermissionNames() {
        let center = PermissionCenter()

        center.microphone = .granted
        center.accessibility = .granted
        #expect(center.dictationReady)
        #expect(center.blockedSummary == "Dictation is ready.")

        center.accessibility = .denied
        #expect(!center.dictationReady)
        #expect(center.blockedSummary == "MyWhispr cannot notice the dictation key or type into other apps yet.")

        center.microphone = .denied
        #expect(center.blockedSummary == "MyWhispr needs permission to hear you and to type into other apps.")

        center.accessibility = .granted
        #expect(center.blockedSummary == "MyWhispr cannot hear you yet.")
    }

    @Test func inputMonitoringIsNotRequiredForDictation() {
        let center = PermissionCenter()
        center.microphone = .granted
        center.accessibility = .granted
        center.inputMonitoring = .denied

        // Accessibility trust already carries the right to observe keyboard events;
        // this was verified against the real system, with the Input Monitoring list
        // empty and the event tap delivering events normally. Requiring it as well
        // would demand the scariest-sounding permission on the list for nothing.
        #expect(center.dictationReady)
        #expect(center.canObserveKeyboard)
        #expect(center.blockedSummary == "Dictation is ready.")
    }

    @Test func inputMonitoringAloneStillPermitsKeyboardObservation() {
        let center = PermissionCenter()
        center.accessibility = .denied
        center.inputMonitoring = .granted
        #expect(center.canObserveKeyboard)
    }
}
