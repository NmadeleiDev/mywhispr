import SwiftUI

/// A grouped block of settings or detail content.
///
/// Grouping is the load-bearing signal here: related controls sit inside one
/// bounded surface, so the relationship is visible without a sentence explaining
/// which setting affects which.
struct Card<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)
            }
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.card, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row that pairs a label with a trailing control, aligned across a whole card.
struct SettingRow<Control: View>: View {
    var label: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
                .labelsHidden()
        }
    }
}

/// What an empty list looks like. One icon, one line, and — when there is a next
/// step — exactly one action.
struct EmptyStateView: View {
    var icon: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
            }
        }
        .padding(28)
        .frame(maxWidth: 300)
    }
}

/// A speaker's name rendered as a colour-coded chip.
///
/// The colour, not the word, is what lets the eye follow one person down a long
/// transcript, which is why renaming re-colours rather than just relabelling.
struct SpeakerChip: View {
    var name: String
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Palette.speaker(name))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Palette.speaker(name).opacity(0.12), in: .capsule)
    }
}

/// Small status dot + label used for permissions and connection state.
struct StatusPill: View {
    enum Tone { case good, bad, unknown, working }

    var tone: Tone
    var label: String

    private var colour: Color {
        switch tone {
        case .good: Palette.affirm
        case .bad: Palette.danger
        case .unknown: .secondary
        case .working: Palette.accent
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch tone {
                case .working:
                    ProgressView().controlSize(.mini)
                case .good:
                    Image(systemName: "checkmark.circle.fill")
                case .bad:
                    Image(systemName: "exclamationmark.circle.fill")
                case .unknown:
                    Image(systemName: "circle.dashed")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(colour)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(tone == .bad ? Palette.danger : .secondary)
        }
    }
}
