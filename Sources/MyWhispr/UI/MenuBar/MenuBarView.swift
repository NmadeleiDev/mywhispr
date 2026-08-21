import AppKit
import SwiftUI

/// The menu-bar icon.
///
/// Idle it is a static glyph; recording it becomes a live level meter. That is the
/// requested confirmation that capture is really happening without having to look
/// at the HUD — and it means a meeting recording stays visible for its whole run
/// after the HUD pill has collapsed.
struct MenuBarLabel: View {
    var runtime: AppRuntime

    var body: some View {
        if runtime.isCapturing {
            MenuBarMeter(samples: runtime.meter.samples, isActive: true)
                .foregroundStyle(Palette.accent)
        } else if runtime.isWorking {
            Image(systemName: "waveform.badge.magnifyingglass")
        } else if !runtime.permissions.dictationReady {
            Image(systemName: "waveform.badge.exclamationmark")
        } else {
            Image(systemName: "waveform")
        }
    }
}

/// Contents of the menu-bar panel.
///
/// This is the app's always-available surface, so it answers the two questions that
/// bring someone here — "is it working?" and "what did I just say?" — before
/// offering any commands.
struct MenuBarPanel: View {
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            Divider().padding(.vertical, 6)
            recents
            Divider().padding(.vertical, 6)
            actions
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Status

    @ViewBuilder
    private var status: some View {
        if runtime.isMeetingActive {
            HStack(spacing: 10) {
                Circle().fill(Palette.accent).frame(width: 8, height: 8)
                Text("Recording meeting")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(Clock.string(runtime.meetingElapsed))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tabularTime()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        } else if !runtime.permissions.dictationReady {
            Button {
                runtime.openWindowHandler?(WindowID.setup)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.accent)
                    Text(runtime.permissions.blockedSummary)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 8) {
                Text("Hold")
                    .foregroundStyle(.secondary)
                Text(runtime.settings.payload.pushToTalkKey.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("to dictate")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Recents

    @ViewBuilder
    private var recents: some View {
        if runtime.recentDictations.isEmpty {
            Text("Nothing dictated yet")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(runtime.recentDictations.prefix(5)) { session in
                    Button {
                        runtime.insertFromHistory(sessionID: session.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(session.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.menuRow)
                    .help("Insert this text into the app you were using")
                }
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 1) {
            MenuRow(
                title: runtime.isMeetingActive ? "Stop meeting" : "Start meeting",
                icon: runtime.isMeetingActive ? "stop.fill" : "record.circle",
                shortcut: runtime.settings.payload.meetingShortcut.displayString,
                tint: runtime.isMeetingActive ? Palette.danger : nil
            ) {
                runtime.toggleMeeting()
            }
            .disabled(!runtime.canStartMeeting && !runtime.isMeetingActive)

            MenuRow(
                title: "Open MyWhispr",
                icon: "macwindow",
                shortcut: runtime.settings.payload.openWindowShortcut.displayString
            ) {
runtime.openWindowHandler?(WindowID.main)
            }

            MenuRow(title: "Settings…", icon: "gearshape", shortcut: "⌘,") {
runtime.openWindowHandler?(WindowID.settings)
            }

            MenuRow(title: "Quit MyWhispr", icon: "power", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct MenuRow: View {
    var title: String
    var icon: String
    var shortcut: String?
    var tint: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(tint ?? .secondary)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.menuRow)
    }
}

/// A row that highlights on hover the way a real menu item does.
private struct MenuRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && isEnabled ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == MenuRowButtonStyle {
    fileprivate static var menuRow: MenuRowButtonStyle { MenuRowButtonStyle() }
}
