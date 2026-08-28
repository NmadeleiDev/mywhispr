import AVFoundation
import Foundation

@MainActor
final class MicrophoneRecorder {
    private struct MicrophoneTake {
        let engine: AVAudioEngine
        let writer: AudioFileWriter
        let outputURL: URL
        let startedAt: Date
    }

    private let makeEngine: () -> AVAudioEngine
    private let startEngine: (AVAudioEngine) throws -> Void
    private var activeTake: MicrophoneTake?

    /// Realtime-safe hand-off of the input level. Read this on a timer rather than
    /// expecting callbacks: the tap cannot call back into main-actor code.
    let levels = AudioLevelRelay()

    init(
        makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
        startEngine: @escaping (AVAudioEngine) throws -> Void = { try $0.start() }
    ) {
        self.makeEngine = makeEngine
        self.startEngine = startEngine
    }

    func start(outputURL requestedURL: URL? = nil) throws {
        guard activeTake == nil else { throw AudioCaptureError.alreadyRecording }

        let engine = makeEngine()
        let input = engine.inputNode
        // The input scope is the hardware format. AVAudioInputNode does not convert
        // while connected to a device, so its output and tap must use this exact
        // format rather than inheriting an output scope cached before a route change.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }

        let url = requestedURL ?? FileManager.default.temporaryDirectory
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
        do {
            try startEngine(engine)
            activeTake = MicrophoneTake(
                engine: engine,
                writer: fileWriter,
                outputURL: url,
                startedAt: Date()
            )
        } catch {
            input.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            fileWriter.finish()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() -> CapturedAudio? {
        guard let take = endTake() else { return nil }
        return CapturedAudio(
            url: take.outputURL,
            duration: Date().timeIntervalSince(take.startedAt)
        )
    }

    func cancel() {
        if let take = endTake() { try? FileManager.default.removeItem(at: take.outputURL) }
    }

    @discardableResult
    private func endTake() -> MicrophoneTake? {
        guard let take = activeTake else { return nil }
        activeTake = nil
        take.engine.inputNode.removeTap(onBus: 0)
        if take.engine.isRunning { take.engine.stop() }
        take.writer.finish()
        return take
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
