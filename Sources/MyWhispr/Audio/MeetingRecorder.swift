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
        // Both tracks are stopped before either result is judged. Returning early on
        // the one that failed would leave the other still recording, with no handle
        // left to stop it by — an hour-long meeting that cannot be ended.
        let microphoneCapture = microphone.stop()
        let systemCapture = systemAudio.stop()
        self.directoryURL = nil
        // One track is enough. A meeting where nothing played on this Mac, or where
        // the input device was pulled part-way through, still has a recording worth
        // transcribing; demanding both is what turns a partial meeting into a lost
        // one. A track that produced nothing is named anyway and skipped downstream,
        // where "this file holds no speech" is already an ordinary outcome.
        guard microphoneCapture != nil || systemCapture != nil else { return nil }
        return MeetingAudioFiles(
            directoryURL: directoryURL,
            microphoneURL: microphoneCapture?.url ?? directoryURL.appending(path: "microphone.caf"),
            systemURL: systemCapture?.url ?? directoryURL.appending(path: "system.caf"),
            duration: max(microphoneCapture?.duration ?? 0, systemCapture?.duration ?? 0)
        )
    }
}

struct MeetingAudioFiles: Sendable {
    let directoryURL: URL
    let microphoneURL: URL
    let systemURL: URL
    let duration: TimeInterval
}
