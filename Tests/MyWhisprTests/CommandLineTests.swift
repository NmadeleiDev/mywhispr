import AVFoundation
import Foundation
import Testing
@testable import MyWhispr

@Suite("Command-line transcription")
struct CommandLineTests {
    private let cwd = URL(fileURLWithPath: "/tmp/mywhispr-cli-tests", isDirectory: true)

    @Test("An audio path alone uses the fast default model")
    func parsesMinimalInvocation() throws {
        let parsed = try CommandLineParser.parse(["MyWhispr", "voice.ogg"], currentDirectory: cwd)
        let command = try #require(transcribeCommand(from: parsed))
        #expect(command.audioURL.path == "/tmp/mywhispr-cli-tests/voice.ogg")
        #expect(command.profile.engine == .fluidAudio)
        #expect(command.profile.modelID == "parakeet-tdt-v3")
        #expect(command.profile.language == .automatic)
        #expect(command.outputFormat == .text)
    }

    @Test("The explicit subcommand and output options are parsed")
    func parsesOptions() throws {
        let parsed = try CommandLineParser.parse([
            "MyWhispr", "transcribe", "meeting.ogg", "--model", "small",
            "--language", "de", "--format", "json",
        ], currentDirectory: cwd)
        let command = try #require(transcribeCommand(from: parsed))
        #expect(command.profile.engine == .whisperKit)
        #expect(command.profile.modelID == "small")
        #expect(command.profile.language == .fixed("de"))
        #expect(command.outputFormat == .json)
    }

    @Test("Engine and model cannot contradict one another")
    func rejectsMismatchedModel() {
        #expect(throws: CommandLineError.modelEngineMismatch(model: "small", engine: "FluidAudio")) {
            try CommandLineParser.parse([
                "MyWhispr", "voice.wav", "--engine", "fluid-audio", "--model", "small",
            ], currentDirectory: cwd)
        }
    }

    @Test("Missing option values and extra paths are rejected")
    func rejectsMalformedInvocation() {
        #expect(throws: CommandLineError.missingValue("--model")) {
            try CommandLineParser.parse(["MyWhispr", "voice.wav", "--model"], currentDirectory: cwd)
        }
        #expect(throws: CommandLineError.tooManyAudioFiles) {
            try CommandLineParser.parse(["MyWhispr", "one.wav", "two.wav"], currentDirectory: cwd)
        }
    }

    @Test("An Ogg Opus file is decoded through the production input boundary")
    func acceptsOggOpus() throws {
        let directory = URL.temporaryDirectory.appending(path: "MyWhisprCLI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "voice.ogg")

        // A 100 ms, 16 kHz mono Opus tone in a genuine Ogg container. Keeping the
        // tiny fixture inline makes the test independent of ffmpeg or another
        // encoder being installed on the machine that runs the suite.
        let fixture = """
        T2dnUwACAAAAAAAAAABpHN0nAAAAANd2X2sBE09wdXNIZWFkAQE4AYA+AAAAAABPZ2dTAAAAAAAAAAAAAGkc3ScBAAAAidDRxgE8
        T3B1c1RhZ3MMAAAATGF2ZjYzLjEuMTAxAQAAABwAAABlbmNvZGVyPUxhdmM2My4xLjEwMSBsaWJvcHVzT2dnUwAE+BMAAAAAAABp
        HN0nAgAAALGCnaQGPyooKCofSIIBXWx+QOYAAAvT2GC2VwZdhzkY5YbZU/0FvoMoouJDWYnDz13zNO6OahMpzumTuDYBiy7bjgcD
        2vrHM5JgSKH3l6yYhQNcJgoWgB9X2IQpET7Sf7hv+bBeC+xWFLvgRtFvjzRC+G0CSJsrH3Wc/Es6RaW6VLAIcWQJ9+gFsfXVObiy
        tGUzfaSfbdtDCuEBkEibBjKwkqBM1j1j7hqDb0i9H3Q0p4BuuH1FOrNEMGNrI4+5pEnWKVpImrLfdZz8SQ7YN9JzfCJ+FdIq+rra
        3cAym117iXFbRum7l9WN5FPxpWBIBdM19hTEhvPIERcHC3mhYoG4yTKD2mN6BlOArrLw
        """
        let data = try #require(Data(base64Encoded: fixture, options: .ignoreUnknownCharacters))
        try data.write(to: url)

        try TranscriptionAudioInput.validate(url)
        let decoded = try AVAudioFile(forReading: url)
        #expect(decoded.length > 0)
        #expect(decoded.fileFormat.channelCount == 1)
    }

    private func transcribeCommand(from parsed: ParsedCommand) -> TranscribeCommand? {
        guard case .transcribe(let command) = parsed else { return nil }
        return command
    }
}
