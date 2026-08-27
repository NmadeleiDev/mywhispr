import Foundation
import Observation
import OSLog

/// The conversation about one meeting.
///
/// Owned by ``AppRuntime`` the way playback and the HUD are: it holds state that
/// belongs to a meeting rather than to a view, so switching to another meeting and
/// back finds the conversation where it was left, and closing the window does not
/// throw away an answer that took a minute to write.
@MainActor
@Observable
final class MeetingChatController {
    private(set) var sessionID: UUID?
    private(set) var messages: [ChatMessageRecord] = []
    /// The answer being written right now, as far as it has got.
    private(set) var streamingAnswer: String?
    /// The request is out but nothing has come back yet. On a long meeting this is
    /// the model reading the transcript, which can take a while and looks like
    /// nothing happening unless it is said.
    private(set) var isReading = false
    private(set) var errorMessage: String?
    /// Size of the transcript the model is given, in tokens, so the interface can
    /// say when it will not fit rather than letting the server quietly drop half of it.
    private(set) var transcriptTokens = 0

    var draft = ""

    private weak var runtime: AppRuntime?
    private var transcript = ""
    private var task: Task<Void, Never>?
    /// Bumped whenever an in-flight answer is abandoned rather than stopped, so a
    /// task that is still unwinding cannot write its leftovers over the one that
    /// replaced it.
    private var generation = 0
    /// Fragments arrive at whatever rate the model writes, which on a fast local
    /// model is a hundred a second. Republishing that often rebuilds the rendered
    /// Markdown and re-runs the scroll for every token; the answer is no more
    /// readable for it. They are gathered and published on a short beat instead,
    /// with a trailing flush so the last words are never left waiting.
    private var pending = ""
    private var flush: Task<Void, Never>?
    private static let publishInterval: Duration = .milliseconds(60)
    private let logger = Logger(subsystem: "app.mywhispr.mac", category: "meeting-chat")

    func attach(runtime: AppRuntime) {
        self.runtime = runtime
    }

    // MARK: - Derived state

    var isBusy: Bool { task != nil }

    var canSend: Bool {
        !isBusy && sessionID != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEmpty: Bool { messages.isEmpty && streamingAnswer == nil }

    /// A question was asked and never answered — the app was quit mid-answer, or the
    /// server refused. The question is still there; only the answer is missing.
    var hasUnansweredQuestion: Bool {
        !isBusy && messages.last?.role == .user
    }

    /// What the model is about to be sent, so both the size warning and the request
    /// itself are derived from exactly the same thing.
    private var prompt: [LocalAIMessage] {
        guard let runtime else { return [] }
        return MeetingChatPrompt.messages(
            instruction: runtime.settings.payload.localAI.chatPrompt,
            transcript: transcript,
            history: messages.map { LocalAIMessage(role: $0.role, content: $0.content) }
        )
    }

    /// What the whole conversation costs, measured without concatenating it.
    ///
    /// `prompt` builds a string the size of the meeting; this is read on every
    /// redraw, so it adds up the same parts instead of joining them.
    private var estimatedTokens: Int {
        guard let runtime else { return 0 }
        let instruction = TokenBudget.estimate(runtime.settings.payload.localAI.chatPrompt)
        let history = messages.reduce(0) { $0 + TokenBudget.estimate($1.content) + TokenBudget.messageOverhead }
        return transcriptTokens + instruction + history + MeetingChatPrompt.framingTokens
    }

    /// Set when this meeting is too long for the window the model will get.
    ///
    /// Stated rather than silently tolerated: the failure mode is not an error but a
    /// confident answer drawn from part of the meeting, which is indistinguishable
    /// from a correct one until it matters.
    var contextWarning: String? {
        guard let runtime, sessionID != nil, transcriptTokens > 0 else { return nil }
        let configuration = runtime.settings.payload.localAI
        let size = TokenBudget.describe(transcriptTokens)
        switch configuration.provider {
        case .ollama:
            guard estimatedTokens + TokenBudget.answerReserve > configuration.maxContextTokens else { return nil }
            return """
            This meeting is about \(size) tokens, more than the \
            \(TokenBudget.describe(configuration.maxContextTokens)) context limit. The model will \
            only see part of it. Raise the limit in Settings ▸ Local AI.
            """
        case .openAICompatible:
            // Nothing in this protocol carries a context size, so the server answers
            // with whatever window it loaded the model with. All that can honestly be
            // done is name the number the owner needs to have configured there.
            guard transcriptTokens > 6_000 else { return nil }
            return """
            This meeting is about \(size) tokens. Make sure the model is loaded with a \
            context window at least that large, or it will only see part of the meeting.
            """
        }
    }

    // MARK: - Lifecycle

    /// Points the conversation at whichever session is now selected.
    func load(_ detail: SessionDetail?) {
        guard let detail, detail.session.kind == .meeting else {
            reset()
            return
        }
        if detail.session.id != sessionID {
            cancel()
            draft = ""
            errorMessage = nil
            streamingAnswer = nil
            sessionID = detail.session.id
            messages = (try? runtime?.database.chatMessages(for: detail.session.id)) ?? []
        }
        // The transcript is re-read even mid-answer, because editing a passage while
        // reading the answer is a reasonable thing to do and the next question should
        // see the correction.
        transcript = detail.annotatedTranscript
        transcriptTokens = TokenBudget.estimate(transcript)
    }

    func reset() {
        cancel()
        sessionID = nil
        messages = []
        transcript = ""
        transcriptTokens = 0
        streamingAnswer = nil
        errorMessage = nil
        draft = ""
    }

    // MARK: - Asking

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        ask(question)
    }

    func send(_ question: String) {
        draft = ""
        ask(question)
    }

    /// Answers the question already at the end of the conversation.
    func retry() {
        guard hasUnansweredQuestion else { return }
        ask(nil)
    }

    /// Stops the answer, keeping whatever was written.
    ///
    /// A half-written answer is usually enough — that is why the owner stopped — and
    /// discarding it would make Stop indistinguishable from Cancel.
    func stop() {
        task?.cancel()
    }

    func clear() {
        guard let sessionID, let runtime else { return }
        cancel()
        do {
            try runtime.database.deleteChatMessages(for: sessionID)
            messages = []
            streamingAnswer = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func ask(_ question: String?) {
        guard let runtime, let sessionID, task == nil else { return }
        errorMessage = nil
        streamingAnswer = nil
        pending = ""

        if let question {
            let record = ChatMessageRecord(
                id: UUID(),
                sessionID: sessionID,
                position: (messages.last?.position ?? -1) + 1,
                role: .user,
                content: question,
                createdAt: Date()
            )
            do {
                try runtime.database.appendChatMessage(record)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            messages.append(record)
        }

        let configuration = runtime.settings.payload.localAI
        let request = prompt
        let contextTokens = TokenBudget.context(for: request, limit: configuration.maxContextTokens)
        let service = runtime.localAI
        let generation = generation

        isReading = true
        task = Task { [weak self] in
            do {
                try await service.answer(
                    request,
                    contextTokens: contextTokens,
                    configuration: configuration,
                    onDelta: { delta in
                        // Awaited, so fragments land in the order the model wrote them.
                        await MainActor.run { self?.receive(delta, generation: generation) }
                    }
                )
                await MainActor.run { self?.finish(generation, for: sessionID, stopped: false) }
            } catch is CancellationError {
                await MainActor.run { self?.finish(generation, for: sessionID, stopped: true) }
            } catch {
                await MainActor.run { self?.finish(generation, for: sessionID, stopped: false, error: error) }
            }
        }
    }

    private func receive(_ delta: String, generation: Int) {
        guard generation == self.generation else { return }
        isReading = false
        pending += delta
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: Self.publishInterval)
            guard let self else { return }
            self.flush = nil
            self.publish()
        }
    }

    private func publish() {
        guard !pending.isEmpty else { return }
        streamingAnswer = (streamingAnswer ?? "") + pending
        pending = ""
    }

    private func finish(_ generation: Int, for sessionID: UUID, stopped: Bool, error: (any Error)? = nil) {
        guard generation == self.generation else { return }
        task = nil
        isReading = false
        flush?.cancel()
        flush = nil
        publish()
        let answer = (streamingAnswer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        streamingAnswer = nil

        // The selection may have moved on while the model was writing. The answer
        // still belongs to the meeting it was asked about, so it is stored there
        // rather than shown against whatever is on screen now.
        if !answer.isEmpty {
            store(answer, for: sessionID)
        }

        if let error {
            // A cancelled URL request is the Stop button arriving by another route.
            let urlCancelled = (error as? URLError)?.code == .cancelled
            if !urlCancelled {
                errorMessage = error.localizedDescription
                logger.error("Meeting question failed: \(error.localizedDescription)")
            }
        } else if answer.isEmpty, !stopped {
            errorMessage = LocalAIError.emptyAnswer.localizedDescription
        }
    }

    private func store(_ answer: String, for sessionID: UUID) {
        guard let runtime else { return }
        let position: Int
        if sessionID == self.sessionID {
            position = (messages.last?.position ?? -1) + 1
        } else {
            position = ((try? runtime.database.chatMessages(for: sessionID))?.last?.position ?? -1) + 1
        }
        let record = ChatMessageRecord(
            id: UUID(),
            sessionID: sessionID,
            position: position,
            role: .assistant,
            content: answer,
            createdAt: Date()
        )
        do {
            try runtime.database.appendChatMessage(record)
            if sessionID == self.sessionID { messages.append(record) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        flush?.cancel()
        flush = nil
        pending = ""
        isReading = false
    }
}
