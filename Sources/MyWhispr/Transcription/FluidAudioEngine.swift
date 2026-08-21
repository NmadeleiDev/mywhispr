import FluidAudio
import Foundation

actor FluidAudioEngine: TranscriptionEngine {
    private var parakeet: AsrManager?
    private var senseVoice: SenseVoiceManager?
    private var loadedModelID: String?

    func prepare(modelID: String, progress: ProgressReporter?) async throws {
        guard loadedModelID != modelID || (parakeet == nil && senseVoice == nil) else {
            progress?(.running, nil)
            return
        }
        await unload()
        // Decided before the work starts: once the files are on disk the same call
        // does something entirely different, and the owner is owed the difference.
        let fetching = !ModelStorage.isInstalled(modelID: modelID, engine: .fluidAudio)
        let stage: TranscriptionStage = fetching ? .downloadingModel : .loadingModel
        progress?(stage, fetching ? 0 : nil)

        switch modelID {
        case "parakeet-tdt-v3":
            let models = try await AsrModels.downloadAndLoad(version: .v3) { value in
                progress?(stage, fetching ? value.fractionCompleted : nil)
            }
            progress?(.loadingModel, nil)
            let manager = AsrManager(config: ASRConfig(melChunkContext: false))
            try await manager.loadModels(models)
            parakeet = manager
        case "sensevoice-small":
            senseVoice = try await SenseVoiceManager.load { value in
                progress?(stage, fetching ? value.fractionCompleted : nil)
            }
        default:
            throw TranscriptionEngineError.unsupportedModel(modelID)
        }
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
        switch profile.modelID {
        case "parakeet-tdt-v3":
            guard let parakeet else { throw TranscriptionEngineError.unsupportedModel(profile.modelID) }
            var decoderState = TdtDecoderState.make(decoderLayers: await parakeet.decoderLayerCount)
            let result = try await parakeet.transcribe(audioURL, decoderState: &decoderState)
            let speaker = channel == .microphone ? "You" : "Speaker 1"
            let words = buildWordTimings(from: result.tokenTimings ?? [])
            let segments = Self.groupWords(words, channel: channel, speaker: speaker)
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscriptionEngineError.noSpeech
            }
            progress?(.running, 1)
            return TranscriptionResult(
                text: result.text,
                detectedLanguage: languageCode(profile.language),
                segments: segments.isEmpty ? [
                    TranscriptSegment(
                        id: UUID(), start: 0, end: result.duration, text: result.text,
                        speaker: speaker, channel: channel
                    )
                ] : segments
            )
        case "sensevoice-small":
            guard let senseVoice else { throw TranscriptionEngineError.unsupportedModel(profile.modelID) }
            let text = try await senseVoice.transcribe(audioURL: audioURL)
            guard !text.isEmpty else { throw TranscriptionEngineError.noSpeech }
            return TranscriptionResult(
                text: text,
                detectedLanguage: nil,
                segments: [TranscriptSegment(
                    id: UUID(), start: 0, end: 0, text: text,
                    speaker: channel == .microphone ? "You" : "Speaker 1", channel: channel
                )]
            )
        default:
            throw TranscriptionEngineError.unsupportedModel(profile.modelID)
        }
    }

    func unload() async {
        if let parakeet { await parakeet.cleanup() }
        parakeet = nil
        senseVoice = nil
        loadedModelID = nil
    }

    private func languageCode(_ selection: LanguageSelection) -> String? {
        if case .fixed(let code) = selection { return code }
        return nil
    }

    private static func groupWords(
        _ words: [WordTiming],
        channel: AudioChannel,
        speaker: String
    ) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        var current: [WordTiming] = []
        for word in words {
            current.append(word)
            let terminates = word.word.last.map { ".!?".contains($0) } ?? false
            if terminates || current.count >= 24 {
                output.append(makeSegment(current, channel: channel, speaker: speaker))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { output.append(makeSegment(current, channel: channel, speaker: speaker)) }
        return output
    }

    private static func makeSegment(
        _ words: [WordTiming],
        channel: AudioChannel,
        speaker: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            start: words.first?.startTime ?? 0,
            end: words.last?.endTime ?? 0,
            text: words.map(\.word).joined(separator: " "),
            speaker: speaker,
            channel: channel
        )
    }
}
