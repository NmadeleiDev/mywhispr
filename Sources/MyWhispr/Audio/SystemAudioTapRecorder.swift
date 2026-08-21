// Core Audio tap lifecycle adapted from OpenWhispr's MIT-licensed
// resources/macos-audio-tap.swift. Copyright (c) 2024 OpenWhispr Team.

import AVFoundation
@preconcurrency import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

/// Everything the IO proc touches, and nothing else.
///
/// The original arrangement had the recorder's own mutable properties — converter,
/// format, file, a `stopping` flag — read and written from both the main thread and
/// the Core Audio IO thread with no synchronisation at all. That is a data race
/// whether or not it happens to work, and it is the kind that surfaces as a corrupt
/// recording of a meeting that cannot be repeated.
///
/// Bundling the realtime state into one immutable context, captured by the IO block
/// at creation and never mutated afterwards, removes the sharing rather than
/// guarding it. The only cross-thread mutation left is a single atomic stop flag.
private final class TapContext: @unchecked Sendable {
    let sourceFormat: AVAudioFormat
    let targetFormat: AVAudioFormat
    let converter: AVAudioConverter
    let writer: AudioFileWriter

    private let stopFlag = ManagedAtomicFlag()

    init(
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter,
        writer: AudioFileWriter
    ) {
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.converter = converter
        self.writer = writer
    }

    func stop() { stopFlag.set() }

    /// Called on the Core Audio IO thread.
    func process(_ inputData: UnsafePointer<AudioBufferList>) {
        guard !stopFlag.isSet else { return }

        let mutableInput = UnsafeMutablePointer(mutating: inputData)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            bufferListNoCopy: mutableInput,
            deallocator: nil
        ) else { return }

        let capacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * targetFormat.sampleRate / max(1, sourceFormat.sampleRate))
        ) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(32, capacity)
        ) else { return }

        let provided = OneShotLatch()
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outputStatus in
            guard provided.take() else {
                outputStatus.pointee = .noDataNow
                return nil
            }
            outputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard error == nil, status == .haveData || status == .inputRanDry else { return }
        guard outputBuffer.frameLength > 0 else { return }
        // Hands off rather than writing: see `AudioFileWriter`.
        writer.write(outputBuffer)
    }
}

/// A flag that may be set from one thread and read from a realtime thread.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private var storage: Int32 = 0

    var isSet: Bool {
        OSAtomicAdd32(0, &storage) != 0
    }

    func set() {
        OSAtomicCompareAndSwap32(0, 1, &storage)
    }
}

/// Records this Mac's audio output using a Core Audio process tap.
///
/// The tap is private and non-muting, so the owner keeps hearing the meeting
/// normally and the selected output device is never changed.
final class SystemAudioTapRecorder: @unchecked Sendable {
    private let ioQueue = DispatchQueue(label: "app.mywhispr.system-audio", qos: .userInitiated)

    // Lifecycle state. Only ever touched by start/stop, never by the IO thread.
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var context: TapContext?
    private var writer: AudioFileWriter?
    private var startedAt: Date?
    private(set) var outputURL: URL?

    /// 16 kHz mono float — what every speech model here wants, so the conversion
    /// happens once during capture rather than again per transcription.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func start(outputURL: URL) throws {
        guard tapID == 0 else { throw AudioCaptureError.alreadyRecording }
        self.outputURL = outputURL

        let description = CATapDescription()
        description.name = "MyWhispr System Audio"
        description.uuid = UUID()
        description.processes = []
        description.isMono = true
        description.isExclusive = true
        description.isMixdown = true
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var createdTap = AudioObjectID()
        let status = AudioHardwareCreateProcessTap(description, &createdTap)
        guard status == noErr else {
            cleanup()
            throw AudioCaptureError.systemAudioUnavailable(status)
        }
        tapID = createdTap

        do {
            let uid = try tapUID()
            try createAggregateDevice(tapUID: uid)
            try waitUntilAggregateDeviceReady()

            let sourceFormat = try resolveTapFormat()
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw AudioCaptureError.systemAudioUnavailable(kAudioHardwareUnsupportedOperationError)
            }
            let fileWriter = try AudioFileWriter(
                url: outputURL,
                settings: targetFormat.settings,
                label: "app.mywhispr.system-audio.writer"
            )
            writer = fileWriter
            let tapContext = TapContext(
                sourceFormat: sourceFormat,
                targetFormat: targetFormat,
                converter: converter,
                writer: fileWriter
            )
            context = tapContext
            try registerIOProc(context: tapContext)

            let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
            guard startStatus == noErr else {
                throw AudioCaptureError.systemAudioUnavailable(startStatus)
            }
            startedAt = Date()
        } catch {
            cleanup()
            throw error
        }
    }

    func stop() -> CapturedAudio? {
        guard tapID != 0, let outputURL else { return nil }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        cleanup()
        return CapturedAudio(url: outputURL, duration: duration)
    }

    /// Tears down in the order that guarantees no in-flight IO callback can still be
    /// running when the writer is closed: signal, stop the device, destroy the proc,
    /// and only then flush.
    private func cleanup() {
        context?.stop()
        if aggregateDeviceID != 0, ioProcID != nil {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
        }
        if let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        writer?.finish()
        writer = nil
        context = nil
        startedAt = nil
    }

    private func tapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedUID) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let unmanagedUID else {
            throw AudioCaptureError.systemAudioUnavailable(status)
        }
        return unmanagedUID.takeRetainedValue() as String
    }

    private func createAggregateDevice(tapUID: String) throws {
        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MyWhispr System Audio",
            kAudioAggregateDeviceUIDKey: "app.mywhispr.audio-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        var deviceID = AudioObjectID()
        let status = AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &deviceID)
        guard status == noErr else { throw AudioCaptureError.systemAudioUnavailable(status) }
        aggregateDeviceID = deviceID
    }

    private func waitUntilAggregateDeviceReady() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for _ in 0..<20 {
            var isAlive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(aggregateDeviceID, &address, 0, nil, &size, &isAlive)
            if status == noErr, isAlive != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw AudioCaptureError.systemAudioUnavailable(kAudioHardwareNotRunningError)
    }

    private func resolveTapFormat() throws -> AVAudioFormat {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &description) else {
            throw AudioCaptureError.systemAudioUnavailable(status)
        }
        return format
    }

    private func registerIOProc(context: TapContext) throws {
        var procID: AudioDeviceIOProcID?
        // The context is captured once here and never mutated, so the IO thread
        // shares no writable state with the rest of the app.
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            ioQueue
        ) { _, inputData, _, _, _ in
            context.process(inputData)
        }
        guard status == noErr, let procID else {
            throw AudioCaptureError.systemAudioUnavailable(status)
        }
        ioProcID = procID
    }
}

/// Single-use flag: the first `take()` returns true, every later call false.
///
/// Used to feed an `AVAudioConverter` exactly one input buffer per conversion.
/// `AVAudioConverter` types its input block `@Sendable` even though it invokes it
/// synchronously on the calling thread, so the latch is locked rather than assumed
/// single-threaded.
private final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}
