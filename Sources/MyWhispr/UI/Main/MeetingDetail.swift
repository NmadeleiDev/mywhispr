import SwiftUI

enum MeetingDetailMode: String, CaseIterable, Identifiable {
    case transcript
    case notes
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .notes: "Notes"
        case .ask: "Ask"
        }
    }
}

/// Keeps the selected surface stable while SwiftUI refreshes the same meeting.
/// A genuinely different meeting still starts on its transcript.
struct MeetingDetailSelection: Equatable {
    private(set) var sessionID: UUID?
    private(set) var mode: MeetingDetailMode = .transcript

    @discardableResult
    mutating func load(sessionID: UUID) -> Bool {
        guard self.sessionID != sessionID else { return false }
        self.sessionID = sessionID
        mode = .transcript
        return true
    }

    mutating func select(_ mode: MeetingDetailMode) {
        self.mode = mode
    }
}

/// A recorded meeting: transport, transcript, and optional local summary.
///
/// Processing states get real estate rather than a spinner in a corner, because the
/// moment after stopping a meeting is when the owner most needs to know their audio
/// is safe. Once ready, the transcript takes the whole surface.
struct MeetingDetail: View {
    var detail: SessionDetail
    var runtime: AppRuntime

    @State private var titleDraft = ""
    @State private var renamingSpeaker: String?
    @State private var speakerDraft = ""
    @State private var summaryDraft = ""
    @State private var editingSummary = false
    @State private var confirmingDelete = false
    @State private var selection = MeetingDetailSelection()

    /// Asking is only offered once there is something to ask about.
    private var canAsk: Bool {
        detail.session.state == .completed && !detail.segments.isEmpty
    }

    private var mode: MeetingDetailMode { selection.mode }

    private var modeBinding: Binding<MeetingDetailMode> {
        Binding(
            get: { selection.mode },
            set: { selection.select($0) }
        )
    }

    var body: some View {
        ZStack {
            switch mode {
            case .ask where canAsk:
                MeetingChatView(chat: runtime.meetingChat, runtime: runtime)
            case .notes where canAsk:
                notesSurface
            default:
                transcriptSurface
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { titleBar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if mode == .ask, canAsk {
                MeetingChatComposer(chat: runtime.meetingChat, runtime: runtime)
            } else {
                actionBar
            }
        }
        .onChange(of: detail.session.id, initial: true) { _, sessionID in
            guard selection.load(sessionID: sessionID) else { return }
            titleDraft = detail.session.title
            summaryDraft = detail.session.summary ?? ""
            editingSummary = false
        }
        .onChange(of: canAsk) { _, possible in
            if !possible { selection.select(.transcript) }
        }
        .onChange(of: detail.session.title) { _, title in
            titleDraft = title
        }
        .alert("Rename speaker", isPresented: Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )) {
            TextField("Name", text: $speakerDraft)
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
            Button("Rename") {
                if let original = renamingSpeaker {
                    runtime.renameSpeaker(from: original, to: speakerDraft, in: detail.session.id)
                }
                renamingSpeaker = nil
            }
        } message: {
            Text("Every passage spoken by this person is renamed.")
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete meeting and recording", role: .destructive) {
                runtime.deleteSession(id: detail.session.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript, the summary, and both audio tracks are removed from this Mac. This cannot be undone.")
        }
    }

    private var transcriptSurface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch detail.session.state {
                    case .recording:
                        liveNotice
                    case .processing:
                        processingNotice
                    case .failed, .interrupted:
                        recoveryNotice
                    case .completed:
                        EmptyView()
                    }

                    if runtime.playback.duration > 0 {
                        PlaybackBar(playback: runtime.playback)
                    }

                    if !detail.segments.isEmpty {
                        TranscriptView(
                            segments: detail.segments,
                            currentTime: runtime.playback.currentTime,
                            isPlaybackAvailable: runtime.playback.duration > 0,
                            onSeek: { runtime.playback.seek(to: $0) },
                            onEdit: { segment, text in
                                runtime.updateSegment(segment, text: text, speaker: segment.speaker)
                            },
                            onRenameSpeaker: { speaker in
                                speakerDraft = speaker
                                renamingSpeaker = speaker
                            }
                        )
                    }
                }
                .padding(20)
            }
            .onChange(of: runtime.playback.currentTime) { _, time in
                guard runtime.playback.isPlaying,
                      let active = detail.segments.last(where: { $0.start <= time }) else { return }
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(active.id, anchor: .center)
                }
            }
            .task(id: runtime.meetingSourceTarget?.id) {
                guard let target = runtime.meetingSourceTarget,
                      target.sessionID == detail.session.id,
                      let segment = detail.segments.last(where: { $0.start <= target.time }) else { return }
                proxy.scrollTo(segment.id, anchor: .center)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var notesSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if detail.session.summary != nil
                    || runtime.summaryGeneration.isGenerating(for: detail.session.id) {
                    summarySection
                } else {
                    EmptyStateView(
                        icon: "note.text",
                        message: "No notes yet",
                        actionTitle: runtime.canAskLocalAI ? "Write notes" : "Open AI settings",
                        action: {
                            if runtime.canAskLocalAI { runtime.generateSummary(for: detail.session.id) }
                            else { runtime.openWindowHandler?(WindowID.settings) }
                        }
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
            }
            .padding(20)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// The meeting's name, editable in place. Renaming is the most common thing an
    /// owner does to a meeting, so it is the header rather than a menu item.
    private var titleBar: some View {
        HStack(spacing: 10) {
            TextField("Meeting name", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .onSubmit { runtime.renameSession(id: detail.session.id, title: titleDraft) }
            Spacer(minLength: 8)
            if canAsk {
                Picker("", selection: modeBinding) {
                    ForEach(MeetingDetailMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Text(detail.session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if detail.session.state == .completed, mode == .notes {
                if runtime.summaryGeneration.isGenerating(for: detail.session.id) {
                    Button {
                        runtime.cancelSummary(for: detail.session.id)
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                } else {
                    Picker("Summary language", selection: Binding(
                        get: { runtime.settings.payload.localAI.summaryLanguage },
                        set: { runtime.settings.payload.localAI.summaryLanguage = $0 }
                    )) {
                        ForEach(SummaryLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("Language for the generated title and summary")
                    .disabled(runtime.summaryGeneration.isActive)

                    Button {
                        runtime.generateSummary(for: detail.session.id)
                    } label: {
                        Label(
                            detail.session.summary == nil ? "Summarize" : "Regenerate",
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!runtime.canAskLocalAI || runtime.summaryGeneration.isActive)
                    .help(
                        !runtime.canAskLocalAI
                            ? "Connect a local AI service in Settings to summarize"
                            : runtime.summaryGeneration.isActive
                                ? "Wait for the other summary to finish"
                                : "Write meeting notes with your local AI model"
                    )
                }

            }

            if detail.session.state == .completed, mode == .transcript {
                ConfirmingButton(
                    title: "Copy transcript",
                    systemImage: "doc.on.doc",
                    confirmation: "Transcript copied"
                ) { runtime.copy(detail.transcript, note: "Transcript copied.") }
            }

            if detail.session.state == .failed || detail.session.state == .interrupted {
                Button {
                    runtime.retrySession(id: detail.session.id)
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .controlSize(.small)
            }

            Spacer()

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Delete this meeting and its recording")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.bar)
    }

    // MARK: - State notices

    private var liveNotice: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.accent).frame(width: 8, height: 8)
            Text("Recording")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Stop") { runtime.stopMeeting() }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .controlSize(.small)
        }
        .padding(12)
        .glassEffect(.regular.tint(Palette.accent.opacity(0.14)), in: .rect(cornerRadius: Metrics.card, style: .continuous))
    }

    /// Progress with the reassurance that matters most at this moment: the audio is
    /// already on disk, so waiting is safe and interruption is survivable.
    private var processingNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(runtime.meetingStageDescription)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let progress = runtime.meetingProgress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tabularTime()
                }
            }
            if let progress = runtime.meetingProgress {
                ProgressView(value: progress)
                    .tint(Palette.accent)
            }
            Text("Both recordings are saved. You can close this window.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.card, style: .continuous))
    }

    private var recoveryNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.trianglehead.counterclockwise")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    detail.session.state == .interrupted
                        ? "MyWhispr stopped before this meeting finished processing"
                        : "Processing did not finish"
                )
                .font(.system(size: 12, weight: .semibold))
                Text(detail.session.errorMessage ?? "The recorded audio is still on this Mac, so nothing has to be recorded again.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Try again") { runtime.retrySession(id: detail.session.id) }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .controlSize(.small)
        }
        .padding(12)
        .glassEffect(.regular.tint(Palette.accent.opacity(0.12)), in: .rect(cornerRadius: Metrics.card, style: .continuous))
    }

    // MARK: - Summary

    private var summarySection: some View {
        Card(title: "Notes") {
            if runtime.summaryGeneration.isGenerating(for: detail.session.id) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Writing notes with \(runtime.summaryModelName)…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if editingSummary {
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $summaryDraft)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140)
                    HStack(spacing: 8) {
                        Button("Cancel") {
                            summaryDraft = detail.session.summary ?? ""
                            editingSummary = false
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        Button("Save") {
                            runtime.updateSummary(summaryDraft, for: detail.session.id)
                            editingSummary = false
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Palette.accent)
                        .controlSize(.small)
                    }
                }
            } else if let summary = detail.session.summary {
                VStack(alignment: .leading, spacing: 10) {
                    // Markdown is what the summary prompt asks the model for, so it is
                    // rendered rather than shown as raw asterisks. `Text` alone only
                    // covers the inline half of Markdown; the headings and bullets a
                    // model writes notes with are block-level and printed literally.
                    MarkdownText(markdown: summary)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button("Edit") {
                            summaryDraft = summary
                            editingSummary = true
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        ConfirmingButton(
                            title: "Copy",
                            systemImage: "doc.on.doc",
                            confirmation: "Copied"
                        ) { runtime.copy(summary, note: "Summary copied.") }
                    }
                }
            }
        }
    }
}
