import SwiftUI

enum WindowID {
    static let main = "main"
    static let setup = "setup"
}

/// The app's main window: a list of what you have said, and the detail of one item.
///
/// The two workflows the owner thinks in — dictation and meetings — are the top
/// level choice, named in their words. There is no "sessions" concept on screen even
/// though both share a storage type, because collapsing them would ask the owner to
/// learn the database's vocabulary instead of using their own.
struct MainWindow: View {
    @Environment(AppRuntime.self) private var runtime
    @FocusState private var searchFocused: Bool
    /// A meeting owns irreplaceable audio, so its deletion is confirmed. A dictation
    /// is text that can be spoken again, so it is not — asking every time would
    /// train the owner to dismiss the question that matters.
    @State private var meetingPendingDeletion: SessionRecord?

    var body: some View {
        @Bindable var runtime = runtime

        HSplitView {
            sidebar(runtime: runtime)
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)

            VStack(spacing: 0) {
                DetailHeader(runtime: runtime)
                Divider().opacity(0.4)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 460)
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(.background)
        .onReceive(NotificationCenter.default.publisher(for: .myWhisprFocusSearch)) { _ in
            searchFocused = true
        }
        .confirmationDialog(
            "Delete “\(meetingPendingDeletion?.title ?? "this meeting")”?",
            isPresented: Binding(
                get: { meetingPendingDeletion != nil },
                set: { if !$0 { meetingPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete meeting and recording", role: .destructive) {
                if let meeting = meetingPendingDeletion { runtime.deleteSession(id: meeting.id) }
                meetingPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { meetingPendingDeletion = nil }
        } message: {
            Text("The transcript, the summary, and both audio tracks are removed from this Mac. This cannot be undone.")
        }
    }

    /// One deletion route for the list, whichever gesture asked for it.
    private func requestDelete(_ id: UUID) {
        guard let session = runtime.sessions.first(where: { $0.id == id }) else { return }
        if session.kind == .meeting {
            meetingPendingDeletion = session
        } else {
            runtime.deleteSession(id: id)
        }
    }

    private func sidebar(runtime: AppRuntime) -> some View {
        @Bindable var runtime = runtime

        return VStack(spacing: 0) {
            // Sits in the space the transparent titlebar leaves free, so the window
            // reads as one surface rather than chrome stacked on content.
            VStack(spacing: 8) {
                Picker("", selection: $runtime.filter) {
                    Text("Dictation").tag(WorkflowKind.dictation)
                    Text("Meetings").tag(WorkflowKind.meeting)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                SearchField(
                    text: $runtime.searchText,
                    prompt: runtime.filter == .dictation ? "Search dictations" : "Search meetings",
                    focused: $searchFocused
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 34)
            .padding(.bottom, 10)

            Divider().opacity(0.4)

            SessionList(
                sessions: runtime.sessions,
                kind: runtime.filter,
                selection: $runtime.selectedSessionID,
                searchText: runtime.searchText,
                onDelete: { requestDelete($0) }
            )
        }
        .background(.background.secondary)
    }

    @ViewBuilder
    private var detail: some View {
        if let detail = runtime.selectedDetail {
            switch detail.session.kind {
            case .dictation:
                DictationDetail(detail: detail, runtime: runtime)
            case .meeting:
                MeetingDetail(detail: detail, runtime: runtime)
            }
        } else {
            EmptyStateView(
                icon: runtime.filter == .dictation ? "text.cursor" : "waveform.badge.mic",
                message: runtime.filter == .dictation
                    ? "Select a dictation to read, edit, or reuse it."
                    : "Select a meeting to read its transcript."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The window's own header, in the band the transparent titlebar frees up.
private struct DetailHeader: View {
    var runtime: AppRuntime

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                MeetingToggleButton(runtime: runtime)
                Button {
                    runtime.openWindowHandler?(WindowID.settings)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.top, 30)
            .padding(.bottom, 10)

            if !runtime.permissions.dictationReady {
                PermissionBanner(runtime: runtime)
            }
            if let message = runtime.bannerMessage {
                BannerView(message: message) { runtime.bannerMessage = nil }
            }
        }
        .animation(.smooth(duration: 0.25), value: runtime.bannerMessage)
    }
}

/// One button that both starts and stops a meeting, because to the owner it is one
/// switch, not two commands.
struct MeetingToggleButton: View {
    var runtime: AppRuntime

    var body: some View {
        Button {
            runtime.toggleMeeting()
        } label: {
            Label(
                runtime.isMeetingActive ? "Stop meeting" : "Start meeting",
                systemImage: runtime.isMeetingActive ? "stop.fill" : "record.circle"
            )
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.glassProminent)
        .tint(runtime.isMeetingActive ? Palette.danger : Palette.accent)
        .disabled(!runtime.canStartMeeting && !runtime.isMeetingActive)
        .help(
            runtime.isMeetingActive
                ? "Stop recording and start transcribing"
                : "Record your microphone and this Mac's audio together"
        )
    }
}

/// Shown while dictation cannot work. Names the missing capability in terms of what
/// stops working, not in terms of the macOS permission's own vocabulary.
struct PermissionBanner: View {
    var runtime: AppRuntime

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.accent)
            Text(runtime.permissions.blockedSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Finish setup") { runtime.openWindowHandler?(WindowID.setup) }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular.tint(Palette.accent.opacity(0.12)), in: .rect(cornerRadius: Metrics.card, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// Search input styled to match the app rather than the system field.
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    /// Owned by the enclosing view so Edit ▸ Find can put the cursor here.
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    focused.wrappedValue ? Palette.accent.opacity(0.6) : Color(nsColor: .separatorColor),
                    lineWidth: focused.wrappedValue ? 1.5 : 0.5
                )
        )
        .animation(.smooth(duration: 0.15), value: focused.wrappedValue)
    }
}
