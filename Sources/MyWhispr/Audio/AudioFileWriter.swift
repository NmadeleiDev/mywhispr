import AVFoundation
import Foundation

/// Writes audio buffers to disk off whatever thread produced them.
///
/// Core Audio IO procs and `AVAudioEngine` taps run on realtime threads with hard
/// deadlines measured in milliseconds. Writing a file there — which is what the
/// straightforward implementation does — can block on the filesystem and cause
/// dropouts, and the dropouts are not confined to this app: an IO proc that
/// overruns its deadline glitches whatever else is playing, which during a meeting
/// means the call the owner is recording.
///
/// So the realtime side only hands a buffer over, and the writing happens here.
final class AudioFileWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let file: AVAudioFile
    private var isClosed = false
    private var failure: (any Error)?

    init(url: URL, settings: [String: Any], label: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        file = try AVAudioFile(forWriting: url, settings: settings)
        queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Hands a buffer over for writing. Safe to call from a realtime thread.
    ///
    /// `sending` states the contract exactly: ownership transfers to the writer and
    /// the producer must not touch the buffer again. The compiler enforces that at
    /// every call site, which is a real guarantee rather than the comment-and-hope
    /// that suppressing the Sendable warning would have been.
    /// Queues a buffer the caller already owns exclusively.
    ///
    /// `sending` states and enforces that contract: ownership transfers here, and
    /// the caller may not touch the buffer again.
    func write(_ buffer: sending AVAudioPCMBuffer) {
        enqueue(UncheckedSendableBox(buffer))
    }

    /// Copies a realtime tap's buffer, then queues the copy.
    ///
    /// A tap's buffer is only valid for the duration of its callback — it is reused
    /// immediately afterwards — so it cannot simply be handed over. Copying here
    /// rather than at the call site keeps the ownership argument in one place: the
    /// copy is created, boxed, and queued without ever being visible to anything
    /// else, which is what makes the transfer safe.
    func writeCopy(of buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.makeIndependentCopy() else { return }
        enqueue(UncheckedSendableBox(copy))
    }

    private func enqueue(_ payload: UncheckedSendableBox<AVAudioPCMBuffer>) {
        queue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return }
            do {
                try file.write(from: payload.value)
            } catch {
                failure = failure ?? error
                isClosed = true
            }
        }
    }

    /// Flushes everything already handed over, then refuses further writes.
    ///
    /// Synchronous by design: the caller is about to hand this file to a
    /// transcription engine, so every buffer must be on disk before it returns.
    func finish() {
        queue.sync {
            lock.lock()
            isClosed = true
            lock.unlock()
        }
    }

    func takeError() -> (any Error)? {
        lock.lock()
        defer { failure = nil; lock.unlock() }
        return failure
    }
}
