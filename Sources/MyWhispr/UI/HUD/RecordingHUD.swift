import SwiftUI

/// What the pill is currently saying. Derived from ``RecordingPhase`` plus the
/// short-lived outcome flash that follows a completed dictation.
enum HUDState: Equatable {
    case hidden
    case armed                              // key is down, capture is spinning up
    case listening(startedAt: Date)         // dictation, live
    case meeting(startedAt: Date, collapsed: Bool)
    case working(WorkStage, progress: Double?)
    case inserted(words: Int)
    case copied(reason: CopyReason)
    case failed(String)

    enum WorkStage: Equatable {
        /// First use of a model. Named separately because it can run for minutes on
        /// a several-hundred-megabyte download, and calling that "Transcribing"
        /// makes the app look stuck at 0%.
        case downloadingModel
        case loadingModel
        case transcribing
        case rewriting
        case inserting

        var label: String {
            switch self {
            case .downloadingModel: "Downloading the model"
            case .loadingModel: "Loading the model"
            case .transcribing: "Transcribing"
            case .rewriting: "Rewriting"
            case .inserting: "Inserting"
            }
        }
    }

    enum CopyReason: Equatable {
        case targetChanged
        case unsupported

        var label: String {
            switch self {
            case .targetChanged: "Focus moved · copied"
            case .unsupported: "Copied"
            }
        }
    }

    var isVisible: Bool { self != .hidden }
}

/// The bottom-centre Liquid Glass pill.
///
/// One capsule for the whole lifecycle: it grows out of nothing when capture
/// starts, morphs in place through transcription, and shrinks away after
/// confirming. `glassEffectID` inside a `GlassEffectContainer` is what makes the
/// glass itself flow between the states instead of cross-fading two pills.
struct RecordingHUD: View {
    var state: HUDState
    var meter: AudioLevelMeter
    var onCancel: () -> Void
    var onStopMeeting: () -> Void
    var onCancelProcessing: () -> Void

    @Namespace private var glass
    @State private var now = Date()

    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 18) {
                pill
                    .glassEffectID("hud", in: glass)
                    .glassEffectTransition(.matchedGeometry)
            }
            .padding(.bottom, Metrics.hudBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(tick) { now = $0 }
        .animation(.glassMorph, value: state)
    }

    @ViewBuilder
    private var pill: some View {
        switch state {
        case .hidden:
            EmptyView()

        case .armed:
            content(tint: Palette.accent) {
                RecordDot(level: 0, isLive: true)
                Text("Listening")
                    .foregroundStyle(.secondary)
            }

        case .listening(let startedAt):
            let elapsed = now.timeIntervalSince(startedAt)
            content(tint: Palette.accent) {
                RecordDot(level: meter.level, isLive: true)
                if meter.looksSilent(after: elapsed) {
                    // Silence is only worth mentioning once it is informative. A muted
                    // input or the wrong device announces itself here instead of
                    // surfacing later as an empty transcription.
                    Label("No sound from the microphone", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.danger)
                        .transition(.opacity)
                } else {
                    WaveformView(samples: meter.samples)
                }
                Text(Clock.string(elapsed))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tabularTime()
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .onTapGesture(perform: onCancel)
            .help("Click to cancel")

        case .meeting(let startedAt, let collapsed):
            let elapsed = now.timeIntervalSince(startedAt)
            content(tint: Palette.accent) {
                RecordDot(level: meter.level, isLive: true)
                if !collapsed {
                    WaveformView(samples: meter.samples)
                }
                Text(Clock.string(elapsed))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tabularTime()
                    .frame(minWidth: collapsed ? 44 : 52, alignment: .trailing)
                if !collapsed {
                    Button(action: onStopMeeting) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                    .help("Stop the meeting")
                }
            }

        case .working(let stage, let progress):
            content(tint: nil) {
                WorkIndicator(progress: progress)
                Text(stage.label)
                    .foregroundStyle(.secondary)
                if let progress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .tabularTime()
                        .frame(minWidth: 36, alignment: .trailing)
                }
                // Waiting is the one part of dictation the owner cannot shorten, so
                // there is always a way out of it. Kept quiet — it is an escape
                // hatch, not the expected next step.
                Button(action: onCancelProcessing) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Stop")
            }

        case .inserted(let words):
            content(tint: nil) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.affirm)
                Text(words == 1 ? "1 word" : "\(words) words")
                    .foregroundStyle(.secondary)
            }

        case .copied(let reason):
            content(tint: nil) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(reason.label)
                    .foregroundStyle(.secondary)
                Text("⌘V")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

        case .failed(let message):
            content(tint: Palette.danger) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
    }

    /// Every state shares one capsule geometry so the glass morphs rather than
    /// swapping. `tint` is nil for everything except live capture and failure —
    /// the accent stays scarce enough to mean something.
    private func content<Body: View>(
        tint: Color?,
        @ViewBuilder _ body: () -> Body
    ) -> some View {
        HStack(spacing: 10) {
            body()
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .glassEffect(
            tint.map { Glass.regular.tint($0.opacity(0.16)) } ?? .regular,
            in: .capsule
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .contentShape(.capsule)
    }
}

/// The record indicator: a solid dot with a ring that breathes on the voice level.
private struct RecordDot: View {
    var level: Float
    var isLive: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.accent.opacity(0.35), lineWidth: 2)
                .frame(width: 18, height: 18)
                .scaleEffect(1 + CGFloat(min(max(level, 0), 1)) * 0.45)
                .opacity(isLive ? 1 : 0)
            Circle()
                .fill(Palette.accent)
                .frame(width: 9, height: 9)
        }
        .frame(width: 26, height: 26)
        .animation(.levelFollow, value: level)
    }
}

/// Determinate ring when the engine reports progress, indeterminate sweep when it
/// does not. Both occupy the same footprint so the pill does not resize mid-work.
private struct WorkIndicator: View {
    var progress: Double?
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2.5)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.3), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            }
        }
        .frame(width: 17, height: 17)
        .frame(width: 26, height: 26)
    }
}
