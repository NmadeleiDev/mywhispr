import AppKit
import Foundation
import Testing
@testable import MyWhispr

@Suite("Meeting recording check-ins")
struct MeetingCheckInTests {
    private var defaults: MeetingCheckInConfiguration { .init() }

    @Test func silenceWarnsThenStopsAtDeadline() {
        var monitor = MeetingCheckIn(now: 0, configuration: defaults)
        let shouldStopAt179_99 = monitor.tick(now: 179.99, configuration: defaults)
        #expect(!shouldStopAt179_99)
        #expect(monitor.prompt == nil)
        let shouldStopAt180 = monitor.tick(now: 180, configuration: defaults)
        #expect(!shouldStopAt180)
        #expect(monitor.prompt == .silence(deadline: 240))
        let shouldStopAt239_99 = monitor.tick(now: 239.99, configuration: defaults)
        #expect(!shouldStopAt239_99)
        let shouldStopAt240 = monitor.tick(now: 240, configuration: defaults)
        #expect(shouldStopAt240)
    }

    @Test func audioReturningAtDeadlineCancelsStop() {
        var monitor = MeetingCheckIn(now: 0, configuration: defaults)
        _ = monitor.tick(now: 180, configuration: defaults)
        monitor.recordActivity(level: defaults.activityThreshold, now: 240)
        let shouldStopAt240 = monitor.tick(now: 240, configuration: defaults)
        #expect(!shouldStopAt240)
        #expect(monitor.prompt == nil)
        let shouldStopAt419 = monitor.tick(now: 419, configuration: defaults)
        #expect(!shouldStopAt419)
        #expect(monitor.prompt == nil)
        _ = monitor.tick(now: 420, configuration: defaults)
        #expect(monitor.prompt == .silence(deadline: 480))
    }

    @Test func faintNoiseDoesNotCancelWarning() {
        var monitor = MeetingCheckIn(now: 0, configuration: defaults)
        _ = monitor.tick(now: 180, configuration: defaults)
        monitor.recordActivity(level: defaults.activityThreshold / 2, now: 239)
        monitor.recordActivity(level: .nan, now: 239)
        let shouldStopAt240 = monitor.tick(now: 240, configuration: defaults)
        #expect(shouldStopAt240)
    }

    @Test func stillRecordingResetsSilenceAndReminderClocks() {
        var monitor = MeetingCheckIn(now: 0, configuration: defaults)
        _ = monitor.tick(now: 180, configuration: defaults)
        monitor.keepRecording(now: 220)
        #expect(monitor.prompt == nil)
        let shouldStopAt399 = monitor.tick(now: 399, configuration: defaults)
        #expect(!shouldStopAt399)
        #expect(monitor.prompt == nil)
        _ = monitor.tick(now: 400, configuration: defaults)
        #expect(monitor.prompt == .silence(deadline: 460))
    }

    @Test func hourlyReminderNeverStopsAnActiveMeeting() {
        var monitor = MeetingCheckIn(now: 0, configuration: defaults)
        monitor.recordActivity(level: 0.5, now: 3599)
        _ = monitor.tick(now: 3599, configuration: defaults)
        #expect(monitor.prompt == nil)
        let shouldStopAt3600 = monitor.tick(now: 3600, configuration: defaults)
        #expect(!shouldStopAt3600)
        #expect(monitor.prompt == .duration)
        monitor.recordActivity(level: 0.5, now: 7200)
        let shouldStopAt7200 = monitor.tick(now: 7200, configuration: defaults)
        #expect(!shouldStopAt7200)
        #expect(monitor.prompt == .duration)
        monitor.keepRecording(now: 7200)
        monitor.recordActivity(level: 0.5, now: 10799)
        _ = monitor.tick(now: 10799, configuration: defaults)
        #expect(monitor.prompt == nil)
        _ = monitor.tick(now: 10800, configuration: defaults)
        #expect(monitor.prompt == .duration)
    }

    @Test func silenceTakesPrecedenceOverUnansweredHourlyPrompt() {
        var monitor = MeetingCheckIn(now: 0, configuration: defaults)
        monitor.recordActivity(level: 1, now: 3600)
        _ = monitor.tick(now: 3600, configuration: defaults)
        #expect(monitor.prompt == .duration)
        _ = monitor.tick(now: 3780, configuration: defaults)
        #expect(monitor.prompt == .silence(deadline: 3840))
        let shouldStopAt3840 = monitor.tick(now: 3840, configuration: defaults)
        #expect(shouldStopAt3840)
    }

    @Test func delayedFirstTickGivesFullWarningTime() {
        var monitor = MeetingCheckIn(now: 0, configuration: defaults)
        let shouldStopAt9000 = monitor.tick(now: 9000, configuration: defaults)
        #expect(!shouldStopAt9000)
        #expect(monitor.prompt == .silence(deadline: 9060))
    }

    @Test func changingPolicyCancelsPendingStopAndStartsFresh() {
        var monitor = MeetingCheckIn(now: 0, configuration: defaults)
        _ = monitor.tick(now: 180, configuration: defaults)
        var changed = defaults
        changed.countdownSeconds = 120
        let shouldStopAt240 = monitor.tick(now: 240, configuration: changed)
        #expect(!shouldStopAt240)
        #expect(monitor.prompt == nil)
        _ = monitor.tick(now: 420, configuration: changed)
        #expect(monitor.prompt == .silence(deadline: 540))
    }

    @Test func silenceCanAskWithoutAutomaticStopping() {
        var config = defaults
        config.autoStopEnabled = false
        var monitor = MeetingCheckIn(now: 0, configuration: config)
        _ = monitor.tick(now: 180, configuration: config)
        #expect(monitor.prompt == .silence(deadline: nil))
        let shouldStopAt10000 = monitor.tick(now: 10000, configuration: config)
        #expect(!shouldStopAt10000)
    }

    @Test func disablingBothChecksLeavesMeetingAlone() {
        var config = defaults
        config.silenceEnabled = false
        config.remindersEnabled = false
        var monitor = MeetingCheckIn(now: 0, configuration: config)
        let shouldStopAt100000 = monitor.tick(now: 100000, configuration: config)
        #expect(!shouldStopAt100000)
        #expect(monitor.prompt == nil)
    }

    @Test func aNewMeetingDoesNotInheritAnOldWarning() {
        var monitor = MeetingCheckIn(now: 0, configuration: defaults)
        _ = monitor.tick(now: 180, configuration: defaults)
        monitor = MeetingCheckIn(now: 200, configuration: defaults)
        let shouldStopAt240 = monitor.tick(now: 240, configuration: defaults)
        #expect(!shouldStopAt240)
        #expect(monitor.prompt == nil)
    }

    @Test func customTimingIsUsed() {
        var config = defaults
        config.reminderMinutes = 15
        config.silenceMinutes = 5
        config.countdownSeconds = 30
        var monitor = MeetingCheckIn(now: 0, configuration: config)
        _ = monitor.tick(now: 180, configuration: config)
        #expect(monitor.prompt == nil)
        _ = monitor.tick(now: 300, configuration: config)
        #expect(monitor.prompt == .silence(deadline: 330))
        monitor.keepRecording(now: 310)
        monitor.recordActivity(level: 1, now: 1210)
        _ = monitor.tick(now: 1210, configuration: config)
        #expect(monitor.prompt == .duration)
    }

    @Test func settingsDecodePartiallyAndClampUnsafeTiming() throws {
        let config = try JSONDecoder().decode(MeetingCheckInConfiguration.self, from: Data(
            #"{"reminderMinutes":0,"silenceMinutes":-1,"countdownSeconds":0,"silenceThresholdDB":99}"#.utf8
        ))
        #expect(config.reminderMinutes == 15)
        #expect(config.silenceMinutes == 1)
        #expect(config.countdownSeconds == 15)
        #expect(config.silenceThresholdDB == -24)
        #expect(config.remindersEnabled)
    }

    @Test @MainActor func recordingBadgeHasOpaqueRedBackgroundAndWhiteText() throws {
        let image = MeetingMenuBarIndicator.image(elapsed: 3661)
        #expect(!image.isTemplate)
        #expect(image.size.width > 90)
        #expect(image.size.height == 20)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: ".build/mywhispr-recording-badge.png"))
        var redPixels = 0
        var whitePixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                if c.redComponent > 0.6 && c.greenComponent < 0.2 { redPixels += 1 }
                if c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9 { whitePixels += 1 }
            }
        }
        #expect(redPixels > 100)
        #expect(whitePixels > 20)
    }
}
