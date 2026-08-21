import AppKit
import SwiftUI

/// First-run setup, structured as the journey rather than as a tour.
///
/// There is no explanatory carousel: the owner grants exactly the permissions that
/// unblock the next step, then proves it works by doing the real thing — holding the
/// key and watching text arrive in a live text field. Setup succeeds through the
/// actual product action, so the last step is also the first successful use.
struct SetupWindow: View {
    @Environment(AppRuntime.self) private var runtime

    @State private var testField = ""
    @State private var sawInsertion = false
    @FocusState private var testFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PermissionStep(
                        index: 1,
                        title: "Hear your voice",
                        detail: "MyWhispr records only while you hold the dictation key.",
                        status: runtime.permissions.microphone,
                        action: { Task { await runtime.permissions.requestMicrophone() } },
                        openSettings: { runtime.permissions.openPrivacySettings("Privacy_Microphone") }
                    )
                    PermissionStep(
                        index: 2,
                        title: "Notice the key, and type for you",
                        detail: "Lets MyWhispr see the dictation key while you work in other apps, and place finished text at your cursor.",
                        status: runtime.permissions.accessibility,
                        action: { runtime.permissions.requestAccessibility() },
                        openSettings: { runtime.permissions.openPrivacySettings("Privacy_Accessibility") }
                    )

                    tryItStep
                    stuckHint
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 620)
        .background(.background)
        // The owner grants these in System Settings, another application entirely,
        // and macOS posts no notification when a toggle flips. Polling while this
        // window is open is what makes the checkmarks appear as they switch them on.
        .task {
            runtime.permissions.beginPolling()
        }
        .onDisappear { runtime.permissions.endPolling() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            runtime.permissions.refresh()
            runtime.configureHotkeys()
        }
        .onChange(of: runtime.lastInsertedText) { _, value in
            if value != nil, testFocused { sawInsertion = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up MyWhispr")
                .font(.system(size: 20, weight: .semibold))
            Text("Everything below stays on this Mac. Nothing is uploaded.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    /// The escape hatch for the one case the polling cannot solve on its own.
    ///
    /// Input Monitoring is decided per process at launch, so a permission granted
    /// while MyWhispr is already running does not take effect until it restarts.
    /// Saying so — and offering the restart — beats leaving someone toggling a
    /// switch that visibly does nothing.
    @ViewBuilder
    private var stuckHint: some View {
        if runtime.needsRestartToListen {
            // The important case, and the one that used to be invisible: all three
            // permissions read as allowed, so nothing looks wrong, yet the key does
            // nothing because this process predates the Input Monitoring grant.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.trianglehead.counterclockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("One more step — MyWhispr needs to restart")
                        .font(.system(size: 12, weight: .semibold))
                    Text("macOS only lets an app watch the keyboard from the moment it starts, and permission was granted after this one launched.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Restart") { runtime.relaunch() }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                    .controlSize(.small)
            }
            .padding(12)
            .glassEffect(.regular.tint(Palette.accent.opacity(0.14)), in: .rect(cornerRadius: Metrics.card, style: .continuous))
        } else if !runtime.permissions.dictationReady {
            HStack(spacing: 8) {
                Text("Switched something on and it still shows here?")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Button("Restart MyWhispr") { runtime.relaunch() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accent)
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    /// The proof step. Deliberately a real editable field: holding the key here
    /// exercises the same capture, transcription, and insertion path used in Mail.
    private var tryItStep: some View {
        Card(
            title: "3 · Try it",
            footnote: runtime.needsRestartToListen
                ? "Restart MyWhispr first — see below."
                : runtime.permissions.dictationReady
                    ? "Hold \(runtime.settings.payload.pushToTalkKey.displayName), say a few words, and let go."
                    : "Finish the steps above first."
        ) {
            TextField("Click here, then hold the key and speak", text: $testField, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(3...6)
                .focused($testFocused)
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            testFocused ? Palette.accent.opacity(0.7) : Color(nsColor: .separatorColor),
                            lineWidth: testFocused ? 1.5 : 0.5
                        )
                )
                .disabled(!runtime.permissions.dictationReady)
                .animation(.smooth(duration: 0.2), value: testFocused)

            if sawInsertion || !testField.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.affirm)
                    Text("That is dictation working. It behaves the same in every app.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") {
                        runtime.settings.payload.hasCompletedSetup = true
                        runtime.closeWindowHandler?(WindowID.setup)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                    .controlSize(.small)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.smooth(duration: 0.3), value: testField.isEmpty)
    }
}

private struct PermissionStep: View {
    var index: Int
    var title: String
    var detail: String
    var status: PermissionCenter.Status
    var action: () -> Void
    var openSettings: () -> Void
    /// Only supplied for Input Monitoring, whose System Settings list has an "+"
    /// button that opens a picker rooted where a locally built app is not.
    var revealInFinder: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            marker
            VStack(alignment: .leading, spacing: 3) {
                Text("\(index) · \(title)")
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.card, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var marker: some View {
        ZStack {
            Circle()
                .fill(status == .granted ? Palette.affirm.opacity(0.16) : Color.secondary.opacity(0.12))
                .frame(width: 24, height: 24)
            Image(systemName: status == .granted ? "checkmark" : "\(index).circle")
                .font(.system(size: status == .granted ? 11 : 13, weight: .bold))
                .foregroundStyle(status == .granted ? Palette.affirm : .secondary)
        }
        .animation(.smooth(duration: 0.25), value: status)
    }

    @ViewBuilder
    private var control: some View {
        if status == .granted {
            EmptyView()
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                // Allow comes first because pressing it is also what registers
                // MyWhispr in the corresponding System Settings list. Sending someone
                // to that list before the app appears in it is a dead end.
                Button("Allow", action: action)
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                    .controlSize(.small)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if let revealInFinder {
                    Button("Show app in Finder", action: revealInFinder)
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("Drag MyWhispr into the list, or use ⌘⇧G in the picker")
                }
            }
        }
    }
}
