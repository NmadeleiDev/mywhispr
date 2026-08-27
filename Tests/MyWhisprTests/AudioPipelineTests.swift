import AVFoundation
import Foundation
import Testing
@testable import MyWhispr

/// These cover the pieces the realtime audio threads touch.
///
/// Two crashes and one data race came from this area, all of the same shape: code
/// reachable from a realtime callback quietly depending on main-actor state, or on
/// state another thread was mutating. Every type here is deliberately free of actor
/// isolation, and these tests exercise them from outside the main actor so that a
/// regression shows up as a failure rather than as a trap during a recording.
@Suite("Realtime audio hand-off")
struct AudioLevelRelayTests {
    @Test func reportsThePeakSinceTheLastRead() {
        let relay = AudioLevelRelay()
        relay.store(0.2)
        relay.store(0.9)
        relay.store(0.4)

        // Peak, not most-recent: the interface reads slower than the tap writes, so
        // a transient must not be able to slip between two reads.
        #expect(relay.drain() == 0.9)
        #expect(relay.drain() == 0)
    }

    @Test func keepsTheFirstErrorAndClearsItOnceRead() {
        struct First: Error {}
        struct Second: Error {}
        let relay = AudioLevelRelay()
        relay.store(error: First())
        relay.store(error: Second())

        #expect(relay.takeError() is First)
        #expect(relay.takeError() == nil)
    }

    @Test func resetClearsBothLevelAndError() {
        struct Failure: Error {}
        let relay = AudioLevelRelay()
        relay.store(0.7)
        relay.store(error: Failure())
        relay.reset()

        #expect(relay.drain() == 0)
        #expect(relay.takeError() == nil)
    }

    /// The relay is written from a realtime thread and read from the main actor.
    @Test func survivesConcurrentWritersAndReaders() async {
        let relay = AudioLevelRelay()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<500 { relay.store(Float.random(in: 0...1)) }
                }
            }
            group.addTask {
                for _ in 0..<500 { _ = relay.drain() }
            }
        }
        // Reaching here without tripping the thread sanitiser or crashing is the
        // assertion; drain simply must remain in range.
        let value = relay.drain()
        #expect(value >= 0 && value <= 1)
    }
}

@Suite("Level measurement")
struct PCMLevelTests {
    private func buffer(filledWith value: Float, frames: AVAudioFrameCount = 512) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData!.pointee
        for index in 0..<Int(frames) { channel[index] = value }
        return buffer
    }

    /// `PCMLevel` lives outside `MicrophoneRecorder` precisely so it is callable
    /// from a realtime thread. Calling it here, off the main actor, is the point.
    @Test func silenceMeasuresZeroAndLoudAudioSaturates() {
        #expect(PCMLevel.rms(buffer(filledWith: 0)) == 0)
        #expect(PCMLevel.rms(buffer(filledWith: 1.0)) == 1)
    }

    @Test func conversationalSpeechLandsInAVisibleRange() {
        // Normal speech RMS sits around 0.05–0.2. If the scaling ever regressed to
        // raw RMS, the waveform would look like a flat line while someone talks.
        let quiet = PCMLevel.rms(buffer(filledWith: 0.05))
        let normal = PCMLevel.rms(buffer(filledWith: 0.15))
        #expect(quiet > 0.15)
        #expect(normal > 0.5)
        #expect(normal > quiet)
    }

    @Test func emptyBufferIsSilentRatherThanUndefined() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        empty.frameLength = 0
        #expect(PCMLevel.rms(empty) == 0)
    }
}

@Suite("Buffer hand-off")
struct BufferCopyTests {
    @Test func copyIsIndependentOfItsSource() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        source.frameLength = 128
        let channel = source.floatChannelData!.pointee
        for index in 0..<128 { channel[index] = 0.5 }

        let copy = try #require(source.makeIndependentCopy())
        // A tap reuses its buffer the moment the callback returns, so a copy that
        // shared storage would be silently overwritten before it reached disk.
        for index in 0..<128 { channel[index] = -1 }

        #expect(copy.frameLength == 128)
        #expect(copy.floatChannelData!.pointee[0] == 0.5)
    }

    @Test func copyPreservesFrameLengthNotCapacity() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
        source.frameLength = 300

        let copy = try #require(source.makeIndependentCopy())
        #expect(copy.frameLength == 300)
    }
}

@Suite("Off-thread file writing")
struct AudioFileWriterTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "mywhispr-writer-\(UUID().uuidString).caf")
    }

    @Test func writesEverythingHandedOverBeforeFinishReturns() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let writer = try AudioFileWriter(url: url, settings: format.settings, label: "test.writer")

        for _ in 0..<40 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
            buffer.frameLength = 256
            writer.writeCopy(of: buffer)
        }
        writer.finish()

        // `finish` is synchronous because the caller hands this file straight to a
        // transcription engine; anything still queued would be silently lost.
        let written = try AVAudioFile(forReading: url)
        #expect(written.length == 40 * 256)
    }

    @Test func ignoresWritesAfterFinishing() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let writer = try AudioFileWriter(url: url, settings: format.settings, label: "test.writer")

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        buffer.frameLength = 128
        writer.writeCopy(of: buffer)
        writer.finish()
        writer.writeCopy(of: buffer)
        writer.finish()

        #expect(try AVAudioFile(forReading: url).length == 128)
    }

    /// The format the file ends up in is the audio's, not the caller's guess.
    ///
    /// The caller's guess is a format read from an input bus before capture began,
    /// and an input bus is free to have renegotiated with the hardware since. When
    /// the two disagreed, every write was rejected and the take came back empty —
    /// so the writer takes its format from the buffers it is actually given.
    @Test func adoptsTheFormatOfTheAudioItIsGiven() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        // Deliberately not the format the buffers arrive in.
        let stale = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let writer = try AudioFileWriter(url: url, settings: stale.settings, label: "test.writer")

        let buffer = AVAudioPCMBuffer(pcmFormat: expected, frameCapacity: 512)!
        buffer.frameLength = 512
        writer.writeCopy(of: buffer)
        writer.finish()

        let written = try AVAudioFile(forReading: url)
        #expect(written.processingFormat.sampleRate == 16_000)
        #expect(written.processingFormat.channelCount == 1)
        #expect(written.length == 512)
    }

    /// A take that captured nothing still leaves a file behind.
    ///
    /// Everything downstream is handed a path and told a recording is at it. "There
    /// is no speech in this" is an outcome each of them already handles; "there is
    /// no file" is one none of them does.
    @Test func aTakeWithNoAudioStillLeavesAReadableFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let writer = try AudioFileWriter(url: url, settings: format.settings, label: "test.writer")
        writer.finish()

        #expect(try AVAudioFile(forReading: url).length == 0)
    }

    /// Mirrors the real caller: many producers, as a realtime tap would.
    @Test func acceptsBuffersFromManyThreadsAtOnce() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let writer = try AudioFileWriter(url: url, settings: format.settings, label: "test.writer")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    for _ in 0..<25 {
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
                        buffer.frameLength = 64
                        writer.writeCopy(of: buffer)
                    }
                }
            }
        }
        writer.finish()

        #expect(try AVAudioFile(forReading: url).length == 6 * 25 * 64)
    }
}

/// The microphone recorder's lifecycle, which is where a stuck dictation came from.
///
/// The failure was not in recording: it was in *not* recording. `engine.start()`
/// threw — the input device had just been released by a meeting and Core Audio was
/// still tearing it down — and the recorder returned from that throw with its tap
/// still on bus 0. The next dictation's `installTap` then raised an Objective-C
/// exception, which is not a Swift error, so it unwound through the caller instead
/// of being handled by it and left the app showing "Listening" with nothing
/// listening. Every test here is about a take ending completely, whichever way it
/// ends, so that the next one starts from nothing.
///
/// The throwing start itself cannot be provoked from a test — it needs the audio
/// device to actually go away mid-call — so what is pinned here is the bookkeeping
/// that made the aftermath unrecoverable.
@MainActor
@Suite("Microphone recorder lifecycle")
struct MicrophoneRecorderLifecycleTests {
    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "mywhispr-tests-\(UUID().uuidString)")
            .appending(path: "take.caf")
    }

    @Test func stoppingWithoutStartingReportsNothing() {
        let recorder = MicrophoneRecorder()
        #expect(recorder.stop() == nil)
    }

    @Test func cancellingWithoutStartingIsHarmless() {
        let recorder = MicrophoneRecorder()
        recorder.cancel()
        recorder.cancel()
        #expect(recorder.stop() == nil)
    }

    @Test func aTakeIsHandedOverExactlyOnce() throws {
        let recorder = MicrophoneRecorder()
        let url = scratchURL()
        try recorder.start(outputURL: url)

        let captured = recorder.stop()
        #expect(captured?.url == url)
        // The caller owns the file from here — it transcribes it, then deletes it.
        // A second stop that handed the same URL back would point a second consumer
        // at a file the first one is entitled to have already removed.
        #expect(recorder.stop() == nil)
        recorder.cancel()

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func cancellingDiscardsTheRecording() throws {
        let recorder = MicrophoneRecorder()
        let url = scratchURL()
        try recorder.start(outputURL: url)
        recorder.cancel()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func startingWhileRecordingIsRefusedWithoutDisturbingTheTakeInProgress() throws {
        let recorder = MicrophoneRecorder()
        let url = scratchURL()
        try recorder.start(outputURL: url)

        let second = scratchURL()
        #expect(throws: AudioCaptureError.self) { try recorder.start(outputURL: second) }

        // The refused start must not have ended the live one.
        #expect(recorder.stop()?.url == url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    /// The regression proper: one recorder, used over and over, the way a day of
    /// dictating uses it. Anything left installed by take *n* is what take *n + 1*
    /// raises on.
    @Test func survivesRepeatedTakesEndedEveryWhichWay() throws {
        let recorder = MicrophoneRecorder()
        var written: [URL] = []
        for index in 0..<8 {
            let url = scratchURL()
            try recorder.start(outputURL: url)
            if index.isMultiple(of: 2) {
                #expect(recorder.stop()?.url == url)
                written.append(url)
            } else {
                recorder.cancel()
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
        }
        #expect(written.count == 4)
        for url in written { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

@MainActor
@Suite("Meeting recorder lifecycle")
struct MeetingRecorderLifecycleTests {
    /// A meeting that was never started has nothing to hand back — and, more to the
    /// point, saying so must not depend on either track having succeeded.
    @Test func stoppingWithoutStartingReportsNothing() {
        #expect(MeetingRecorder().stop() == nil)
    }
}
