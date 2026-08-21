import AVFoundation
import Foundation

/// Carries the input level from the realtime audio thread to the interface.
///
/// The audio tap runs on a realtime thread with hard deadlines. It must not touch
/// main-actor state, allocate, or await — doing any of those risks a dropped buffer,
/// and under Swift 6 touching actor-isolated state there traps outright.
///
/// So the tap does the cheapest possible thing: take a lock, keep the loudest sample
/// seen, release. The interface drains that on its own schedule. Peak-since-drain
/// rather than most-recent, because the display reads slower than the tap writes and
/// a transient should not be able to slip between two reads.
final class AudioLevelRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var failure: (any Error)?

    func store(_ value: Float) {
        lock.lock()
        peak = max(peak, value)
        lock.unlock()
    }

    func store(error: any Error) {
        lock.lock()
        failure = failure ?? error
        lock.unlock()
    }

    /// Returns the loudest level since the last call and resets the peak.
    func drain() -> Float {
        lock.lock()
        defer { peak = 0; lock.unlock() }
        return peak
    }

    func takeError() -> (any Error)? {
        lock.lock()
        defer { failure = nil; lock.unlock() }
        return failure
    }

    func reset() {
        lock.lock()
        peak = 0
        failure = nil
        lock.unlock()
    }
}

/// Signal level of a PCM buffer.
///
/// Deliberately a standalone enum rather than a member of ``MicrophoneRecorder``:
/// that class is `@MainActor`, which makes even its `static` members main-actor
/// isolated, and calling one from the realtime audio tap pulls the whole tap
/// closure into main-actor isolation — where it traps.
enum PCMLevel {
    /// Root-mean-square amplitude, scaled into roughly 0...1 for speech.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?.pointee else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            sum += channel[index] * channel[index]
        }
        // ×4 lifts conversational speech into the upper half of the range; RMS for
        // normal talking sits around 0.05–0.2 and would otherwise look like silence.
        return min(1, (sum / Float(count)).squareRoot() * 4)
    }
}

extension AVAudioPCMBuffer {
    /// A deep copy sharing no storage with the receiver.
    func makeIndependentCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        let frames = Int(frameLength)
        if let source = floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
            return copy
        }
        if let source = int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
            return copy
        }
        if let source = int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
            return copy
        }
        return nil
    }
}
