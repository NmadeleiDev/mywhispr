import SwiftUI

enum WindowID {
    static let main = "main"
    static let setup = "setup"
}

/// The quiet front door to MyWhispr's three jobs: dictate, record, and ask.
struct MainWindow: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @Namespace private var workspaceTransition
    @State private var destination = Destination.home
    @State private var showingWorkspaceConversation = false
    @State private var confirmingWorkspaceClear = false
    /// A meeting owns irreplaceable audio, so its deletion is confirmed. A dictation
    /// is text that can be spoken again, so it is not — asking every time would
    /// train the owner to dismiss the question that matters.
    @State private var meetingPendingDeletion: SessionRecord?

    private enum Destination { case home, library }

    enum InitialDestination {
        case home
        case workspaceConversation
        case library
    }

    init(initialDestination: InitialDestination = .home) {
        switch initialDestination {
        case .home:
            _destination = State(initialValue: .home)
            _showingWorkspaceConversation = State(initialValue: false)
        case .workspaceConversation:
            _destination = State(initialValue: .home)
            _showingWorkspaceConversation = State(initialValue: true)
        case .library:
            _destination = State(initialValue: .library)
            _showingWorkspaceConversation = State(initialValue: false)
        }
    }

    var body: some View {
        @Bindable var runtime = runtime

        HStack(spacing: 0) {
            appSidebar
                .frame(width: 196)
                .fixedSize(horizontal: true, vertical: false)

            Divider().opacity(0.4)

            VStack(spacing: 0) {
                globalHeader
                Divider().opacity(0.4)
                Group {
                    switch destination {
                    case .home: home
                    case .library: library
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(.background)
        .overlay(alignment: .topTrailing) {
            if let toast = runtime.toast.current {
                ToastView(toast: toast) { runtime.toast.dismiss() }
                    .padding(.top, 72)
                    .padding(.trailing, 16)
                    .id(toast.id)
                    .transition(toastTransition)
                    .zIndex(10)
            }
        }
        .animation(toastAnimation, value: runtime.toast.current)
        .onAppear { selectFirstLibraryRecordIfNeeded() }
        .onChange(of: destination) { _, _ in selectFirstLibraryRecordIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .myWhisprFocusSearch)) { _ in
            destination = .library
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .myWhisprOpenLibrary)) { _ in
            destination = .library
        }
        .onChange(of: runtime.sessions.map(\.id)) { _, ids in
            guard destination == .library else { return }
            if let selected = runtime.selectedSessionID, ids.contains(selected) { return }
            runtime.selectedSessionID = ids.first
        }
        .onChange(of: runtime.workspaceChat.isEmpty) { _, empty in
            guard empty, !runtime.workspaceChat.isBusy else { return }
            showingWorkspaceConversation = false
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
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $confirmingWorkspaceClear,
            titleVisibility: .visible
        ) {
            Button("Clear conversation", role: .destructive) { runtime.workspaceChat.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Questions and answers will be removed. Meetings stay unchanged.")
        }
    }

    private var toastTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    private var toastAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.24)
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

    private func selectFirstLibraryRecordIfNeeded() {
        guard destination == .library, runtime.selectedSessionID == nil else { return }
        runtime.selectedSessionID = runtime.sessions.first?.id
    }

    private var appSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MyWhispr")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            destinationButton("Home", systemImage: "house", destination: .home)
            destinationButton("Library", systemImage: "rectangle.stack", destination: .library)

            Spacer()

            Button {
                runtime.openWindowHandler?(WindowID.settings)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 44)
        .padding(.bottom, 12)
        .background(.background.secondary)
    }

    private func destinationButton(
        _ title: String,
        systemImage: String,
        destination next: Destination
    ) -> some View {
        Button {
            destination = next
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    destination == next ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private var globalHeader: some View {
        HStack(spacing: 10) {
            if destination == .home, showingWorkspaceConversation {
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .glassMorph) {
                        showingWorkspaceConversation = false
                    }
                } label: {
                    Label("Home", systemImage: "chevron.left")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                if !runtime.workspaceChat.isEmpty {
                    Menu {
                        Button("Clear conversation", role: .destructive) {
                            confirmingWorkspaceClear = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Conversation options")
                }
            }
            Spacer()
            if runtime.isMeetingActive {
                ActiveMeetingPill(runtime: runtime)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 10)
        .frame(minHeight: 64)
    }

    @ViewBuilder
    private var home: some View {
        ZStack {
            if showingWorkspaceConversation {
                workspaceConversation
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.015)))
            } else {
                HomeStartView(
                    runtime: runtime,
                    namespace: workspaceTransition,
                    ask: askFromHome
                )
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .glassMorph, value: showingWorkspaceConversation)
    }

    private var workspaceConversation: some View {
        MeetingChatView(chat: runtime.workspaceChat, runtime: runtime)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                WorkspaceComposer(
                    chat: runtime.workspaceChat,
                    runtime: runtime,
                    namespace: workspaceTransition,
                    compact: true
                )
            }
    }

    private func askFromHome() {
        runtime.workspaceChat.send()
        guard runtime.workspaceChat.messages.last?.role == .user else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .glassMorph) {
            showingWorkspaceConversation = true
        }
    }

    @ViewBuilder
    private var library: some View {
        @Bindable var runtime = runtime
        if runtime.sessions.isEmpty, runtime.searchText.isEmpty {
            VStack(spacing: 18) {
                Picker("", selection: $runtime.filter) {
                    Text("Meetings").tag(WorkflowKind.meeting)
                    Text("Dictations").tag(WorkflowKind.dictation)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                EmptyStateView(
                    icon: runtime.filter == .dictation ? "waveform" : "person.wave.2",
                    message: runtime.filter == .dictation ? "No dictations yet" : "No meetings yet",
                    actionTitle: runtime.filter == .dictation ? "Home" : "Start meeting",
                    action: {
                        if runtime.filter == .meeting { runtime.startMeeting() }
                        else { destination = .home }
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        Picker("", selection: $runtime.filter) {
                            Text("Meetings").tag(WorkflowKind.meeting)
                            Text("Dictations").tag(WorkflowKind.dictation)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SearchField(
                            text: $runtime.searchText,
                            prompt: runtime.filter == .dictation ? "Search dictations" : "Search meetings",
                            focused: $searchFocused
                        )
                    }
                    .padding(12)

                    Divider().opacity(0.4)

                    SessionList(
                        sessions: runtime.sessions,
                        kind: runtime.filter,
                        selection: $runtime.selectedSessionID,
                        searchText: runtime.searchText,
                        summaryGenerationSessionID: runtime.summaryGeneration.sessionID,
                        onDelete: { requestDelete($0) }
                    )
                }
                .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)

                libraryDetail
                    .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var libraryDetail: some View {
        if let detail = runtime.selectedDetail {
            switch detail.session.kind {
            case .dictation:
                DictationDetail(detail: detail, runtime: runtime)
            case .meeting:
                MeetingDetail(detail: detail, runtime: runtime)
            }
        } else {
            EmptyStateView(
                icon: runtime.filter == .dictation ? "waveform" : "person.wave.2",
                message: runtime.searchText.isEmpty
                    ? (runtime.filter == .dictation ? "No dictations yet" : "No meetings yet")
                    : "No matches",
                actionTitle: runtime.searchText.isEmpty
                    ? (runtime.filter == .dictation ? "Home" : "Start meeting")
                    : nil,
                action: runtime.searchText.isEmpty ? {
                    if runtime.filter == .meeting { runtime.startMeeting() }
                    else { destination = .home }
                } : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct HomeStartView: View {
    var runtime: AppRuntime
    var namespace: Namespace.ID
    var ask: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                dictationCard
                meetingCard
            }
            .frame(height: 190)

            WorkspaceComposer(
                chat: runtime.workspaceChat,
                runtime: runtime,
                namespace: namespace,
                compact: false,
                send: ask
            )
        }
        .frame(maxWidth: 720)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            runtime.workspaceChat.loadWorkspace()
            runtime.permissions.beginPolling()
        }
        .onDisappear { runtime.permissions.endPolling() }
    }

    private var dictationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Right ⌘")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 0.5))
            Text("Hold and speak")
                .font(.system(size: 16, weight: .semibold))
            Text("Speech appears at your cursor.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Label(
                    runtime.permissions.dictationReady ? "Ready" : "Needs setup",
                    systemImage: runtime.permissions.dictationReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundStyle(runtime.permissions.dictationReady ? Palette.affirm : Palette.accent)
                Spacer()
                if !runtime.permissions.dictationReady {
                    Button("Set up dictation") { runtime.openWindowHandler?(WindowID.setup) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))
        }
        .homeCard()
    }

    @ViewBuilder
    private var meetingCard: some View {
        if runtime.isMeetingActive {
            meetingCardContent
                .homeCard()
        } else {
            Button { runtime.startMeeting() } label: {
                meetingCardContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .homeCard()
            .disabled(!runtime.canStartMeeting)
        }
    }

    private var meetingCardContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: runtime.isMeetingActive ? "record.circle.fill" : "record.circle")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(runtime.isMeetingActive ? Palette.danger : .secondary)
            Text(runtime.isMeetingActive ? "Recording" : "Start meeting")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Label("Microphone", systemImage: runtime.permissions.microphone == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
            Label("Mac audio when available", systemImage: "desktopcomputer")
            HStack(spacing: 12) {
                Text("In person or online")
                Text("Records without internet")
            }
            Text("Also in the menu bar")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private extension View {
    func homeCard() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(20)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.card).strokeBorder(.separator.opacity(0.65), lineWidth: 0.5))
    }
}

private struct WorkspaceComposer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var chat: ConversationController
    var runtime: AppRuntime
    var namespace: Namespace.ID
    var compact: Bool
    var send: (() -> Void)?

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("All meetings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !runtime.canAskLocalAI {
                    Text("AI is unavailable.")
                        .foregroundStyle(.secondary)
                    Button("Open AI settings") {
                        runtime.openWindowHandler?(WindowID.settings)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                }
            }
            .font(.system(size: 11))
            HStack(spacing: 10) {
                TextField(compact ? "Ask a follow-up" : "Ask anything about your meetings", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { (send ?? chat.send)() }

                Button {
                    if chat.isBusy { chat.stop() }
                    else { (send ?? chat.send)() }
                } label: {
                    Label(chat.isBusy ? "Stop" : "Ask", systemImage: chat.isBusy ? "stop.fill" : "arrow.up")
                        .frame(minWidth: 56)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .disabled(!chat.isBusy && (!chat.canSend || !runtime.canAskLocalAI))
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.card).strokeBorder(.separator.opacity(0.7), lineWidth: 0.5))
        .modifier(WorkspaceComposerGeometry(namespace: namespace, enabled: !reduceMotion))
        .padding(compact ? 16 : 0)
    }
}

private struct WorkspaceComposerGeometry: ViewModifier {
    var namespace: Namespace.ID
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.matchedGeometryEffect(id: "workspace-composer", in: namespace)
        } else {
            content
        }
    }
}

/// A connected live object: status, elapsed time, and the only Stop action stay in
/// one place no matter which screen is open.
private struct ActiveMeetingPill: View {
    var runtime: AppRuntime

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.danger)
                .frame(width: 7, height: 7)
            Text(Clock.string(runtime.meetingElapsed))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Divider().frame(height: 14)
            Button("Stop") { runtime.stopMeeting() }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.danger)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 11)
        .frame(height: 30)
        .glassEffect(.regular, in: .capsule)
        .help("Stop recording and start transcribing")
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
