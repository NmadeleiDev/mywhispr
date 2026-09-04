import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class MeetingPlaybackController {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var microphonePlayer: AVAudioPlayer?
    private var systemPlayer: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    func load(directoryURL: URL) throws {
        stop()
        let microphone = try AVAudioPlayer(contentsOf: directoryURL.appending(path: "microphone.caf"))
        microphone.prepareToPlay()
        microphonePlayer = microphone
        let systemURL = directoryURL.appending(path: "system.caf")
        if FileManager.default.fileExists(atPath: systemURL.path) {
            let system = try AVAudioPlayer(contentsOf: systemURL)
            system.prepareToPlay()
            systemPlayer = system
        }
        duration = max(microphone.duration, systemPlayer?.duration ?? 0)
        currentTime = 0
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let microphonePlayer else { return }
        if currentTime >= duration { seek(to: 0) }
        let deviceTime = max(microphonePlayer.deviceCurrentTime, systemPlayer?.deviceCurrentTime ?? 0) + 0.05
        microphonePlayer.play(atTime: deviceTime)
        systemPlayer?.play(atTime: deviceTime)
        isPlaying = true
        startTicker()
    }

    func pause() {
        microphonePlayer?.pause()
        systemPlayer?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    func seek(to time: TimeInterval) {
        let bounded = min(max(0, time), duration)
        let resume = isPlaying
        microphonePlayer?.pause()
        systemPlayer?.pause()
        microphonePlayer?.currentTime = bounded
        systemPlayer?.currentTime = bounded
        currentTime = bounded
        if resume { play() }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        microphonePlayer?.stop()
        systemPlayer?.stop()
        microphonePlayer = nil
        systemPlayer = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                let time = max(
                    self.microphonePlayer?.currentTime ?? 0,
                    self.systemPlayer?.currentTime ?? 0
                )
                self.currentTime = time
                if time >= self.duration - 0.05 {
                    self.pause()
                    self.currentTime = self.duration
                    return
                }
            }
        }
    }
}
