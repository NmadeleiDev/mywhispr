import SwiftUI

struct LocalAISettings: View {
    @Bindable var runtime: AppRuntime

    var body: some View {
        @Bindable var settings = runtime.settings
        let source = runtime.localModelSource
        let catalog = runtime.localModelCatalog.state(for: source)

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
                            settings.payload.localAI.embeddingModel = ""
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
                    switch catalog {
                    case .notLoaded, .loading:
                        StatusPill(tone: .working, label: "Checking…")
                    case .available(let models):
                        StatusPill(
                            tone: models.isEmpty ? .bad : .good,
                            label: models.isEmpty
                                ? "No chat models available"
                                : (models.count == 1 ? "1 model available" : "\(models.count) models available")
                        )
                        Button { runtime.discoverLocalModels() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Refresh models")
                    case .failed(let message):
                        StatusPill(tone: .bad, label: message)
                        Button("Try again") { runtime.discoverLocalModels() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    Spacer()
                }
            }

            Card(title: "Models") {
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
                SettingRow(
                    label: "Search meetings with",
                    detail: "Adds multilingual semantic search to exact transcript matching. Embeddings stay in MyWhispr's local database."
                ) {
                    embeddingModelPicker(selection: $settings.payload.localAI.embeddingModel)
                }
                if !settings.payload.localAI.embeddingModel.isEmpty {
                    HStack {
                        semanticIndexStatus
                        Spacer()
                    }
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

            Card(title: "Summary instruction") {
                TextEditor(text: $settings.payload.localAI.summaryPrompt)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 90)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    Spacer()
                    Button("Restore default") {
                        settings.payload.localAI.summaryPrompt = LocalAIConfiguration.defaultSummaryPrompt
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
        .task(id: source) {
            // Address edits are persisted as they are typed. Let SwiftUI cancel
            // superseded values so only the settled connection is queried.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            runtime.discoverLocalModels()
        }
    }

    @ViewBuilder
    private func modelPicker(selection: Binding<String>, allowsInherit: Bool) -> some View {
        let source = runtime.localModelSource
        let models = runtime.localModelCatalog.models(for: source)
        Picker("", selection: selection) {
            if allowsInherit {
                Text("Same as rewrite").tag("")
            } else {
                Text("None").tag("")
            }
            if !models.isEmpty {
                Divider()
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            if !selection.wrappedValue.isEmpty,
               runtime.localModelCatalog.confirmsMissing(selection.wrappedValue, from: source) {
                Divider()
                Text("\(selection.wrappedValue) (not found)").tag(selection.wrappedValue)
            } else if !selection.wrappedValue.isEmpty, !models.contains(selection.wrappedValue) {
                Divider()
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }

    private func embeddingModelPicker(selection: Binding<String>) -> some View {
        let source = runtime.localModelSource
        let models = runtime.settings.payload.localAI.provider == .ollama
            ? runtime.localEmbeddingModels
            : runtime.localModelCatalog.models(for: source)
        return Picker("", selection: selection) {
            Text("Exact text only").tag("")
            if !models.isEmpty {
                Divider()
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            if !selection.wrappedValue.isEmpty,
               !models.contains(selection.wrappedValue) {
                Divider()
                Text("\(selection.wrappedValue) (not found)").tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }

    @ViewBuilder
    private var semanticIndexStatus: some View {
        switch runtime.meetingSemanticIndexState {
        case .idle:
            StatusPill(tone: .unknown, label: "Search index waiting")
        case .indexing(let completed, let total):
            StatusPill(tone: .working, label: "Indexing \(completed) of \(total) passages")
        case .ready(let count):
            StatusPill(tone: .good, label: "\(count) passages ready")
        case .failed(let message):
            StatusPill(tone: .bad, label: message)
        }
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
