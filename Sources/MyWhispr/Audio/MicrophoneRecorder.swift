import AVFoundation
import Foundation

@MainActor
final class MicrophoneRecorder {
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var startedAt: Date?
    private var outputURL: URL?
    /// Whether *this* type installed the tap that is currently on bus 0.
    ///
    /// `AVAudioNode` offers no way to ask, and installing a second tap on a bus that
    /// already has one is not an error the caller can catch — it raises an
    /// Objective-C exception from inside AVFAudio, which unwinds straight past every
    /// Swift `catch` and leaves the caller's own state half-updated. Tracking it here
    /// is what makes the tap removable on the failure paths that would otherwise
    /// leave one behind.
    private var isTapped = false

    /// Realtime-safe hand-off of the input level. Read this on a timer rather than
    /// expecting callbacks: the tap cannot call back into main-actor code.
    let levels = AudioLevelRelay()

    func start(outputURL requestedURL: URL? = nil) throws {
        guard !engine.isRunning else { throw AudioCaptureError.alreadyRecording }
        // Clear anything a previous take left behind before touching the bus. Two
        // ordinary situations get here with a tap still installed: a start that threw
        // after installing one, and a running engine the system stopped underneath
        // the app when its input device disappeared. Either way the next
        // `installTap` would raise, and an exception raised here does not merely fail
        // the dictation — it aborts the caller mid-way and strands whatever state it
        // had already published.
        discardTake()

        let input = engine.inputNode
        // Read to answer one question only — is there a usable input device at all —
        // and never trusted as *the* capture format. See the tap installation below.
        let format = input.outputFormat(forBus: 0)
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
        // `nil`, not the format read above. They are meant to be the same value, and
        // when they are not — the bus renegotiated in between, which it does after
        // the engine has been stopped and the device released — `installTap` does not
        // fail, it raises, and an Objective-C exception raised in here unwinds past
        // every `catch` in this file and out through whatever called it. `nil` asks
        // for the bus's own format, which is what was wanted, and cannot disagree
        // with itself. What lands on disk is decided by `AudioFileWriter` from the
        // buffers themselves for the same reason.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { @Sendable buffer, _ in
            relay.store(PCMLevel.rms(buffer))
            sink.writeCopy(of: buffer)
        }
        isTapped = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            // Unwind everything this call created. A microphone that is momentarily
            // unavailable — the device changed, another process grabbed it, the HAL
            // is still tearing down the meeting that just ended — is a recoverable
            // failure, and it stays recoverable only if the next attempt starts from
            // a clean recorder.
            discardTake()
            throw error
        }
    }

    func stop() -> CapturedAudio? {
        // Deliberately not conditioned on `engine.isRunning`. When the input device
        // goes away the system stops the engine without telling anyone, and a `stop`
        // that returned early there would leave the tap installed, the file open, and
        // the recorded audio unreachable.
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard let url = endTake() else { return nil }
        return CapturedAudio(url: url, duration: duration)
    }

    func cancel() {
        if let url = endTake() { try? FileManager.default.removeItem(at: url) }
    }

    /// Closes the engine, the tap, and the writer, and hands back the file that was
    /// being written, if there was one. What happens to that file is the caller's
    /// decision; every exit from a take goes through here so a tap can never outlive
    /// the take that installed it.
    @discardableResult
    private func endTake() -> URL? {
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        if engine.isRunning { engine.stop() }
        writer?.finish()
        writer = nil
        startedAt = nil
        defer { outputURL = nil }
        return outputURL
    }

    /// Ends the take and throws away whatever it captured.
    private func discardTake() {
        if let url = endTake() { try? FileManager.default.removeItem(at: url) }
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
