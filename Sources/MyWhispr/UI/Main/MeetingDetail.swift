import SwiftUI

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
    @State private var mode: Mode = .transcript

    /// The two things an owner does with a finished meeting: read it, or ask about
    /// it. They are alternatives rather than neighbours — each wants the whole
    /// surface and its own scroll position — so they are a switch, not two panes.
    private enum Mode: String, CaseIterable, Identifiable {
        case transcript
        case ask

        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcript: "Transcript"
            case .ask: "Ask"
            }
        }
    }

    /// Asking is only offered once there is something to ask about.
    private var canAsk: Bool {
        detail.session.state == .completed && !detail.segments.isEmpty
    }

    var body: some View {
        Group {
            if mode == .ask, canAsk {
                MeetingChatView(chat: runtime.chat, runtime: runtime)
            } else {
                transcriptSurface
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { titleBar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if mode == .ask, canAsk {
                MeetingChatComposer(chat: runtime.chat, runtime: runtime)
            } else {
                actionBar
            }
        }
        .task(id: detail.session.id) {
            titleDraft = detail.session.title
            summaryDraft = detail.session.summary ?? ""
            editingSummary = false
            mode = .transcript
        }
        .onChange(of: canAsk) { _, possible in
            if !possible { mode = .transcript }
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

                    if detail.session.summary != nil || runtime.isGeneratingSummary {
                        summarySection
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
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
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
            if detail.session.state == .completed {
                if runtime.isGeneratingSummary {
                    Button {
                        runtime.cancelSummary()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                } else {
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
                    .disabled(!runtime.canAskLocalAI)
                    .help(
                        runtime.canAskLocalAI
                            ? "Write meeting notes with your local AI model"
                            : "Connect a local AI service in Settings to summarize"
                    )
                }

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
        .padding(.vertical, 10)
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
        Card(title: "Summary") {
            if runtime.isGeneratingSummary {
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
