import Foundation
import GRDB

enum WorkflowKind: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case dictation
    case meeting
}

enum SessionState: String, Codable, DatabaseValueConvertible, Sendable {
    case recording
    case processing
    case completed
    case failed
    case interrupted
}

enum AudioChannel: String, Codable, DatabaseValueConvertible, Sendable {
    case microphone
    case system
}

enum EngineIdentifier: String, Codable, CaseIterable, Sendable {
    case fluidAudio
    case whisperKit

    var displayName: String {
        switch self {
        case .fluidAudio: "FluidAudio"
        case .whisperKit: "WhisperKit"
        }
    }
}

enum LanguageSelection: Codable, Hashable, Sendable {
    case automatic
    case fixed(String)
}

struct TranscriptionProfile: Codable, Hashable, Sendable {
    var engine: EngineIdentifier
    var modelID: String
    var language: LanguageSelection

    /// v2 payloads and older transcript snapshots stored one word list per workflow.
    /// Kept only so those lists can be folded into the single shared vocabulary on
    /// first launch — never written back. See ``SettingsStore``.
    var legacyVocabulary: [String]?

    private enum CodingKeys: String, CodingKey {
        case engine
        case modelID
        case language
        case legacyVocabulary = "vocabulary"
    }

    static let dictationDefault = TranscriptionProfile(
        engine: .fluidAudio,
        modelID: "parakeet-tdt-v3",
        language: .automatic
    )

    static let meetingDefault = TranscriptionProfile(
        engine: .whisperKit,
        modelID: "large-v3-v20240930_626MB",
        language: .automatic
    )
}

struct ModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let engine: EngineIdentifier
    let displayName: String
    let detail: String
    /// What the download costs, summed from the published repository listing for
    /// exactly the files the engine fetches — not the whole repository, which
    /// carries variants MyWhispr never asks for.
    ///
    /// It is stated before the download rather than after, because "how big is it"
    /// is the question being asked at the moment of choosing.
    let downloadBytes: Int64
    let supportsAutomaticLanguage: Bool
    let supportsWordTimestamps: Bool
    let supportsLongForm: Bool
    let license: String
    let recommendedFor: Set<WorkflowKind>
}

extension ModelDescriptor {
    static let curated: [ModelDescriptor] = [
        ModelDescriptor(
            id: "parakeet-tdt-v3",
            engine: .fluidAudio,
            displayName: "Parakeet TDT v3",
            detail: "Fast multilingual transcription on the Neural Engine",
            downloadBytes: 483_300_000,
            supportsAutomaticLanguage: true,
            supportsWordTimestamps: true,
            supportsLongForm: true,
            license: "CC-BY-4.0",
            recommendedFor: [.dictation, .meeting]
        ),
        ModelDescriptor(
            id: "sensevoice-small",
            engine: .fluidAudio,
            displayName: "SenseVoice Small",
            detail: "Broad automatic language detection across 50+ languages",
            downloadBytes: 472_469_017,
            supportsAutomaticLanguage: true,
            supportsWordTimestamps: false,
            supportsLongForm: true,
            license: "Model-specific open license",
            recommendedFor: [.dictation]
        ),
        ModelDescriptor(
            id: "tiny",
            engine: .whisperKit,
            displayName: "Whisper Tiny",
            detail: "Small and fast; best for testing",
            downloadBytes: 76_635_397,
            supportsAutomaticLanguage: true,
            supportsWordTimestamps: true,
            supportsLongForm: true,
            license: "MIT",
            recommendedFor: [.dictation]
        ),
        ModelDescriptor(
            id: "base",
            engine: .whisperKit,
            displayName: "Whisper Base",
            detail: "Balanced multilingual dictation",
            downloadBytes: 146_719_453,
            supportsAutomaticLanguage: true,
            supportsWordTimestamps: true,
            supportsLongForm: true,
            license: "MIT",
            recommendedFor: [.dictation]
        ),
        ModelDescriptor(
            id: "small",
            engine: .whisperKit,
            displayName: "Whisper Small",
            detail: "Higher accuracy with moderate latency",
            downloadBytes: 486_487_465,
            supportsAutomaticLanguage: true,
            supportsWordTimestamps: true,
            supportsLongForm: true,
            license: "MIT",
            recommendedFor: [.dictation, .meeting]
        ),
        ModelDescriptor(
            id: "large-v3-v20240930_turbo",
            engine: .whisperKit,
            displayName: "Whisper Large v3 Turbo",
            detail: "Maximum speed and accuracy on macOS",
            downloadBytes: 1_638_464_446,
            supportsAutomaticLanguage: true,
            supportsWordTimestamps: true,
            supportsLongForm: true,
            license: "MIT",
            recommendedFor: [.dictation, .meeting]
        ),
        ModelDescriptor(
            id: "large-v3-v20240930_626MB",
            engine: .whisperKit,
            displayName: "Whisper Large v3 Turbo · Compact",
            detail: "High-accuracy multilingual long-form transcription",
            downloadBytes: 626_718_238,
            supportsAutomaticLanguage: true,
            supportsWordTimestamps: true,
            supportsLongForm: true,
            license: "MIT",
            recommendedFor: [.meeting]
        ),
    ]
}

struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var speaker: String
    var channel: AudioChannel
}

struct TranscriptionResult: Codable, Sendable {
    var text: String
    var detectedLanguage: String?
    var segments: [TranscriptSegment]
}

struct SessionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "sessions"

    var id: UUID
    var kind: WorkflowKind
    var title: String
    var state: SessionState
    var startedAt: Date
    var endedAt: Date?
    var duration: TimeInterval
    var sourceApplication: String?
    var sourceBundleIdentifier: String?
    var modelSnapshot: String
    var audioRelativePath: String?
    var summary: String?
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
}

struct TranscriptSegmentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "transcriptSegments"

    var id: UUID
    var sessionID: UUID
    var position: Int
    var start: TimeInterval
    var end: TimeInterval
    var channel: AudioChannel
    var speaker: String
    var originalText: String
    var editedText: String
}

/// One turn of a conversation about a meeting.
///
/// Stored beside the transcript rather than held in memory, because a question worth
/// asking is worth still having an answer to tomorrow — and because re-asking it
/// means the model reads the whole meeting again.
struct ChatMessageRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "chatMessages"

    var id: UUID
    var sessionID: UUID
    var position: Int
    /// Only ever `user` or `assistant`. The system message is derived from the
    /// transcript and the owner's instruction at the moment of asking, so storing it
    /// would freeze a copy of both.
    var role: LocalAIMessage.Role
    var content: String
    var createdAt: Date
}

extension LocalAIMessage.Role: DatabaseValueConvertible {}

struct SessionDetail: Sendable {
    var session: SessionRecord
    var segments: [TranscriptSegmentRecord]

    var transcript: String {
        segments.map(\.editedText).joined(separator: " ")
    }

    /// The transcript written out the way it is read on screen: who spoke, when, and
    /// what they said.
    ///
    /// This is the form given to a language model. The flat `transcript` above throws
    /// away both facts a meeting turns on — a model reading it cannot answer "who
    /// said that" or "when did we get to pricing", and will cheerfully invent both.
    /// Consecutive lines from one speaker are joined into a single turn, which is how
    /// a person reads them and costs a fraction of the tokens.
    var annotatedTranscript: String {
        var turns: [String] = []
        var currentSpeaker: String?
        for segment in segments {
            let text = segment.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if segment.speaker == currentSpeaker, let previous = turns.popLast() {
                turns.append(previous + " " + text)
            } else {
                turns.append("[\(Clock.string(segment.start))] \(segment.speaker): \(text)")
                currentSpeaker = segment.speaker
            }
        }
        return turns.joined(separator: "\n")
    }
}

enum RecordingPhase: Equatable, Sendable {
    case idle
    case preparing(WorkflowKind)
    case recording(WorkflowKind, startedAt: Date)
    case stopping(WorkflowKind)
    /// The model is being fetched or loaded. Separate from `transcribing` because a
    /// first-run download runs for minutes and is the only thing happening.
    case preparingModel(WorkflowKind, isDownloading: Bool, progress: Double?)
    case transcribing(WorkflowKind, progress: Double)
    case rewriting
    case inserting
    case failed(String)
}

/// Failures that belong to a meeting as a whole rather than to one engine.
enum MeetingProcessingError: LocalizedError {
    case noSpeechInEitherTrack

    var errorDescription: String? {
        switch self {
        case .noSpeechInEitherTrack:
            "Neither your microphone nor this Mac's audio held any speech. The recording is kept — play it back to hear what was captured."
        }
    }
}
