import SwiftUI

/// The live waveform inside the recording HUD.
///
/// Bars are symmetric around the vertical centre and fade toward the leading edge,
/// so the shape reads as "sound moving toward now" without any label saying so.
struct WaveformView: View {
    var samples: [Float]
    var tint: Color = Palette.accent
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var minHeight: CGFloat = 3
    var maxHeight: CGFloat = 26

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, value in
                let position = samples.isEmpty ? 1 : Double(index) / Double(max(1, samples.count - 1))
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.28 + 0.72 * position))
                    .frame(width: barWidth, height: height(for: value))
            }
        }
        .frame(height: maxHeight)
        .animation(.levelFollow, value: samples)
        .accessibilityHidden(true)
    }

    private func height(for value: Float) -> CGFloat {
        // Perceptual curve: raw RMS spends most of its range near zero, which would
        // make normal speech look like a flat line. The exponent lifts quiet speech
        // into visible territory while leaving headroom for shouting.
        let shaped = pow(Double(min(max(value, 0), 1)), 0.62)
        return minHeight + (maxHeight - minHeight) * shaped
    }
}

/// A four-bar meter small enough to live in the menu bar and still read as motion.
struct MenuBarMeter: View {
    var samples: [Float]
    var isActive: Bool

    private var buckets: [Float] {
        guard !samples.isEmpty else { return Array(repeating: 0, count: 4) }
        // Average the newest 16 samples into 4 buckets so the tiny meter shows a
        // trend rather than jittering on single frames.
        let tail = samples.suffix(16)
        let size = max(1, tail.count / 4)
        return stride(from: 0, to: 4, by: 1).map { index in
            let slice = Array(tail).dropFirst(index * size).prefix(size)
            guard !slice.isEmpty else { return 0 }
            return slice.reduce(0, +) / Float(slice.count)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, value in
                Capsule(style: .continuous)
                    .frame(width: 2, height: barHeight(value))
            }
        }
        .frame(width: 15, height: 15)
        .animation(.levelFollow, value: buckets)
    }

    private func barHeight(_ value: Float) -> CGFloat {
        guard isActive else { return 3 }
        let shaped = pow(Double(min(max(value, 0), 1)), 0.6)
        return 3 + 10 * shaped
    }
}
