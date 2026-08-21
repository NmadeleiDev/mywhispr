import AppKit
import SwiftUI

struct ShortcutSettings: View {
    @Bindable var runtime: AppRuntime

    var body: some View {
        @Bindable var settings = runtime.settings

        SettingsPane {
            Card(
                title: "Dictation",
                footnote: "Hold the key to record, let go to insert. Pressing another key while holding cancels the take, so ⌘C still copies."
            ) {
                SettingRow(label: "Turn on hold-to-talk") {
                    Toggle("", isOn: $settings.payload.pushToTalkEnabled)
                }
                SettingRow(label: "Hold this key") {
                    Picker("", selection: $settings.payload.pushToTalkKey) {
                        ForEach(PushToTalkKey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    .disabled(!settings.payload.pushToTalkEnabled)
                }
            }

            Card(
                title: "Everything else",
                footnote: "Click a shortcut and press the keys you want. These are reserved system-wide, so they will not reach the app you are working in."
            ) {
                ShortcutField(
                    label: "Start or stop a meeting",
                    binding: $settings.payload.meetingShortcut,
                    conflict: runtime.shortcutConflicts.contains(.toggleMeeting)
                )
                SettingRow(
                    label: "Offer recent dictations to insert",
                    detail: "Opens a list of what you have said, filtered as you type."
                ) {
                    Toggle("", isOn: $settings.payload.quickPasteEnabled)
                }
                if settings.payload.quickPasteEnabled {
                    ShortcutField(
                        label: "Insert something you said earlier",
                        binding: $settings.payload.quickPasteShortcut,
                        conflict: runtime.shortcutConflicts.contains(.quickPaste)
                    )
                }
                ShortcutField(
                    label: "Open the MyWhispr window",
                    binding: $settings.payload.openWindowShortcut,
                    conflict: runtime.shortcutConflicts.contains(.openMainWindow)
                )
            }

            HStack {
                Button("Restore defaults") { runtime.resetShortcuts() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                Spacer()
            }
        }
    }
}

/// Click to record a key combination, the way every macOS shortcut field works.
struct ShortcutField: View {
    var label: String
    @Binding var binding: ShortcutBinding
    var conflict: Bool

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        SettingRow(
            label: label,
            detail: conflict ? "Another app already uses this combination." : nil
        ) {
            HStack(spacing: 6) {
                Button {
                    recording ? stopRecording() : startRecording()
                } label: {
                    Text(recording ? "Press keys…" : binding.displayString)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(minWidth: 84)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                }
                .buttonStyle(.glass)
                .tint(conflict ? Palette.danger : nil)

                if binding.isEnabled {
                    Button {
                        binding.isEnabled = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Turn this shortcut off")
                } else {
                    Button("Off") { binding.isEnabled = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape abandons recording rather than binding Escape itself, which
            // would leave no way out of the field.
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            if let candidate = ShortcutBinding(event: event) {
                binding = candidate
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
