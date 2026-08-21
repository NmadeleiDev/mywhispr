import Foundation
import Observation

/// Rolling microphone level history that drives the live waveform.
///
/// This is deliberately a separate observable from ``AppRuntime``. The tap fires
/// roughly 47 times a second; if the level lived on `AppRuntime` every view that
/// reads *anything* from the runtime — the whole main window included — would
/// invalidate at audio-buffer rate. Only the HUD and the menu-bar icon observe
/// this type, so the redraw cost stays where the motion actually is.
@MainActor
@Observable
final class AudioLevelMeter {
    /// Number of bars in the waveform. Newest sample is last.
    static let barCount = 34

    private(set) var samples: [Float] = Array(repeating: 0, count: AudioLevelMeter.barCount)

    /// Smoothed instantaneous level, 0...1. Used for the menu-bar meter and the
    /// breathing ring around the record dot.
    private(set) var level: Float = 0

    /// Peak seen since the last ``reset()``. Drives the "we heard nothing at all"
    /// hint, which is how a muted or wrong input device announces itself without
    /// the owner having to discover it after a failed transcription.
    private(set) var peak: Float = 0

    func push(_ raw: Float) {
        let clamped = min(max(raw, 0), 1)
        // Asymmetric smoothing: rise fast so speech onset is immediate, fall slowly
        // so the waveform reads as a shape rather than a strobe.
        let attack: Float = 0.55
        let release: Float = 0.14
        let coefficient = clamped > level ? attack : release
        level += (clamped - level) * coefficient
        peak = max(peak, clamped)

        samples.removeFirst()
        samples.append(level)
    }

    func reset() {
        samples = Array(repeating: 0, count: Self.barCount)
        level = 0
        peak = 0
    }

    /// True once enough time has passed that silence is informative rather than
    /// just "they have not started talking yet".
    func looksSilent(after elapsed: TimeInterval) -> Bool {
        elapsed > 1.6 && peak < 0.035
    }
}
