import SwiftUI

/// The app uses a near-monochrome surface with exactly one saturated accent.
///
/// The accent is reserved for two things and nothing else: live capture, and the
/// single primary action on a surface. Because it is the only colour on screen,
/// "MyWhispr is listening right now" never needs a text label to be unmistakable.
enum Palette {
    /// Warm amber. Live recording, and at most one primary action per surface.
    static let accent = Color(.sRGB, red: 0.98, green: 0.60, blue: 0.13, opacity: 1)

    /// A lighter amber used only for the trailing edge of the live waveform.
    static let accentSoft = Color(.sRGB, red: 1.00, green: 0.76, blue: 0.42, opacity: 1)

    /// Failure states. Never used decoratively.
    static let danger = Color(.sRGB, red: 0.91, green: 0.32, blue: 0.28, opacity: 1)

    /// Confirmation. Deliberately desaturated so success reads as calm, not loud.
    static let affirm = Color(.sRGB, red: 0.36, green: 0.72, blue: 0.50, opacity: 1)

    /// Speaker chips in a meeting transcript. Assigned by index, wrapping.
    ///
    /// These are hues, not accents: they are pushed to low chroma so a transcript
    /// with six speakers still reads as one calm document, and so the amber
    /// recording accent is never mistaken for a speaker colour.
    static let speakers: [Color] = [
        Color(.sRGB, red: 0.45, green: 0.62, blue: 0.85, opacity: 1),
        Color(.sRGB, red: 0.72, green: 0.55, blue: 0.82, opacity: 1),
        Color(.sRGB, red: 0.40, green: 0.72, blue: 0.68, opacity: 1),
        Color(.sRGB, red: 0.85, green: 0.58, blue: 0.60, opacity: 1),
        Color(.sRGB, red: 0.62, green: 0.70, blue: 0.44, opacity: 1),
        Color(.sRGB, red: 0.55, green: 0.60, blue: 0.78, opacity: 1),
    ]

    /// `You` always renders in the accent-adjacent warm tone so the owner's own
    /// speech is findable at a glance without reading names.
    static let selfSpeaker = Color(.sRGB, red: 0.85, green: 0.64, blue: 0.36, opacity: 1)

    static func speaker(_ name: String) -> Color {
        guard name != "You" else { return selfSpeaker }
        // Deterministic FNV-1a, not `Hasher`: `Hasher` is seeded per process, so it
        // would repaint every speaker on each relaunch. A speaker keeps its hue for
        // the life of the transcript; renaming re-colours it, which reads as
        // confirmation that the rename landed.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return speakers[Int(hash % UInt64(speakers.count))]
    }
}

enum Metrics {
    /// Corner radius of the recording HUD capsule and menu-bar panel.
    static let capsule: CGFloat = 26
    /// Corner radius of cards and list rows.
    static let card: CGFloat = 12
    /// Gap the HUD keeps above the Dock / screen bottom.
    static let hudBottomInset: CGFloat = 18
    /// The HUD panel is a fixed, generously sized transparent canvas so the pill
    /// can grow and shrink entirely in SwiftUI without ever moving its window.
    static let hudPanelSize = CGSize(width: 620, height: 190)
    static let quickPastePanelSize = CGSize(width: 560, height: 420)
}

extension Animation {
    /// The single motion curve used for every glass morph in the app.
    static let glassMorph = Animation.smooth(duration: 0.36, extraBounce: 0.12)
    /// Faster curve for level-driven motion that must not feel laggy.
    static let levelFollow = Animation.smooth(duration: 0.09)
}

extension Text {
    /// Elapsed timers and percentages must not reflow as digits change.
    func tabularTime() -> some View {
        self.monospacedDigit().contentTransition(.numericText())
    }
}

enum Clock {
    /// `0:07` for short takes, `1:04:22` once a meeting passes an hour.
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// `4.2s`, `1m 12s`, `1h 04m` — for durations shown in list rows, where a
    /// running clock would imply the item is still live.
    static func compact(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let total = Int(seconds.rounded())
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }
}
