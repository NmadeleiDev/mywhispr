import AVFoundation
import Foundation
import Testing
@testable import MyWhispr

@Suite("Audio probe")
struct AudioProbeTests {
    /// Writes a mono 16 kHz float file whose samples come from `sample`.
    private func makeFile(
        seconds: Double = 0.5,
        sample: (Int) -> Float
    ) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "MyWhisprProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "track.caf")

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) { channel[index] = sample(index) }
        try file.write(from: buffer)
        return url
    }

    @Test("A track of pure silence is recognised as silent")
    func detectsDigitalSilence() throws {
        let url = try makeFile { _ in 0 }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(AudioProbe.peakAmplitude(of: url) == 0)
        #expect(AudioProbe.isSilent(url))
    }

    @Test("A track with a tone is not silent")
    func detectsSignal() throws {
        let url = try makeFile { index in
            0.25 * sin(2 * .pi * 440 * Float(index) / 16_000)
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(AudioProbe.peakAmplitude(of: url) > 0.2)
        #expect(!AudioProbe.isSilent(url))
    }

    @Test("Very quiet speech is not mistaken for silence")
    func quietSignalSurvives() throws {
        // A whisper at the far end of a room lands far above this. The threshold
        // exists to catch tracks that are literally zero, and must never be an
        // excuse to skip transcribing someone who spoke softly.
        let url = try makeFile { index in
            0.002 * sin(2 * .pi * 220 * Float(index) / 16_000)
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!AudioProbe.isSilent(url))
    }

    @Test("An unreadable file reports no signal rather than crashing")
    func missingFileIsHandled() {
        let url = URL.temporaryDirectory.appending(path: "MyWhisprProbe-missing-\(UUID().uuidString).caf")
        #expect(AudioProbe.peakAmplitude(of: url) == 0)
    }

    @Test("A track longer than one read block is scanned to the end")
    func scansPastTheFirstBlock() throws {
        // The probe reads in 65,536-frame blocks; a signal that only appears after
        // the first block must still be found.
        let url = try makeFile(seconds: 12) { index in
            index > 100_000 ? 0.3 : 0
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!AudioProbe.isSilent(url))
    }
}
