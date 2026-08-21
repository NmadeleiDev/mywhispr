import AVFoundation
import Foundation

@MainActor
final class MicrophoneRecorder {
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var startedAt: Date?
    private(set) var outputURL: URL?

    /// Realtime-safe hand-off of the input level. Read this on a timer rather than
    /// expecting callbacks: the tap cannot call back into main-actor code.
    let levels = AudioLevelRelay()

    func start(outputURL: URL? = nil) throws {
        guard !engine.isRunning else { throw AudioCaptureError.alreadyRecording }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }

        let url = outputURL ?? FileManager.default.temporaryDirectory
            .appending(path: "mywhispr-\(UUID().uuidString).caf")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fileWriter = try AudioFileWriter(
            url: url,
            settings: format.settings,
            label: "app.mywhispr.microphone.writer"
        )
        writer = fileWriter
        self.outputURL = url
        startedAt = Date()

        levels.reset()
        // Captured explicitly and locally. Nothing main-actor-isolated may be touched
        // in here: this block runs on a realtime audio thread, and `self` is
        // `@MainActor`, so reaching for it traps under Swift 6's isolation checks.
        //
        // `@Sendable` is the point, not decoration: it forces this closure out of the
        // enclosing type's main-actor isolation, so the compiler rejects main-actor
        // access here instead of the app trapping on the first buffer. That is
        // exactly how the previous crash got in — a `static` helper on this
        // `@MainActor` class looked harmless and was not.
        let sink = fileWriter
        let relay = levels
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable buffer, _ in
            relay.store(PCMLevel.rms(buffer))
            sink.writeCopy(of: buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> CapturedAudio? {
        guard engine.isRunning, let outputURL else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Flush before returning: the caller hands this file straight to a
        // transcription engine, so every buffer must already be on disk.
        writer?.finish()
        writer = nil
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        return CapturedAudio(url: outputURL, duration: duration)
    }

    func cancel() {
        let capture = stop()
        if let url = capture?.url { try? FileManager.default.removeItem(at: url) }
    }

}

struct CapturedAudio: Sendable {
    let url: URL
    let duration: TimeInterval
}

enum AudioCaptureError: LocalizedError {
    case alreadyRecording
    case microphoneUnavailable
    case systemAudioUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already active."
        case .microphoneUnavailable: "No usable microphone is available."
        case .systemAudioUnavailable(let status): "System audio capture failed (\(status))."
        }
    }
}
