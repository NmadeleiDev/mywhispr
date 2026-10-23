import Foundation

/// Recording supervision uses a monotonic clock, independent of UI visibility.
/// A warning always gets its full grace period, including after sleep or a delayed tick.
struct MeetingCheckIn: Equatable {
    enum Prompt: Equatable {
        case duration
        case silence(deadline: TimeInterval?)
    }

    private(set) var prompt: Prompt?
    private var lastActivity: TimeInterval
    private var lastReminder: TimeInterval
    private var configuration: MeetingCheckInConfiguration

    init(now: TimeInterval, configuration: MeetingCheckInConfiguration) {
        lastActivity = now
        lastReminder = now
        self.configuration = configuration
    }

    mutating func recordActivity(level: Float, now: TimeInterval) {
        guard level.isFinite, level >= configuration.activityThreshold else { return }
        lastActivity = now
        if case .silence = prompt { prompt = nil }
    }

    /// Returns true only while an unanswered silence warning reaches its deadline.
    mutating func tick(now: TimeInterval, configuration newConfiguration: MeetingCheckInConfiguration) -> Bool {
        if configuration != newConfiguration {
            // Editing a running meeting's policy starts fresh, never shortens an
            // already displayed warning or immediately stops a recording.
            configuration = newConfiguration
            keepRecording(now: now)
        }
        if case .silence(let deadline) = prompt {
            return deadline.map { now >= $0 } ?? false
        }
        if configuration.silenceEnabled,
           now - lastActivity >= Double(configuration.silenceMinutes) * 60 {
            prompt = .silence(deadline: configuration.autoStopEnabled
                ? now + Double(configuration.countdownSeconds) : nil)
        } else if configuration.remindersEnabled, prompt == nil,
                  now - lastReminder >= Double(configuration.reminderMinutes) * 60 {
            prompt = .duration
            lastReminder = now
        }
        return false
    }

    mutating func keepRecording(now: TimeInterval) {
        prompt = nil
        lastActivity = now
        lastReminder = now
    }
}

struct MeetingCheckInConfiguration: Codable, Equatable, Sendable {
    var remindersEnabled = true
    var reminderMinutes = 60
    var silenceEnabled = true
    var silenceMinutes = 3
    var autoStopEnabled = true
    var countdownSeconds = 60
    /// RMS dBFS. PCMLevel scales amplitudes by four for the visible meter.
    var silenceThresholdDB = -42

    var activityThreshold: Float {
        Float(pow(10, Double(silenceThresholdDB) / 20) * 4)
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? values.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        remindersEnabled = value(.remindersEnabled, defaults.remindersEnabled)
        reminderMinutes = min(240, max(15, value(.reminderMinutes, defaults.reminderMinutes)))
        silenceEnabled = value(.silenceEnabled, defaults.silenceEnabled)
        silenceMinutes = min(30, max(1, value(.silenceMinutes, defaults.silenceMinutes)))
        autoStopEnabled = value(.autoStopEnabled, defaults.autoStopEnabled)
        countdownSeconds = min(300, max(15, value(.countdownSeconds, defaults.countdownSeconds)))
        silenceThresholdDB = min(-24, max(-60, value(.silenceThresholdDB, defaults.silenceThresholdDB)))
    }
}
