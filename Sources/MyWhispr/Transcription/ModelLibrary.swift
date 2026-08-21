import AppKit
import Foundation
import Observation
import OSLog

/// The shared set of downloaded speech models.
///
/// Downloads are delegated to the engines themselves — they own the repository
/// layout and resumption — so this type's job is the part the engines do not do:
/// telling the owner what is on disk, how much space it costs, what is currently
/// downloading, and refusing to delete a model a workflow still depends on.
@MainActor
@Observable
final class ModelLibrary {
    enum State: Equatable {
        case absent
        case downloading(Double)
        case installed(Int64)
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    /// Every byte under both engines' model roots, including the speaker-separation
    /// models that arrive with the first meeting rather than being chosen.
    private(set) var totalBytes: Int64 = 0

    @ObservationIgnored private let transcription: TranscriptionService
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "app.mywhispr.mac", category: "models")

    init(transcription: TranscriptionService) {
        self.transcription = transcription
        refresh()
    }

    func state(of id: String) -> State {
        states[id] ?? .absent
    }

    var isDownloadingAnything: Bool {
        states.values.contains { if case .downloading = $0 { true } else { false } }
    }

    /// Rescans disk. Sizing walks two directory trees, so it runs off the main
    /// actor and publishes the result back.
    func refresh() {
        let descriptors = ModelDescriptor.curated
        let inFlight = Set(downloads.keys)
        Task.detached(priority: .utility) {
            var found: [String: State] = [:]
            for descriptor in descriptors {
                guard let directory = ModelStorage.directory(for: descriptor) else { continue }
                let size = ModelStorage.size(of: directory)
                // A directory that exists but holds nothing is an interrupted
                // download, not an installed model.
                if size > 0 { found[descriptor.id] = .installed(size) }
            }
            let total = ModelStorage.size(of: ModelStorage.whisperKitBase)
                + ModelStorage.size(of: ModelStorage.fluidAudioRoot)
            await MainActor.run { [found, total] in
                for (id, state) in found where !inFlight.contains(id) {
                    self.states[id] = state
                }
                // Anything previously installed that is now gone becomes absent,
                // so removing files outside the app is reflected here.
                for id in self.states.keys where found[id] == nil && !inFlight.contains(id) {
                    if case .installed = self.states[id] { self.states[id] = .absent }
                }
                self.totalBytes = total
            }
        }
    }

    func download(_ descriptor: ModelDescriptor) {
        guard downloads[descriptor.id] == nil else { return }
        states[descriptor.id] = .downloading(0)
        let profile = TranscriptionProfile(
            engine: descriptor.engine,
            modelID: descriptor.id,
            language: .automatic
        )
        let service = transcription
        downloads[descriptor.id] = Task { [weak self] in
            do {
                try await service.prepare(profile: profile) { stage, fraction in
                    Task { @MainActor in
                        // Ignore late progress from a download the owner cancelled.
                        guard let library = self, library.downloads[descriptor.id] != nil else { return }
                        switch stage {
                        case .downloadingModel:
                            library.states[descriptor.id] = .downloading(min(0.99, fraction ?? 0))
                        case .loadingModel, .running:
                            // Bytes are on disk; what remains is loading, which this
                            // row reports as finished rather than as a stalled bar.
                            library.states[descriptor.id] = .downloading(0.99)
                        }
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.downloads[descriptor.id] = nil
                self.refresh()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.downloads[descriptor.id] = nil
                self.states[descriptor.id] = .failed(error.localizedDescription)
                self.logger.error("Download of \(descriptor.id) failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelDownload(_ id: String) {
        downloads[id]?.cancel()
        downloads[id] = nil
        states[id] = .absent
        refresh()
    }

    /// Deletes a model's files.
    ///
    /// Callers are responsible for having confirmed the model is not assigned to a
    /// workflow — the UI disables the control — but the engine is unloaded first
    /// regardless, so files are never deleted out from under a loaded model.
    func remove(_ descriptor: ModelDescriptor) {
        cancelDownload(descriptor.id)
        Task { [weak self] in
            guard let self else { return }
            await transcription.unload(engine: descriptor.engine)
            if let directory = ModelStorage.directory(for: descriptor) {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    logger.error("Could not remove \(descriptor.id): \(error.localizedDescription)")
                    await MainActor.run { self.states[descriptor.id] = .failed(error.localizedDescription) }
                    return
                }
            }
            await MainActor.run {
                self.states[descriptor.id] = .absent
                self.refresh()
            }
        }
    }

    func revealInFinder() {
        let root = ModelStorage.whisperKitBase.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
}
