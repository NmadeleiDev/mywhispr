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
        speakers: [SpeakerInterval]
    ) -> [TranscriptSegment] {
        let attributedSystem = system.map { segment in
            var copy = segment
            let midpoint = (segment.start + segment.end) / 2
            copy.speaker = speakers.first(where: { midpoint >= $0.start && midpoint <= $0.end })?.speaker
                ?? "Speaker 1"
            return copy
        }
        let remoteWithoutEcho = attributedSystem.filter { remote in
            !microphone.contains { local in
                overlaps(local, remote) && similarity(local.text, remote.text) > 0.82
            }
        }
        return (microphone + remoteWithoutEcho).sorted {
            if $0.start == $1.start { return $0.channel == .microphone }
            return $0.start < $1.start
        }
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
