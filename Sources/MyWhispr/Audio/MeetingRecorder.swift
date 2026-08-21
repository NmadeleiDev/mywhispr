import Foundation

@MainActor
final class MeetingRecorder {
    private let microphone = MicrophoneRecorder()
    private let systemAudio = SystemAudioTapRecorder()
    private(set) var directoryURL: URL?

    /// The meeting's microphone level, for the recording indicator.
    var levels: AudioLevelRelay { microphone.levels }

    func start(directoryURL: URL) throws {
        let microphoneURL = directoryURL.appending(path: "microphone.caf")
        let systemURL = directoryURL.appending(path: "system.caf")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        do {
            try systemAudio.start(outputURL: systemURL)
            try microphone.start(outputURL: microphoneURL)
            self.directoryURL = directoryURL
        } catch {
            _ = systemAudio.stop()
            microphone.cancel()
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    func stop() -> MeetingAudioFiles? {
        guard let directoryURL else { return nil }
        let microphoneCapture = microphone.stop()
        let systemCapture = systemAudio.stop()
        self.directoryURL = nil
        guard let microphoneCapture, let systemCapture else { return nil }
        return MeetingAudioFiles(
            directoryURL: directoryURL,
            microphoneURL: microphoneCapture.url,
            systemURL: systemCapture.url,
            duration: max(microphoneCapture.duration, systemCapture.duration)
        )
    }
}

struct MeetingAudioFiles: Sendable {
    let directoryURL: URL
    let microphoneURL: URL
    let systemURL: URL
    let duration: TimeInterval
}
