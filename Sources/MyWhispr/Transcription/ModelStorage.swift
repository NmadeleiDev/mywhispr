import Foundation

/// Where speech-model files actually live on disk.
///
/// The two engines have different, opinionated defaults, and one of them is a
/// problem: WhisperKit's Hugging Face client writes to `~/Documents/huggingface`
/// unless given a `downloadBase`. Dropping hundreds of megabytes into a folder the
/// owner sees in Finder and iCloud-syncs is not acceptable for files the app should
/// be managing, so MyWhispr redirects it into Application Support alongside
/// everything else it owns.
///
/// FluidAudio already caches to `~/Library/Application Support/FluidAudio/Models`
/// and offers no override, so that path is read rather than chosen.
enum ModelStorage {
    static var applicationSupport: URL {
        // `.applicationSupportDirectory` is guaranteed present for the user domain;
        // falling back to the home directory keeps this non-throwing at call sites
        // that are only ever reporting disk usage.
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }

    /// Base handed to WhisperKit. It appends `models/<repo>` beneath this.
    static var whisperKitBase: URL {
        applicationSupport.appending(path: "MyWhispr/Models/WhisperKit", directoryHint: .isDirectory)
    }

    private static var whisperKitRepositoryRoot: URL {
        whisperKitBase.appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
    }

    /// FluidAudio's fixed cache root for ASR and diarization models.
    static var fluidAudioRoot: URL {
        applicationSupport.appending(path: "FluidAudio/Models", directoryHint: .isDirectory)
    }

    /// Folder names FluidAudio derives from its `Repo` cases by stripping the
    /// `-coreml` suffix from the repository slug.
    private static let fluidAudioFolders: [String: String] = [
        "parakeet-tdt-v3": "parakeet-tdt-0.6b-v3",
        "sensevoice-small": "sensevoice-small",
    ]

    /// The speaker-separation models, downloaded on first meeting rather than
    /// chosen. Counted in disk usage so the number in Settings matches reality.
    static var diarizerDirectory: URL {
        fluidAudioRoot.appending(path: "speaker-diarization", directoryHint: .isDirectory)
    }

    /// Resolves a curated model id to its directory, if that directory exists.
    ///
    /// WhisperKit names its folders after the Hugging Face variant path rather than
    /// the plain model id (`openai_whisper-small` for `small`), so the WhisperKit
    /// side matches by suffix instead of assuming a name.
    static func directory(for descriptor: ModelDescriptor) -> URL? {
        switch descriptor.engine {
        case .fluidAudio:
            guard let folder = fluidAudioFolders[descriptor.id] else { return nil }
            let url = fluidAudioRoot.appending(path: folder, directoryHint: .isDirectory)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil

        case .whisperKit:
            let root = whisperKitRepositoryRoot
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }
            // `small` must not match a folder merely containing that substring, so
            // require the name to end at the id rather than contain it anywhere.
            return entries.first { $0.lastPathComponent.hasSuffix(descriptor.id) }
        }
    }

    /// Whether a model's files are already on disk.
    ///
    /// Lets an engine say "downloading" or "loading" truthfully before it starts,
    /// rather than making the waiting owner guess which one is taking the time.
    static func isInstalled(modelID: String, engine: EngineIdentifier) -> Bool {
        guard let descriptor = ModelDescriptor.curated.first(
            where: { $0.id == modelID && $0.engine == engine }
        ) else { return false }
        guard let directory = directory(for: descriptor) else { return false }
        return size(of: directory) > 0
    }

    /// Recursive size of a directory in bytes. Returns 0 for a missing path.
    static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return 0 }
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey,
            ]), values.isRegularFile == true else { continue }
            // Allocated size, not logical size: it is the number that matches what
            // Finder and the owner's free space actually reflect.
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
