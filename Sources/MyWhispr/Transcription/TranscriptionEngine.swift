import Foundation

/// What a long-running transcription job is doing right now.
///
/// The stages exist because they are not interchangeable to the person waiting.
/// Downloading a 600 MB model on first use takes minutes and has a real fraction;
/// transcription takes seconds. Reporting both as one number made the HUD say
/// "Transcribing 0%" for the entire download — technically the job had started, and
/// completely wrong about what was happening.
enum TranscriptionStage: Sendable, Equatable {
    case downloadingModel
    case loadingModel
    case running
}

/// `nil` means the work is real but unmeasurable, which is honest for a load step
/// that reports nothing. A fabricated fraction is worse than a spinner.
typealias ProgressReporter = @Sendable (TranscriptionStage, Double?) -> Void

protocol TranscriptionEngine: Sendable {
    func prepare(modelID: String, progress: ProgressReporter?) async throws
    func transcribe(
        audioURL: URL,
        profile: TranscriptionProfile,
        channel: AudioChannel,
        progress: ProgressReporter?
    ) async throws -> TranscriptionResult
    func unload() async
}

actor TranscriptionService {
    private let fluidAudio = FluidAudioEngine()
    private let whisperKit = WhisperKitEngine()

    func prepare(profile: TranscriptionProfile, progress: ProgressReporter? = nil) async throws {
        try await engine(for: profile.engine).prepare(modelID: profile.modelID, progress: progress)
    }

    func transcribe(
        audioURL: URL,
        profile: TranscriptionProfile,
        vocabulary: [String] = [],
        channel: AudioChannel,
        progress: ProgressReporter? = nil
    ) async throws -> TranscriptionResult {
        let result = try await engine(for: profile.engine).transcribe(
            audioURL: audioURL,
            profile: profile,
            channel: channel,
            progress: progress
        )
        // Applied here rather than in either engine so both workflows and both
        // engines get the same treatment, and so the owner's word list has exactly
        // one place where it takes effect.
        return VocabularyCorrector.apply(vocabulary, to: result)
    }

    func unload(engine identifier: EngineIdentifier) async {
        await engine(for: identifier).unload()
    }

    private func engine(for identifier: EngineIdentifier) -> any TranscriptionEngine {
        switch identifier {
        case .fluidAudio: fluidAudio
        case .whisperKit: whisperKit
        }
    }
}

enum TranscriptionEngineError: LocalizedError, Equatable {
    case unsupportedModel(String)
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .unsupportedModel(let id): "The selected model is not supported: \(id)."
        case .noSpeech: "No speech was detected."
        }
    }
}
