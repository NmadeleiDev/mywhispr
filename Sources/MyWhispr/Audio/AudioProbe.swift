import AVFoundation
import Foundation

/// Cheap questions about a recorded file, answered without loading a speech model.
enum AudioProbe {
    /// Below this, a track is silence rather than quiet speech.
    ///
    /// −80 dBFS is far under anything a microphone produces in a real room — the
    /// quietest room tone in testing sat near −60 — so this only catches tracks that
    /// are genuinely empty, which is what a Mac with nothing playing records.
    static let silenceThreshold: Float = 0.0001

    /// The largest absolute sample in the file, or 0 when it cannot be read.
    ///
    /// Reads in blocks so an hour-long meeting is not decoded into memory at once.
    static func peakAmplitude(of url: URL) -> Float {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let format = file.processingFormat
        let blockSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else { return 0 }

        var peak: Float = 0
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: blockSize)
            } catch {
                break
            }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for index in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(samples[index]))
                }
            }
        }
        return peak
    }

    /// Whether the file holds no audible signal at all.
    static func isSilent(_ url: URL) -> Bool {
        peakAmplitude(of: url) < silenceThreshold
    }
}
