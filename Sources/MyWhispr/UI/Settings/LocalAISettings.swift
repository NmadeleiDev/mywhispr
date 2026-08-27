import SwiftUI

struct LocalAISettings: View {
    @Bindable var runtime: AppRuntime

    var body: some View {
        @Bindable var settings = runtime.settings

        SettingsPane {
            Card(
                title: "Connection",
                footnote: "MyWhispr never transcribes through this service. It only sends a finished transcript and your instruction, and only when you have turned rewriting on, asked for a summary, or asked a question about a meeting."
            ) {
                SettingRow(label: "Service") {
                    Picker("", selection: Binding(
                        get: { settings.payload.localAI.provider },
                        set: { provider in
                            settings.payload.localAI.provider = provider
                            settings.payload.localAI.baseURL = provider.defaultBaseURL
                            settings.payload.localAI.model = ""
                            settings.payload.localAI.summaryModel = ""
                        }
                    )) {
                        ForEach(LocalAIConfiguration.Provider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 190)
                }

                SettingRow(label: "Address") {
                    TextField("", text: $settings.payload.localAI.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 240)
                }

                SettingRow(
                    label: "Allow an address on my network",
                    detail: "Off means only this Mac. Turning this on lets transcripts leave this machine."
                ) {
                    Toggle("", isOn: $settings.payload.localAI.allowLAN)
                }

                HStack(spacing: 10) {
                    Button("Test connection") { runtime.discoverLocalModels() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    switch runtime.localAIStatus {
                    case .idle:
                        EmptyView()
                    case .checking:
                        StatusPill(tone: .working, label: "Checking…")
                    case .connected(let count):
                        StatusPill(tone: .good, label: count == 1 ? "1 model available" : "\(count) models available")
                    case .failed(let message):
                        StatusPill(tone: .bad, label: message)
                    }
                    Spacer()
                }
            }

            Card(
                title: "Models",
                footnote: runtime.localModels.isEmpty
                    ? "Test the connection to discover what this service is serving."
                    : nil
            ) {
                SettingRow(
                    label: "Rewrite dictation with",
                    detail: "Runs in the gap before text appears, so prefer a small fast model."
                ) {
                    modelPicker(selection: $settings.payload.localAI.model, allowsInherit: false)
                }
                SettingRow(
                    label: "Summarize and answer with",
                    detail: "Used for meeting summaries and for questions about a meeting. Runs only when you ask, so a slower, stronger model is fine."
                ) {
                    modelPicker(selection: $settings.payload.localAI.summaryModel, allowsInherit: true)
                }
            }

            Card(
                title: "Reading a whole meeting",
                footnote: "A question about a meeting is answered from the entire transcript, so the model has to be able to hold it. Roughly: 8K is half an hour of speech, 32K is two hours. A larger window costs memory while the model is loaded, and a window too small for the meeting is filled from the end — the model answers about the part it saw without saying so.\n\nOllama is told this per request. An OpenAI-compatible server sets its own window when it loads a model, so this is only used to warn you when a meeting will not fit."
            ) {
                SettingRow(
                    label: "Context limit",
                    detail: "The largest window MyWhispr will ask for."
                ) {
                    Picker("", selection: $settings.payload.localAI.maxContextTokens) {
                        ForEach(LocalAIConfiguration.contextChoices, id: \.self) { limit in
                            Text(TokenBudget.describe(limit)).tag(limit)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                }
            }

            Card(title: "Question instruction") {
                TextEditor(text: $settings.payload.localAI.chatPrompt)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 110)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    Spacer()
                    Button("Restore default") {
                        settings.payload.localAI.chatPrompt = LocalAIConfiguration.defaultChatPrompt
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            Card(title: "Rewrite instruction") {
                TextEditor(text: $settings.payload.localAI.rewritePrompt)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 90)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    Spacer()
                    Button("Restore default") {
                        settings.payload.localAI.rewritePrompt = LocalAIConfiguration().rewritePrompt
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func modelPicker(selection: Binding<String>, allowsInherit: Bool) -> some View {
        Picker("", selection: selection) {
            if allowsInherit {
                Text("Same as rewrite").tag("")
            } else {
                Text("None").tag("")
            }
            if !runtime.localModels.isEmpty {
                Divider()
                ForEach(runtime.localModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            // A model chosen before the service went away must stay visible, or the
            // picker would silently appear to reset the owner's choice.
            if !selection.wrappedValue.isEmpty, !runtime.localModels.contains(selection.wrappedValue) {
                Divider()
                Text("\(selection.wrappedValue) (not found)").tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }
}

struct PrivacySettings: View {
    @Bindable var runtime: AppRuntime
    @State private var confirmingClear = false

    var body: some View {
        SettingsPane {
            Card(
                title: "Where things are kept",
                footnote: runtime.storageLocation
            ) {
                SettingRow(label: "Meeting recordings") {
                    Text(ByteFormat.string(runtime.meetingAudioBytes))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                SettingRow(label: "Downloaded speech models") {
                    Text(ByteFormat.string(runtime.models.totalBytes))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                SettingRow(label: "Transcripts and history") {
                    Text(ByteFormat.string(runtime.databaseBytes))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Show in Finder") { runtime.revealStorageInFinder() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Spacer()
                }
            }

            Card(
                title: "What leaves this Mac",
                footnote: "Speech is transcribed entirely on this Mac. There is no account, no sync, and no analytics. The only outbound connections MyWhispr can make are model downloads you start, and requests to the local AI address you configured."
            ) {
                SettingRow(label: "Speech transcription") {
                    StatusPill(tone: .good, label: "On this Mac")
                }
                SettingRow(label: "Rewrites, summaries, and questions") {
                    StatusPill(
                        tone: runtime.settings.payload.localAI.allowLAN ? .unknown : .good,
                        label: runtime.settings.payload.localAI.allowLAN
                            ? "Your configured address"
                            : "This Mac only"
                    )
                }
            }

            Card(
                title: "Erase",
                footnote: "Removes every dictation, meeting, transcript, summary, and recording. Downloaded speech models are kept — remove those in Models."
            ) {
                HStack {
                    Button("Delete everything…", role: .destructive) { confirmingClear = true }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Spacer()
                }
            }
        }
        .confirmationDialog(
            "Delete every dictation and meeting?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { runtime.eraseAllContent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transcripts, summaries, and both audio tracks of every meeting are removed from this Mac. This cannot be undone.")
        }
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        return ByteCountFormatStyle(style: .file).format(bytes)
    }
}
