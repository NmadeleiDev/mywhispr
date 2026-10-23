import AppKit
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
///
/// Drawn as a template image. MenuBarExtra rasterises a SwiftUI shape painted with
/// a fixed colour — including the recording amber — as white, and a white glyph
/// disappears on a light menu bar. Template artwork keeps only the alpha, so macOS
/// tints the bars to contrast with whatever is behind the bar.
struct MenuBarMeter: View {
    var samples: [Float]
    var isActive: Bool

    var body: some View {
        Image(nsImage: Self.templateImage(samples: samples, isActive: isActive))
            .renderingMode(.template)
            .accessibilityLabel(isActive ? "Recording" : "Level meter")
    }

    static func templateImage(samples: [Float], isActive: Bool) -> NSImage {
        let canvas = NSSize(width: 15, height: 15)
        let levels = buckets(from: samples)
        let image = NSImage(size: canvas, flipped: false) { rect in
            let barWidth: CGFloat = 2
            let spacing: CGFloat = 1.5
            let count = CGFloat(levels.count)
            let contentWidth = count * barWidth + max(0, count - 1) * spacing
            var x = (rect.width - contentWidth) / 2
            for value in levels {
                let height = barHeight(value, isActive: isActive)
                let y = (rect.height - height) / 2
                let bar = NSBezierPath(
                    roundedRect: NSRect(x: x, y: y, width: barWidth, height: height),
                    xRadius: barWidth / 2,
                    yRadius: barWidth / 2
                )
                NSColor.black.setFill()
                bar.fill()
                x += barWidth + spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func buckets(from samples: [Float]) -> [Float] {
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

    private static func barHeight(_ value: Float, isActive: Bool) -> CGFloat {
        guard isActive else { return 3 }
        let shaped = pow(Double(min(max(value, 0), 1)), 0.6)
        return 3 + 10 * shaped
    }
}
