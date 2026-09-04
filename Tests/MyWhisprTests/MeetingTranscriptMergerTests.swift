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
            systemSpeakers: [SpeakerInterval(start: 0, end: 1.2, speaker: "Speaker 2")]
        )
        #expect(result.map(\.speaker) == ["Speaker 1", "You"])
    }

    @Test func removesStrongEchoDuplicates() {
        let local = TranscriptSegment(
            id: UUID(), start: 1, end: 2, text: "The release is ready today", speaker: "You", channel: .microphone
        )
        let echo = TranscriptSegment(
            id: UUID(), start: 1.1, end: 2.1, text: "the release is ready today", speaker: "Speaker 1", channel: .system
        )
        let result = MeetingTranscriptMerger.merge(microphone: [local], system: [echo])
        #expect(result.count == 1)
        #expect(result[0].channel == .microphone)
    }

    @Test func separatesPeopleSharingTheMicrophone() {
        let first = TranscriptSegment(
            id: UUID(), start: 0, end: 1, text: "Hello", speaker: "You", channel: .microphone
        )
        let second = TranscriptSegment(
            id: UUID(), start: 2, end: 3, text: "Welcome", speaker: "You", channel: .microphone
        )
        let result = MeetingTranscriptMerger.merge(
            microphone: [first, second],
            system: [],
            microphoneSpeakers: [
                SpeakerInterval(start: 0, end: 1.2, speaker: "Speaker 0"),
                SpeakerInterval(start: 1.8, end: 3.2, speaker: "Speaker 1"),
            ]
        )

        #expect(result.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    @Test func speakerNamesDoNotCollideAcrossMicrophoneAndMacAudio() {
        let room = TranscriptSegment(
            id: UUID(), start: 0, end: 1, text: "From the room", speaker: "You", channel: .microphone
        )
        let remote = TranscriptSegment(
            id: UUID(), start: 2, end: 3, text: "From the call", speaker: "Speaker 1", channel: .system
        )
        let result = MeetingTranscriptMerger.merge(
            microphone: [room],
            system: [remote],
            microphoneSpeakers: [
                SpeakerInterval(start: 0, end: 0.7, speaker: "Speaker 0"),
                SpeakerInterval(start: 0.8, end: 1.2, speaker: "Speaker 1"),
            ],
            systemSpeakers: [SpeakerInterval(start: 2, end: 3.2, speaker: "Speaker 0")]
        )

        #expect(result.map(\.speaker) == ["Speaker 1", "Speaker 3"])
    }
}
