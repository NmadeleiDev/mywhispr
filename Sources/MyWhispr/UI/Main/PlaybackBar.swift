import AppKit
import SwiftUI

/// Transport for a meeting's two synchronized tracks.
///
/// The scrubber is the shared clock between audio and transcript: dragging it moves
/// the highlighted passage, and clicking a passage moves it. Neither direction
/// needs a label because the two are visibly the same timeline.
struct PlaybackBar: View {
    var playback: MeetingPlaybackController
    @State private var scrubbing: Double?
    @State private var spaceMonitor: Any?

    private var position: Double {
        scrubbing ?? playback.currentTime
    }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .help(playback.isPlaying ? "Pause" : "Play")

            Text(Clock.string(position))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .tabularTime()
                .frame(width: 46, alignment: .leading)

            Slider(
                value: Binding(
                    get: { position },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(playback.duration, 0.01)
            ) { editing in
                if !editing, let target = scrubbing {
                    playback.seek(to: target)
                    scrubbing = nil
                }
            }
            .tint(Palette.accent)

            Text(Clock.string(playback.duration))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .tabularTime()
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.card, style: .continuous))
        .onAppear(perform: startSpaceMonitor)
        .onDisappear(perform: stopSpaceMonitor)
    }

    /// Space plays and pauses, the way it does in every Mac media app.
    ///
    /// This is deliberately not a `keyboardShortcut`. AppKit offers key equivalents
    /// a keystroke *before* the first responder sees it, so a declarative space
    /// shortcut would swallow the space bar while the owner was renaming the
    /// meeting, editing a passage, or typing in the search field — the transport
    /// would hijack the one key that types a word break. Checking the responder
    /// first is the only way to have both.
    private func startSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,
                  !event.modifierFlags.intersects([.command, .option, .control, .shift]),
                  let window = NSApp.keyWindow,
                  window.identifier?.rawValue == WindowID.main,
                  !window.isEditingText
            else { return event }
            playback.toggle()
            return nil
        }
    }

    private func stopSpaceMonitor() {
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        spaceMonitor = nil
    }
}

extension NSEvent.ModifierFlags {
    /// True when any of `others` is held. `intersection(_:).isEmpty` reads backwards
    /// at the call sites that care, which are all asking "is this a bare keystroke?".
    func intersects(_ others: NSEvent.ModifierFlags) -> Bool {
        !intersection(others).isEmpty
    }
}

extension NSWindow {
    /// True when the keystroke about to be handled belongs to a text field or text
    /// view rather than to the window's own commands.
    var isEditingText: Bool {
        switch firstResponder {
        case let text as NSTextView:
            return text.isEditable
        case is NSTextField:
            return true
        default:
            return false
        }
    }
}
