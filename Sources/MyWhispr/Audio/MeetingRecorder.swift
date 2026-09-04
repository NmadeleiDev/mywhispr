import Foundation

@MainActor
final class MeetingRecorder {
    private let microphone = MicrophoneRecorder()
    private let systemAudio = SystemAudioTapRecorder()
    private(set) var directoryURL: URL?

    /// The meeting's microphone level, for the recording indicator.
    var levels: AudioLevelRelay { microphone.levels }

    func start(directoryURL: URL) throws -> MeetingCaptureMode {
        let microphoneURL = directoryURL.appending(path: "microphone.caf")
        let systemURL = directoryURL.appending(path: "system.caf")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let mode: MeetingCaptureMode
        do {
            try systemAudio.start(outputURL: systemURL)
            mode = .microphoneAndSystem
        } catch {
            // Mac audio is an enhancement for calls, not a prerequisite for a room
            // conversation. The caller surfaces this mode so the missing source is
            // never mistaken for a complete dual-track capture.
            mode = .microphoneOnly(reason: error.localizedDescription)
        }
        do {
            try microphone.start(outputURL: microphoneURL)
            self.directoryURL = directoryURL
            return mode
        } catch {
            _ = systemAudio.stop()
            microphone.cancel()
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    func stop() -> MeetingAudioFiles? {
        guard let directoryURL else { return nil }
        // Both tracks are stopped before either result is judged. Returning early on
        // the one that failed would leave the other still recording, with no handle
        // left to stop it by — an hour-long meeting that cannot be ended.
        let microphoneCapture = microphone.stop()
        let systemCapture = systemAudio.stop()
        self.directoryURL = nil
        // The microphone is the required meeting record. System audio is optional
        // and remains optional in the value handed to every downstream consumer.
        guard let microphoneCapture else { return nil }
        return MeetingAudioFiles(
            directoryURL: directoryURL,
            microphoneURL: microphoneCapture.url,
            systemURL: systemCapture?.url,
            microphoneDuration: microphoneCapture.duration,
            duration: max(microphoneCapture.duration, systemCapture?.duration ?? 0)
        )
    }
}

struct MeetingAudioFiles: Sendable {
    let directoryURL: URL
    let microphoneURL: URL
    let systemURL: URL?
    /// The microphone is the required source and therefore the clock used for the
    /// minimum useful recording rule. Optional system capture can start slightly
    /// earlier and must not turn a nine-second meeting into a retained one.
    let microphoneDuration: TimeInterval
    let duration: TimeInterval
}

enum MeetingRecordingPolicy {
    static let minimumDuration: TimeInterval = 10

    /// A recording at the exact boundary is useful; only recordings below it are
    /// accidental starts that should disappear without entering transcription.
    static func shouldDiscard(microphoneDuration: TimeInterval) -> Bool {
        microphoneDuration < minimumDuration
    }
}

enum MeetingCaptureMode: Equatable, Sendable {
    case microphoneAndSystem
    case microphoneOnly(reason: String)
}
