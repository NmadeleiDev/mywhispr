import Foundation
import WhisperKit

actor WhisperKitEngine: TranscriptionEngine {
    private var pipeline: WhisperKit?
    private var loadedModelID: String?

    func prepare(modelID: String, progress: ProgressReporter?) async throws {
        guard loadedModelID != modelID || pipeline == nil else {
            progress?(.running, nil)
            return
        }
        pipeline = nil
        loadedModelID = nil
        // WhisperKit's initialiser reports no progress of its own, so the honest
        // report is the stage without a fraction rather than a number that stands
        // still. See `TranscriptionStage`.
        let fetching = !ModelStorage.isInstalled(modelID: modelID, engine: .whisperKit)
        progress?(fetching ? .downloadingModel : .loadingModel, nil)
        // `downloadBase` is not optional in practice: without it WhisperKit's Hub
        // client writes models into `~/Documents/huggingface`, a folder the owner
        // sees and may be syncing to iCloud. See `ModelStorage`.
        try FileManager.default.createDirectory(
            at: ModelStorage.whisperKitBase,
            withIntermediateDirectories: true
        )
        let config = WhisperKitConfig(
            model: modelID,
            downloadBase: ModelStorage.whisperKitBase,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true,
            useBackgroundDownloadSession: false
        )
        pipeline = try await WhisperKit(config)
        loadedModelID = modelID
        progress?(.running, nil)
    }

    func transcribe(
        audioURL: URL,
        profile: TranscriptionProfile,
        channel: AudioChannel,
        progress: ProgressReporter?
    ) async throws -> TranscriptionResult {
        try await prepare(modelID: profile.modelID, progress: progress)
        guard let pipeline else { throw TranscriptionEngineError.unsupportedModel(profile.modelID) }

        let language: String? = switch profile.language {
        case .automatic: nil
        case .fixed(let code): code
        }
        let options = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let inputOptions = AudioInputOptions(
            channelMode: .sumChannels(nil),
            audioLoadingMode: .incremental
        )
        let results = try await pipeline.transcribe(
            audioPath: audioURL.path,
            audioInputOptions: inputOptions,
            decodeOptions: options
        ) { update in
            let elapsed = update.timings.inputAudioSeconds
            progress?(.running, elapsed > 0 ? min(0.98, update.timings.tokensPerSecond / 100) : 0.1)
            return !Task.isCancelled
        }

        let segments = results.flatMap(\.segments).map { segment in
            TranscriptSegment(
                id: UUID(),
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end),
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: channel == .microphone ? "You" : "Speaker 1",
                channel: channel
            )
        }.filter { !$0.text.isEmpty }
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionEngineError.noSpeech }
        progress?(.running, 1)
        return TranscriptionResult(
            text: text,
            detectedLanguage: results.first?.language,
            segments: segments.isEmpty ? [
                TranscriptSegment(
                    id: UUID(), start: 0, end: 0, text: text,
                    speaker: channel == .microphone ? "You" : "Speaker 1", channel: channel
                )
            ] : segments
        )
    }

    func unload() async {
        pipeline = nil
        loadedModelID = nil
    }
}
