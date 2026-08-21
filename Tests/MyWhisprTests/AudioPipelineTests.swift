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
