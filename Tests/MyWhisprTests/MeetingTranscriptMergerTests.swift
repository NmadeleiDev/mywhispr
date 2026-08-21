import Foundation
import Testing
@testable import MyWhispr

@Suite("Meeting transcript merge")
struct MeetingTranscriptMergerTests {
    @Test func attributesRemoteSpeakersAndKeepsChronology() {
        let local = TranscriptSegment(
            id: UUID(), start: 2, end: 3, text: "My update", speaker: "You", channel: .microphone
        )
        let remote = TranscriptSegment(
            id: UUID(), start: 0, end: 1, text: "Welcome", speaker: "Speaker 1", channel: .system
        )
        let result = MeetingTranscriptMerger.merge(
            microphone: [local],
            system: [remote],
            speakers: [SpeakerInterval(start: 0, end: 1.2, speaker: "Speaker 2")]
        )
        #expect(result.map(\.speaker) == ["Speaker 2", "You"])
    }

    @Test func removesStrongEchoDuplicates() {
        let local = TranscriptSegment(
            id: UUID(), start: 1, end: 2, text: "The release is ready today", speaker: "You", channel: .microphone
        )
        let echo = TranscriptSegment(
            id: UUID(), start: 1.1, end: 2.1, text: "the release is ready today", speaker: "Speaker 1", channel: .system
        )
        let result = MeetingTranscriptMerger.merge(microphone: [local], system: [echo], speakers: [])
        #expect(result.count == 1)
        #expect(result[0].channel == .microphone)
    }
}
