import SwiftUI

/// One retained dictation: the text, where it went, and what can still be done
/// with it.
///
/// The text is the subject of the view and is editable in place, because a
/// dictation's whole value is the words. Everything else is provenance and sits
/// below in a quieter tier.
struct DictationDetail: View {
    var detail: SessionDetail
    var runtime: AppRuntime

    @State private var draft: String = ""
    @State private var isDirty = false
    @FocusState private var textFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if detail.session.state == .failed {
                    recoveryNotice
                }

                TextEditor(text: $draft)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .focused($textFocused)
                    .frame(minHeight: 120)
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.card, style: .continuous)
                            .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                    )
                    .onChange(of: draft) { _, _ in isDirty = draft != detail.transcript }

                provenance
            }
            .padding(20)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .task(id: detail.session.id) {
            draft = detail.transcript
            isDirty = false
        }
    }

    /// Actions live in a bar attached to the content rather than a system toolbar,
    /// so the window can keep one continuous surface under a transparent titlebar.
    private var actionBar: some View {
        HStack(spacing: 8) {
            if isDirty {
                Button("Save") { save() }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                    .controlSize(.small)
            }

            ConfirmingButton(
                title: "Insert",
                systemImage: "text.insert",
                confirmation: "Inserted"
            ) { runtime.insertAgain(draft) }
                .help("Put this text back into the app you were using")

            ConfirmingButton(
                title: "Copy",
                systemImage: "doc.on.doc",
                confirmation: "Copied"
            ) { runtime.copy(draft, note: "Copied.") }

            if detail.session.state == .failed || detail.session.state == .interrupted {
                Button {
                    runtime.retrySession(id: detail.session.id)
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            Spacer()

            Button(role: .destructive) {
                runtime.deleteSession(id: detail.session.id)
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Delete this dictation")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// A failed dictation's audio is preserved for a day. Say what is safe and what
    /// the shortest continuation is, rather than reporting a generic error.
    private var recoveryNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("The recording is kept for 24 hours")
                    .font(.system(size: 12, weight: .semibold))
                if let message = detail.session.errorMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    private var provenance: some View {
        Card(title: "Details") {
            LabeledContent("Spoken") {
                Text(detail.session.startedAt.formatted(date: .abbreviated, time: .standard))
            }
            LabeledContent("Length") {
                Text(Clock.compact(detail.session.duration))
            }
            if let application = detail.session.sourceApplication {
                LabeledContent("Into") { Text(application) }
            }
            if let snapshot = ModelSnapshot.describe(detail.session.modelSnapshot) {
                LabeledContent("Model") { Text(snapshot) }
            }
            if detail.segments.first.map({ $0.originalText != $0.editedText }) == true {
                LabeledContent("Original") {
                    Text(detail.segments.first?.originalText ?? "")
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func save() {
        guard let segment = detail.segments.first else { return }
        runtime.updateSegment(segment, text: draft, speaker: segment.speaker)
        isDirty = false
    }
}

/// Renders the stored transcription profile as something a human can read.
///
/// Every transcript keeps a snapshot of the settings that produced it, so changing
/// the dictation model later never rewrites the history of what was actually used.
enum ModelSnapshot {
    static func describe(_ json: String) -> String? {
        guard let profile = try? JSONDecoder().decode(TranscriptionProfile.self, from: Data(json.utf8)) else {
            return nil
        }
        let model = ModelDescriptor.curated.first { $0.id == profile.modelID }?.displayName ?? profile.modelID
        switch profile.language {
        case .automatic:
            return model
        case .fixed(let code):
            let language = Locale.current.localizedString(forLanguageCode: code) ?? code
            return "\(model) · \(language)"
        }
    }
}
