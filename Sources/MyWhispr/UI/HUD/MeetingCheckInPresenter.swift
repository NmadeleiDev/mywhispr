import AppKit
import SwiftUI

/// A persistent, non-modal question. Independent of the optional recording HUD
/// and Notification Center permissions; recording and level sampling keep running.
@MainActor
final class MeetingCheckInPresenter {
    private var panel: KeyablePanel?

    func update(
        prompt: MeetingCheckIn.Prompt?,
        now: TimeInterval,
        elapsed: TimeInterval,
        onContinue: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        guard let prompt else { dismiss(); return }
        let view = MeetingCheckInView(
            prompt: prompt,
            now: now,
            elapsed: elapsed,
            onContinue: onContinue,
            onStop: onStop
        )
        if let panel {
            (panel.contentView as? NSHostingView<MeetingCheckInView>)?.rootView = view
        } else {
            let panel = KeyablePanel(size: CGSize(width: 420, height: 238))
            panel.level = .statusBar
            panel.contentView = NSHostingView(rootView: view)
            panel.positionAtOpticalCentre()
            panel.orderFrontRegardless()
            self.panel = panel
            // One attention request, never once per countdown tick. Do not steal
            // keyboard focus from a call or another application.
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct MeetingCheckInView: View {
    var prompt: MeetingCheckIn.Prompt
    var now: TimeInterval
    var elapsed: TimeInterval
    var onContinue: () -> Void
    var onStop: () -> Void

    private var detail: String {
        switch prompt {
        case .duration:
            "You’ve been recording for \(Clock.string(elapsed)). Is the meeting still in progress? Recording continues until you stop it."
        case .silence(let deadline):
            if let deadline {
                "No sound detected from the microphone or Mac audio. Recording stops in \(max(0, Int(ceil(deadline - now)))) seconds unless sound returns or you choose to keep recording."
            } else {
                "No sound detected from the microphone or Mac audio. Has the meeting ended? Recording continues until you stop it."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.danger)
                Text("Still in a meeting?")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                Text("REC")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.danger)
            }
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            HStack {
                Button(action: onStop) {
                    Text("Stop & save")
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(.primary.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
                Spacer()
                Button(action: onContinue) {
                    Text("Keep recording")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Color(red: 0.12, green: 0.34, blue: 0.78), in: Capsule())
                        .contentShape(Capsule())
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(width: 420, height: 238)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.15)))
    }
}
