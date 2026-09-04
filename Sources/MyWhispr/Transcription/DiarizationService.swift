import FluidAudio
import Foundation

actor DiarizationService {
    func diarize(audioURL: URL, progress: ProgressReporter? = nil) async throws -> [SpeakerInterval] {
        let manager = OfflineDiarizerManager()
        let result = try await manager.process(audioURL) { completed, total in
            progress?(.running, total > 0 ? Double(completed) / Double(total) : nil)
        }
        progress?(.running, 1)
        return result.segments.map {
            SpeakerInterval(
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds),
                speaker: Self.displayName(for: $0.speakerId)
            )
        }
    }

    private static func displayName(for identifier: String) -> String {
        let digits = identifier.filter(\.isNumber)
        return "Speaker \(Int(digits) ?? 1)"
    }
}

struct SpeakerInterval: Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String
}

enum MeetingTranscriptMerger {
    static func merge(
        microphone: [TranscriptSegment],
        system: [TranscriptSegment],
        microphoneSpeakers: [SpeakerInterval] = [],
        systemSpeakers: [SpeakerInterval] = []
    ) -> [TranscriptSegment] {
        let microphoneNames = orderedSpeakerNames(in: microphoneSpeakers)
        let microphoneMap: [String: String]
        if microphoneNames.count == 1, let only = microphoneNames.first {
            // MyWhispr is a personal recorder. One voice on its microphone keeps the
            // established “You” label; this is a product default, not voice ID.
            microphoneMap = [only: "You"]
        } else {
            microphoneMap = Dictionary(uniqueKeysWithValues: microphoneNames.enumerated().map {
                ($0.element, "Speaker \($0.offset + 1)")
            })
        }
        let systemNames = orderedSpeakerNames(in: systemSpeakers)
        let systemOffset = microphoneNames.count > 1 ? microphoneNames.count : 0
        let systemMap = Dictionary(uniqueKeysWithValues: systemNames.enumerated().map {
            ($0.element, "Speaker \(systemOffset + $0.offset + 1)")
        })

        let attributedMicrophone = microphone.map { segment in
            attributed(segment, intervals: microphoneSpeakers, names: microphoneMap, default: "You")
        }
        let attributedSystem = system.map { segment in
            var copy = segment
            copy = attributed(segment, intervals: systemSpeakers, names: systemMap, default: "Speaker \(systemOffset + 1)")
            return copy
        }
        let remoteWithoutEcho = attributedSystem.filter { remote in
            !attributedMicrophone.contains { local in
                overlaps(local, remote) && similarity(local.text, remote.text) > 0.82
            }
        }
        return (attributedMicrophone + remoteWithoutEcho).sorted {
            if $0.start == $1.start { return $0.channel == .microphone }
            return $0.start < $1.start
        }
    }

    private static func attributed(
        _ segment: TranscriptSegment,
        intervals: [SpeakerInterval],
        names: [String: String],
        default defaultName: String
    ) -> TranscriptSegment {
        var copy = segment
        let midpoint = (segment.start + segment.end) / 2
        let detected = intervals.first { midpoint >= $0.start && midpoint <= $0.end }?.speaker
        copy.speaker = detected.flatMap { names[$0] } ?? defaultName
        return copy
    }

    private static func orderedSpeakerNames(in intervals: [SpeakerInterval]) -> [String] {
        var seen: Set<String> = []
        return intervals.map(\.speaker).filter { seen.insert($0).inserted }
    }

    private static func overlaps(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        max(lhs.start, rhs.start) <= min(lhs.end, rhs.end) + 0.35
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(tokens(lhs))
        let right = Set(tokens(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
