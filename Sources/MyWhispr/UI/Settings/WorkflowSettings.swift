import SwiftUI

/// A model chooser scoped to one workflow.
///
/// It lists only models that suit this job, which is what makes "choose separate
/// models for dictation and meetings" a real choice rather than a trap: the owner
/// cannot pick a model here that will disappoint them later, so compatibility never
/// has to be explained after a bad outcome.
struct ModelPicker: View {
    var kind: WorkflowKind
    @Binding var profile: TranscriptionProfile
    var library: ModelLibrary

    private var candidates: [ModelDescriptor] {
        ModelDescriptor.curated.filter { $0.recommendedFor.contains(kind) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(candidates) { descriptor in
                ModelRow(
                    descriptor: descriptor,
                    state: library.state(of: descriptor.id),
                    isSelected: profile.modelID == descriptor.id,
                    onSelect: {
                        profile.engine = descriptor.engine
                        profile.modelID = descriptor.id
                    },
                    onDownload: { library.download(descriptor) },
                    onCancel: { library.cancelDownload(descriptor.id) }
                )
            }
        }
    }
}

struct ModelRow: View {
    var descriptor: ModelDescriptor
    var state: ModelLibrary.State
    var isSelected: Bool
    var onSelect: () -> Void
    var onDownload: () -> Void
    var onCancel: () -> Void

    private var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    /// What is on disk once installed, and what it will cost until then.
    private var size: Int64 {
        if case .installed(let bytes) = state { return bytes }
        return descriptor.downloadBytes
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.quaternary))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(descriptor.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    // Always stated, installed or not. The size is part of choosing,
                    // and showing it only afterwards answers the question too late.
                    Text(ByteFormat.string(size))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .help(isInstalled ? "On this Mac" : "Download size")
                }
                Text(descriptor.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Palette.accent.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isSelected ? Palette.accent.opacity(0.35) : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: isSelected ? 1 : 0.5
                )
        )
        .contentShape(.rect)
        .onTapGesture {
            // Selecting a model that is not on disk is allowed: the download starts
            // and the choice is already recorded, so the owner is not made to
            // sequence two steps that mean one thing to them.
            onSelect()
            if case .absent = state { onDownload() }
        }
        .animation(.smooth(duration: 0.2), value: isSelected)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.affirm)
        case .absent:
            Button("Download", action: onDownload)
                .buttonStyle(.glass)
                .controlSize(.small)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 76)
                    .tint(Palette.accent)
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                Button("Retry", action: onDownload)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .help(message)
        }
    }
}

/// Language choice shared by both workflows.
struct LanguagePicker: View {
    @Binding var selection: LanguageSelection

    /// A short, opinionated list. The long tail is reachable through automatic
    /// detection, which is the default and is genuinely good on these models.
    private static let common: [(code: String, name: String)] = [
        ("en", "English"), ("ru", "Russian"), ("de", "German"), ("fr", "French"),
        ("es", "Spanish"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("pl", "Polish"), ("uk", "Ukrainian"), ("tr", "Turkish"), ("ja", "Japanese"),
        ("ko", "Korean"), ("zh", "Chinese"), ("ar", "Arabic"), ("hi", "Hindi"),
    ]

    var body: some View {
        Picker("", selection: Binding(
            get: {
                switch selection {
                case .automatic: "auto"
                case .fixed(let code): code
                }
            },
            set: { selection = $0 == "auto" ? .automatic : .fixed($0) }
        )) {
            Text("Detect automatically").tag("auto")
            Divider()
            ForEach(Self.common, id: \.code) { language in
                Text(language.name).tag(language.code)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }
}

struct DictationSettings: View {
    @Bindable var runtime: AppRuntime

    var body: some View {
        @Bindable var settings = runtime.settings

        SettingsPane {
            Card(
                title: "Speech model",
                footnote: "Dictation and meetings keep separate models. Changing this does not affect meetings or anything already transcribed."
            ) {
                ModelPicker(
                    kind: .dictation,
                    profile: $settings.payload.dictationProfile,
                    library: runtime.models
                )
            }

            Card(title: "Language") {
                SettingRow(label: "Spoken language") {
                    LanguagePicker(selection: $settings.payload.dictationProfile.language)
                }
            }

            Card(
                title: "Rewrite before inserting",
                footnote: settings.payload.localAI.rewriteEnabled
                    ? "If the model is slow or unavailable, the faithful transcript is inserted instead. Your words are never lost to a failed rewrite."
                    : "Off means what you said is what you get, word for word."
            ) {
                SettingRow(
                    label: "Clean up dictation with local AI",
                    detail: runtime.canUseLocalAI ? nil : "Connect a local AI service first."
                ) {
                    Toggle("", isOn: $settings.payload.localAI.rewriteEnabled)
                        .disabled(!runtime.canUseLocalAI)
                }
                if settings.payload.localAI.rewriteEnabled {
                    SettingRow(label: "Give up after") {
                        Stepper(value: $settings.payload.localAI.rewriteTimeoutSeconds, in: 1...30, step: 1) {
                            Text(String(format: "%.0fs", settings.payload.localAI.rewriteTimeoutSeconds))
                                .font(.system(size: 12, design: .rounded))
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }

            Card(
                title: "History",
                footnote: "Audio from a successful dictation is deleted immediately either way. This controls the text."
            ) {
                SettingRow(label: "Keep dictated text for") {
                    Picker("", selection: $settings.payload.historyRetention) {
                        ForEach(HistoryRetention.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }
        }
    }
}

struct MeetingSettings: View {
    @Bindable var runtime: AppRuntime

    var body: some View {
        @Bindable var settings = runtime.settings

        SettingsPane {
            Card(
                title: "Speech model",
                footnote: "Meetings are long and unattended, so accuracy usually matters more than speed here."
            ) {
                ModelPicker(
                    kind: .meeting,
                    profile: $settings.payload.meetingProfile,
                    library: runtime.models
                )
            }

            Card(title: "Language") {
                SettingRow(label: "Spoken language") {
                    LanguagePicker(selection: $settings.payload.meetingProfile.language)
                }
            }

            Card(
                title: "Recordings",
                footnote: settings.payload.meetingAudioRetention.explanation
            ) {
                SettingRow(label: "After transcribing") {
                    Picker("", selection: $settings.payload.meetingAudioRetention) {
                        ForEach(MeetingAudioRetention.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                SettingRow(label: "Space used by recordings") {
                    Text(ByteFormat.string(runtime.meetingAudioBytes))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Card(
                title: "Summaries",
                footnote: "Summaries are generated on demand, never automatically, and only by the local AI model you choose."
            ) {
                Text("Sent with the transcript to your local model.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextEditor(text: $settings.payload.localAI.summaryPrompt)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 80)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}
