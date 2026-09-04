import AVFoundation
import Foundation

enum CLIOutputFormat: String, Equatable, Sendable {
    case text
    case json
}

struct TranscribeCommand: Equatable, Sendable {
    var audioURL: URL
    var profile: TranscriptionProfile
    var outputFormat: CLIOutputFormat
}

enum ParsedCommand: Equatable, Sendable {
    case help
    case version
    case transcribe(TranscribeCommand)
}

enum CommandLineError: LocalizedError, Equatable {
    case missingAudioFile
    case tooManyAudioFiles
    case missingValue(String)
    case unknownOption(String)
    case unknownEngine(String)
    case unknownModel(String)
    case modelEngineMismatch(model: String, engine: String)
    case unknownOutputFormat(String)
    case emptyLanguage
    case fileDoesNotExist(String)
    case notAFile(String)
    case unreadableAudio(String)
    case emptyAudio(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioFile:
            "No audio file was provided."
        case .tooManyAudioFiles:
            "Only one audio file can be transcribed at a time."
        case .missingValue(let option):
            "Missing value for \(option)."
        case .unknownOption(let option):
            "Unknown option: \(option)."
        case .unknownEngine(let engine):
            "Unknown engine '\(engine)'. Use 'fluid-audio' or 'whisper-kit'."
        case .unknownModel(let model):
            "Unknown model '\(model)'. Run with --help to see the supported models."
        case .modelEngineMismatch(let model, let engine):
            "Model '\(model)' does not belong to the \(engine) engine."
        case .unknownOutputFormat(let format):
            "Unknown output format '\(format)'. Use 'text' or 'json'."
        case .emptyLanguage:
            "The language must be 'auto' or a language code such as 'en'."
        case .fileDoesNotExist(let path):
            "Audio file does not exist: \(path)"
        case .notAFile(let path):
            "Audio input is not a regular file: \(path)"
        case .unreadableAudio(let path):
            "The file is not a supported or readable audio file: \(path)"
        case .emptyAudio(let path):
            "The audio file contains no audio frames: \(path)"
        }
    }
}

enum CommandLineParser {
    static func parse(
        _ processArguments: [String],
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> ParsedCommand {
        var arguments = Array(processArguments.dropFirst())
        arguments.removeAll { $0.hasPrefix("-psn_") }

        if arguments.first == "transcribe" {
            arguments.removeFirst()
        }
        if arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
            return .help
        }
        if arguments == ["--version"] || arguments == ["version"] {
            return .version
        }

        var path: String?
        var engine: EngineIdentifier?
        var modelID: String?
        var language = LanguageSelection.automatic
        var outputFormat = CLIOutputFormat.text
        var optionsEnded = false
        var index = 0

        func value(after option: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else { throw CommandLineError.missingValue(option) }
            index = valueIndex
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if !optionsEnded && argument == "--" {
                optionsEnded = true
            } else if !optionsEnded && (argument == "--help" || argument == "-h") {
                return .help
            } else if !optionsEnded && argument == "--engine" {
                let raw = try value(after: argument)
                engine = try parseEngine(raw)
            } else if !optionsEnded && argument == "--model" {
                modelID = try value(after: argument)
            } else if !optionsEnded && argument == "--language" {
                let raw = try value(after: argument).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { throw CommandLineError.emptyLanguage }
                language = raw.lowercased() == "auto" ? .automatic : .fixed(raw)
            } else if !optionsEnded && argument == "--format" {
                let raw = try value(after: argument)
                guard let parsed = CLIOutputFormat(rawValue: raw.lowercased()) else {
                    throw CommandLineError.unknownOutputFormat(raw)
                }
                outputFormat = parsed
            } else if !optionsEnded && argument.hasPrefix("-") {
                throw CommandLineError.unknownOption(argument)
            } else if path == nil {
                path = argument
            } else {
                throw CommandLineError.tooManyAudioFiles
            }
            index += 1
        }

        guard let path else { throw CommandLineError.missingAudioFile }
        let resolvedURL = resolve(path: path, relativeTo: currentDirectory)
        let descriptor = try resolveModel(modelID: modelID, engine: engine)
        return .transcribe(TranscribeCommand(
            audioURL: resolvedURL,
            profile: TranscriptionProfile(
                engine: descriptor.engine,
                modelID: descriptor.id,
                language: language
            ),
            outputFormat: outputFormat
        ))
    }

    private static func parseEngine(_ raw: String) throws -> EngineIdentifier {
        switch raw.lowercased() {
        case "fluid", "fluid-audio", "fluidaudio": .fluidAudio
        case "whisper", "whisper-kit", "whisperkit": .whisperKit
        default: throw CommandLineError.unknownEngine(raw)
        }
    }

    private static func resolveModel(
        modelID: String?,
        engine: EngineIdentifier?
    ) throws -> ModelDescriptor {
        if let modelID {
            guard let descriptor = ModelDescriptor.curated.first(where: { $0.id == modelID }) else {
                throw CommandLineError.unknownModel(modelID)
            }
            if let engine, descriptor.engine != engine {
                throw CommandLineError.modelEngineMismatch(
                    model: modelID,
                    engine: engine == .fluidAudio ? "FluidAudio" : "WhisperKit"
                )
            }
            return descriptor
        }

        let profile = switch engine ?? .fluidAudio {
        case .fluidAudio: TranscriptionProfile.dictationDefault
        case .whisperKit: TranscriptionProfile.meetingDefault
        }
        // Both defaults are guarded by ModelCatalogTests; this is an invariant, not
        // user input, so a force unwrap would merely obscure a broken build.
        guard let descriptor = ModelDescriptor.curated.first(where: {
            $0.id == profile.modelID && $0.engine == profile.engine
        }) else {
            preconditionFailure("The default transcription model is missing from the curated catalog")
        }
        return descriptor
    }

    private static func resolve(path: String, relativeTo directory: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if NSString(string: expanded).isAbsolutePath {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return directory.appending(path: expanded).standardizedFileURL
    }
}

/// Validates through the same AVFoundation decoder used by both transcription
/// engines. macOS 26 decodes Ogg Vorbis, Opus, and FLAC in Ogg containers here, so
/// `.ogg`, `.oga`, and `.opus` need no lossy conversion or external executable.
enum TranscriptionAudioInput {
    static func validate(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CommandLineError.fileDoesNotExist(url.path)
        }
        guard !isDirectory.boolValue else { throw CommandLineError.notAFile(url.path) }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw CommandLineError.unreadableAudio(url.path)
        }
        guard file.fileFormat.channelCount > 0, file.fileFormat.sampleRate > 0, file.length > 0 else {
            throw CommandLineError.emptyAudio(url.path)
        }
    }
}

enum CommandLineInterface {
    static let version = "0.3.0"

    static let usage = """
    Usage:
      MyWhispr transcribe <audio-file> [options]
      MyWhispr <audio-file> [options]

    Transcribes one local audio file entirely on this Mac. Ogg Vorbis, Ogg Opus,
    and Ogg FLAC files are accepted through .ogg, .oga, and .opus inputs.

    Options:
      --engine <name>      fluid-audio (default) or whisper-kit
      --model <id>         Model to use; selecting one also selects its engine
      --language <code>    auto (default) or a language code such as en or de
      --format <format>    text (default) or json
      -h, --help           Show this help
      --version            Show the version

    FluidAudio models:
      parakeet-tdt-v3 (default), sensevoice-small

    WhisperKit models:
      tiny, base, small, large-v3-v20240930_turbo,
      large-v3-v20240930_626MB (default for --engine whisper-kit)

    The selected model is downloaded on first use. The transcript is written to
    stdout; progress and errors are written to stderr.
    """

    static func isInvocation(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { !$0.hasPrefix("-psn_") }
    }

    static func run(arguments: [String]) async -> Int32 {
        do {
            switch try CommandLineParser.parse(arguments) {
            case .help:
                write(usage + "\n", to: .standardOutput)
            case .version:
                write("MyWhispr \(version)\n", to: .standardOutput)
            case .transcribe(let command):
                try TranscriptionAudioInput.validate(command.audioURL)
                let result = try await TranscriptionService().transcribe(
                    audioURL: command.audioURL,
                    profile: command.profile,
                    channel: .microphone,
                    progress: nil
                )
                switch command.outputFormat {
                case .text:
                    write(result.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", to: .standardOutput)
                case .json:
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let data = try encoder.encode(result)
                    FileHandle.standardOutput.write(data)
                    write("\n", to: .standardOutput)
                }
            }
            return 0
        } catch let error as CommandLineError {
            write("error: \(error.localizedDescription)\n\n\(usage)\n", to: .standardError)
            return 2
        } catch {
            write("error: Transcription failed: \(error.localizedDescription)\n", to: .standardError)
            return 1
        }
    }

    fileprivate static func write(_ string: String, to handle: FileHandle) {
        handle.write(Data(string.utf8))
    }
}
