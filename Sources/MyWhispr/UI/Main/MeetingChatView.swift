import SwiftUI

/// Questions about a meeting, and the answers.
///
/// A conversation, not a search box: the answer to "what did we decide" is usually
/// followed by "who disagreed", and that second question only means anything if the
/// first one is still on screen.
struct MeetingChatView: View {
    var chat: MeetingChatController
    var runtime: AppRuntime

    private static let bottomAnchor = "chat-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat.isEmpty && chat.errorMessage == nil {
                        opening
                    }

                    ForEach(chat.messages) { message in
                        turn(message)
                            .id(message.id)
                    }

                    if let answer = chat.streamingAnswer {
                        answerBubble(answer, isWriting: true)
                    } else if chat.isReading {
                        reading
                    }

                    if let error = chat.errorMessage {
                        failure(error)
                    } else if chat.hasUnansweredQuestion {
                        unanswered
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onChange(of: chat.messages.count) { _, _ in scrollToEnd(proxy, animated: true) }
            .onChange(of: chat.isReading) { _, _ in scrollToEnd(proxy, animated: true) }
            // Not animated: an answer being written moves the anchor several times a
            // second, and animating each move fights the one before it.
            .onChange(of: chat.streamingAnswer) { _, _ in scrollToEnd(proxy, animated: false) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        guard animated else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            return
        }
        withAnimation(.smooth(duration: 0.25)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Turns

    @ViewBuilder
    private func turn(_ message: ChatMessageRecord) -> some View {
        switch message.role {
        case .user:
            question(message.content)
        case .assistant, .system:
            answerBubble(message.content, isWriting: false)
        }
    }

    /// The owner's own words, set apart the way their speech is in the transcript.
    private func question(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Palette.accent.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: Metrics.card, style: .continuous)
                )
        }
    }

    private func answerBubble(_ text: String, isWriting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The same renderer the summary uses: a model asked for Markdown writes
            // Markdown, and raw asterisks in an answer are as unreadable here as there.
            MarkdownText(markdown: text)
                .textSelection(.enabled)

            if isWriting {
                WritingIndicator()
            } else {
                ConfirmingButton(
                    title: "Copy",
                    systemImage: "doc.on.doc",
                    confirmation: "Copied"
                ) { runtime.copy(text, note: "Answer copied.") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - States

    /// Shown before the first question. Three openers, because the useful thing to
    /// convey is what kind of question this answers — not to supply a menu that the
    /// owner picks from instead of asking what they actually want to know.
    private var opening: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about this meeting")
                .font(.system(size: 14, weight: .semibold))
            Text("\(runtime.summaryModelName) reads the whole transcript on this Mac and answers from it. Nothing is sent anywhere else.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FlowRow(spacing: 8) {
                ForEach(MeetingChatPrompt.suggestions, id: \.self) { suggestion in
                    Button {
                        chat.send(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(chat.isBusy || !runtime.canAskLocalAI)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading the meeting…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func failure(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.danger)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if chat.hasUnansweredQuestion {
                    Button("Ask again") { chat.retry() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.card, style: .continuous))
    }

    /// A question with no answer under it — the app was quit while the model was
    /// writing. The question survived; offering to run it again is cheaper than
    /// asking the owner to remember what they typed.
    private var unanswered: some View {
        HStack(spacing: 10) {
            Text("This question was never answered.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Ask again") { chat.retry() }
                .buttonStyle(.glass)
                .controlSize(.small)
            Spacer(minLength: 0)
        }
    }
}

/// The caret that says an answer is still being written.
private struct WritingIndicator: View {
    @State private var on = false

    var body: some View {
        Rectangle()
            .fill(Palette.accent)
            .frame(width: 7, height: 13)
            .opacity(on ? 1 : 0.15)
            .task {
                // A repeating animation rather than a spinner: the answer is already
                // arriving, and a spinner would say it had not started.
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

/// The composer, pinned below the conversation.
struct MeetingChatComposer: View {
    @Bindable var chat: MeetingChatController
    var runtime: AppRuntime

    @FocusState private var focused: Bool
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 8) {
            if !runtime.canAskLocalAI {
                notice(
                    "Connect a local AI service in Settings to ask questions about a meeting.",
                    tone: .secondary
                )
            } else if let warning = chat.contextWarning {
                notice(warning, tone: .warning)
            }

            HStack(spacing: 8) {
                if !chat.isEmpty {
                    Button {
                        confirmingClear = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Clear this conversation")
                }

                TextField("Ask about this meeting", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($focused)
                    .disabled(!runtime.canAskLocalAI)
                    .onSubmit { chat.send() }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                focused ? Palette.accent.opacity(0.6) : Color(nsColor: .separatorColor),
                                lineWidth: focused ? 1.5 : 0.5
                            )
                    )
                    .animation(.smooth(duration: 0.15), value: focused)

                if chat.isBusy {
                    Button {
                        chat.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.iconOnly)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Stop writing and keep what has been said so far")
                } else {
                    Button {
                        chat.send()
                    } label: {
                        Label("Ask", systemImage: "arrow.up")
                            .labelStyle(.iconOnly)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                    .controlSize(.small)
                    .disabled(!chat.canSend || !runtime.canAskLocalAI)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("Ask this question")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear conversation", role: .destructive) { chat.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The questions and answers are removed. The transcript, the summary, and the recording are untouched.")
        }
    }

    private enum Tone { case secondary, warning }

    private func notice(_ message: String, tone: Tone) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone == .warning ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Lays children left to right, wrapping onto a new line when the width runs out.
///
/// `HStack` would push the suggestions off the edge of a narrow window, and a `Grid`
/// would space them by the widest one. These are sentences of different lengths that
/// should sit next to each other and wrap like words.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
