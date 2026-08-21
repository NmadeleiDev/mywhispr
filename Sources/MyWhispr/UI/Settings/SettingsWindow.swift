import SwiftUI

/// The settings window's own navigation.
///
/// A `TabView` was wrong here twice over. Structurally, macOS hands a tab view's
/// picker to the window's titlebar — and these windows deliberately draw their own
/// chrome under a transparent titlebar, so the picker landed on top of the traffic
/// lights and collapsed into an overflow chevron. Editorially, seven destinations is
/// past what a segmented control can name legibly; a sidebar states all seven at
/// once, which is the whole point of a settings window.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case dictation
    case meetings
    case vocabulary
    case models
    case localAI
    case shortcuts
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .meetings: "Meetings"
        case .vocabulary: "Your Words"
        case .models: "Models"
        case .localAI: "Local AI"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "mic"
        case .meetings: "person.wave.2"
        case .vocabulary: "character.book.closed"
        case .models: "cube.box"
        case .localAI: "sparkles"
        case .shortcuts: "keyboard"
        case .privacy: "hand.raised"
        }
    }
}

struct SettingsWindow: View {
    @Environment(AppRuntime.self) private var runtime
    @State private var section: SettingsSection = .general
    @State private var lastApplied: SettingsStore.Payload?

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $section)
                .frame(width: 196)

            Divider().opacity(0.4)

            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
        .frame(minWidth: 700, minHeight: 460)
        // Every setting that reaches outside its own value — shortcuts, the Dock
        // icon, retention — is re-applied here, so a change takes hold immediately
        // instead of at the next launch.
        .onChange(of: runtime.settings.payload) { previous, _ in
            runtime.applySettings(previous: lastApplied ?? previous)
            lastApplied = runtime.settings.payload
        }
        .task { lastApplied = runtime.settings.payload }
    }

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .general: GeneralSettings(runtime: runtime)
        case .dictation: DictationSettings(runtime: runtime)
        case .meetings: MeetingSettings(runtime: runtime)
        case .vocabulary: VocabularySettings(runtime: runtime)
        case .models: ModelSettings(runtime: runtime)
        case .localAI: LocalAISettings(runtime: runtime)
        case .shortcuts: ShortcutSettings(runtime: runtime)
        case .privacy: PrivacySettings(runtime: runtime)
        }
    }
}

/// The list of destinations, sitting in the band the transparent titlebar frees up.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        VStack(spacing: 2) {
            // Clears the traffic lights, matching the main window's header inset so
            // the two surfaces line up when both are open.
            Color.clear.frame(height: 30)

            ForEach(SettingsSection.allCases) { item in
                SettingsSidebarRow(
                    item: item,
                    isSelected: selection == item,
                    select: { selection = item }
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
    }
}

private struct SettingsSidebarRow: View {
    var item: SettingsSection
    var isSelected: Bool
    var select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 17, alignment: .center)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.10 : (isHovering ? 0.05 : 0)))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.12), value: isSelected)
        .animation(.smooth(duration: 0.12), value: isHovering)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Shared shell so every pane scrolls identically and shares one padding rhythm.
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

struct GeneralSettings: View {
    @Bindable var runtime: AppRuntime

    var body: some View {
        @Bindable var settings = runtime.settings

        SettingsPane {
            Card(title: "Startup") {
                SettingRow(label: "Open MyWhispr at login") {
                    Toggle("", isOn: Binding(
                        get: { settings.payload.launchAtLogin },
                        set: { runtime.setLaunchAtLogin($0) }
                    ))
                }
                SettingRow(
                    label: "Show in the Dock",
                    detail: "MyWhispr always lives in the menu bar. The Dock icon is optional."
                ) {
                    Toggle("", isOn: $settings.payload.showDockIcon)
                }
            }

            Card(title: "Feedback") {
                SettingRow(
                    label: "Show the recording window",
                    detail: "The capsule above the Dock that shows your voice and progress."
                ) {
                    Toggle("", isOn: $settings.payload.showHUD)
                }
                SettingRow(
                    label: "Play a sound when recording starts and stops",
                    detail: "Useful when the recording window is turned off."
                ) {
                    Toggle("", isOn: $settings.payload.playCues)
                }
            }

            Card(
                title: "Capture limits",
                footnote: "A brush against the dictation key is discarded rather than transcribed. The ceiling protects against a key left stuck down by another app."
            ) {
                SettingRow(label: "Ignore takes shorter than") {
                    HStack(spacing: 6) {
                        Stepper(
                            value: $settings.payload.minimumDictationSeconds,
                            in: 0.1...2,
                            step: 0.05
                        ) {
                            Text(String(format: "%.2fs", settings.payload.minimumDictationSeconds))
                                .font(.system(size: 12, design: .rounded))
                                .tabularTime()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                SettingRow(label: "Stop a dictation after") {
                    Stepper(
                        value: $settings.payload.maximumDictationSeconds,
                        in: 30...1_800,
                        step: 30
                    ) {
                        Text(Clock.compact(settings.payload.maximumDictationSeconds))
                            .font(.system(size: 12, design: .rounded))
                            .frame(width: 62, alignment: .trailing)
                    }
                }
            }
        }
    }
}
