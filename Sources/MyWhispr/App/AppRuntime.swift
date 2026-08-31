import AppKit
import Foundation
import Observation
import OSLog

/// One summary may use the local model at a time, and it belongs to exactly one
/// recording. Keeping the owner ID in the state prevents every meeting view from
/// interpreting global model activity as its own progress.
struct SummaryGenerationState: Equatable, Sendable {
    private(set) var sessionID: UUID?

    var isActive: Bool { sessionID != nil }

    func isGenerating(for sessionID: UUID) -> Bool {
        self.sessionID == sessionID
    }

    mutating func start(for sessionID: UUID) -> Bool {
        guard self.sessionID == nil else { return false }
        self.sessionID = sessionID
        return true
    }

    mutating func finish(for sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        self.sessionID = nil
    }
}

/// The application's single coordinator.
///
/// Every surface — HUD, menu bar, main window, palette — reads from here and calls
/// into here. Domain state lives on this object; how that state should *look* is
/// decided by the presenters it owns, which is why `HUDPresenter` exists rather than
/// this type storing "should the pill be collapsed".
@MainActor
@Observable
final class AppRuntime {
    // MARK: - Published state

    private(set) var phase: RecordingPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            hud.update(phase: phase, enabled: settings.payload.showHUD)
        }
    }

    private(set) var sessions: [SessionRecord] = []
    private(set) var recentDictations: [SessionRecord] = []
    private(set) var selectedDetail: SessionDetail?
    private(set) var localModels: [String] = []
    private(set) var localAIStatus: LocalAIStatus = .idle
    private(set) var summaryGeneration = SummaryGenerationState()
    private(set) var shortcutConflicts: Set<GlobalHotkeyCenter.Action> = []

    /// Whether the dictation key is actually being watched right now.
    ///
    /// This is not the same question as "is Input Monitoring granted". macOS decides
    /// Input Monitoring per process at launch, so a process that started before the
    /// permission was given still cannot build an event tap — every permission reads
    /// as allowed while dictation silently does nothing. Tracking the tap itself is
    /// what lets the app notice that and offer the restart that fixes it.
    private(set) var isDictationListening = false
    private(set) var meetingAudioBytes: Int64 = 0
    private(set) var databaseBytes: Int64 = 0

    /// Incremented once a second while a meeting records. Views that show elapsed
    /// time observe this; without it nothing would republish, because the elapsed
    /// value is derived from a start date that never changes.
    private(set) var meetingTick = 0

    /// Set every time text is successfully placed somewhere. The setup window
    /// watches it to know the owner's first dictation actually landed.
    private(set) var lastInsertedText: String?

    var selectedSessionID: UUID? {
        didSet {
            guard selectedSessionID != oldValue else { return }
            loadSelectedDetail()
        }
    }

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            reloadSessions()
        }
    }

    var filter: WorkflowKind = .dictation {
        didSet {
            guard filter != oldValue else { return }
            selectedSessionID = nil
            reloadSessions()
        }
    }

    var bannerMessage: String?

    enum LocalAIStatus: Equatable {
        case idle
        case checking
        case connected(models: Int)
        case failed(String)
    }

    // MARK: - Collaborators

    let settings: SettingsStore
    let permissions: PermissionCenter
    let database: AppDatabase
    let playback = MeetingPlaybackController()
    let meter = AudioLevelMeter()
    let hud = HUDPresenter()
    let quickPaste = QuickPastePresenter()
    let chat = MeetingChatController()
    let models: ModelLibrary

    private let transcription = TranscriptionService()
    private let diarization = DiarizationService()
    /// Shared with ``MeetingChatController``: one place that knows how to reach the
    /// owner's model server, whatever is being asked of it.
    let localAI = LocalAIService()
    private let microphone = MicrophoneRecorder()
    private let meetingRecorder = MeetingRecorder()
    private let hotkey = HotkeyMonitor()
    private let hotkeys = GlobalHotkeyCenter()
    private let textInserter = TextInserter()
    private let logger = Logger(subsystem: "app.mywhispr.mac", category: "runtime")

    private var dictationTarget: FocusedTextTarget?
    private var activeMeeting: SessionRecord?
    private var meetingStartedAt: Date?
    private var currentlyProcessingMeetingID: UUID?
    private var dictationSafetyTask: Task<Void, Never>?
    /// Deadline on the gap between "the key went down" and "audio is recording".
    private var dictationStartWatchdog: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    /// The in-flight transcribe/rewrite/insert chain, so it can be abandoned.
    private var processingTask: Task<Void, Never>?
    private var elapsedTicker: Task<Void, Never>?
    private var levelTicker: Task<Void, Never>?

    /// Window control, installed at startup so the runtime can open and close
    /// windows from a Carbon hotkey callback or the app delegate, neither of which
    /// has a SwiftUI environment to read.
    var openWindowHandler: ((String) -> Void)?
    var closeWindowHandler: ((String) -> Void)?

    init() throws {
        settings = SettingsStore()
        permissions = PermissionCenter()
        database = try AppDatabase()
        models = ModelLibrary(transcription: transcription)


        hud.attach(runtime: self)
        quickPaste.attach(runtime: self)
        chat.attach(runtime: self)
        // The event tap can only be created once Input Monitoring is allowed, so it
        // is built the moment that happens rather than at the next launch.
        permissions.onGranted = { [weak self] in self?.configureHotkeys() }

        try database.markInterruptedRecordings()
        reloadSessions()
        applyRetentionPolicies()
        refreshStorageSizes()
    }

    func start() {
        permissions.refresh()
        settings.refreshLaunchAtLoginStatus()
        configureHotkeys()
        applyActivationPolicy()
    }

    /// Re-applies every setting that has an effect outside its own stored value.
    ///
    /// Settings changes must take hold the moment they are made — a rebound shortcut
    /// that only works after a relaunch is a bug, not a limitation — so the settings
    /// surface calls this whenever the payload changes.
    func applySettings(previous: SettingsStore.Payload) {
        let payload = settings.payload

        if payload.showDockIcon != previous.showDockIcon {
            applyActivationPolicy()
        }
        if payload.showHUD != previous.showHUD {
            hud.update(phase: phase, enabled: payload.showHUD)
        }
        if payload.pushToTalkKey != previous.pushToTalkKey
            || payload.pushToTalkEnabled != previous.pushToTalkEnabled
            || payload.meetingShortcut != previous.meetingShortcut
            || payload.quickPasteShortcut != previous.quickPasteShortcut
            || payload.openWindowShortcut != previous.openWindowShortcut
            || payload.quickPasteEnabled != previous.quickPasteEnabled {
            configureHotkeys()
        }
        if payload.historyRetention != previous.historyRetention {
            applyRetentionPolicies()
            reloadSessions()
            refreshStorageSizes()
        }
        if payload.localAI.provider != previous.localAI.provider
            || payload.localAI.baseURL != previous.localAI.baseURL {
            localModels = []
            localAIStatus = .idle
        }
    }

    /// Quits and reopens MyWhispr.
    ///
    /// macOS grants Input Monitoring to a *process*, and an already-running process
    /// keeps the answer it got at launch: `CGEvent.tapCreate` will keep failing until
    /// the app starts again. Rather than leave the owner to work that out, or tell
    /// them to quit and reopen by hand, the app restarts itself.
    func relaunch() {
        prepareForTermination()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.bannerMessage = "MyWhispr could not restart: \(error.localizedDescription)"
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Finalises anything in flight before the process goes away.
    func prepareForTermination() {
        if isMeetingActive { stopMeeting() }
        if case .recording(.dictation, _) = phase { cancelDictation() }
        if case .preparing(.dictation) = phase { cancelDictation() }
    }

    // MARK: - Derived state used by the interface

    var isCapturing: Bool {
        switch phase {
        case .recording, .preparing: true
        default: false
        }
    }

    var isWorking: Bool {
        switch phase {
        case .preparingModel, .transcribing, .rewriting, .inserting, .stopping: true
        default: false
        }
    }

    var isMeetingActive: Bool { activeMeeting != nil }

    /// Every permission is allowed, yet the dictation key is not being watched. The
    /// only remedy is relaunching, so this is what the setup window offers.
    var needsRestartToListen: Bool {
        permissions.dictationReady && settings.payload.pushToTalkEnabled && !isDictationListening
    }

    var canStartMeeting: Bool {
        activeMeeting == nil && phase == .idle && permissions.microphone == .granted
    }

    var meetingElapsed: TimeInterval {
        // Reading the tick is what registers this as a dependency for observers.
        _ = meetingTick
        guard let meetingStartedAt else { return 0 }
        return Date().timeIntervalSince(meetingStartedAt)
    }

    var meetingProgress: Double? {
        switch phase {
        case .transcribing(.meeting, let progress): progress
        // A model download has its own fraction, and it is not a fraction of the
        // meeting. The bar shows it, the label says which one it is.
        case .preparingModel(.meeting, _, let progress): progress
        default: nil
        }
    }

    var meetingStageDescription: String {
        switch phase {
        case .preparingModel(.meeting, let isDownloading, _):
            return isDownloading ? "Downloading the speech model" : "Loading the speech model"
        case .transcribing(.meeting, let progress):
            return progress < 0.7 ? "Turning speech into text" : "Telling the speakers apart"
        default:
            return "Processing"
        }
    }

    /// Rewriting dictation needs the rewrite model specifically.
    var canUseLocalAI: Bool { !settings.payload.localAI.model.isEmpty }

    /// Meeting work — summaries and questions — runs on the meeting model, which
    /// falls back to the rewrite model when only one has been chosen.
    var canAskLocalAI: Bool { !settings.payload.localAI.effectiveSummaryModel.isEmpty }

    var summaryModelName: String {
        let name = settings.payload.localAI.effectiveSummaryModel
        return name.isEmpty ? "your local model" : name
    }

    var storageLocation: String {
        database.rootURL.path(percentEncoded: false)
    }

    /// Which workflows currently point at a model, so the library can refuse to
    /// delete something in use and say which choice is blocking it.
    func assignment(of modelID: String) -> [WorkflowKind] {
        var result: [WorkflowKind] = []
        if settings.payload.dictationProfile.modelID == modelID { result.append(.dictation) }
        if settings.payload.meetingProfile.modelID == modelID { result.append(.meeting) }
        return result
    }

    // MARK: - Shortcuts

    func configureHotkeys() {
        hotkey.stop()
        isDictationListening = false
        if settings.payload.pushToTalkEnabled, permissions.canObserveKeyboard {
            do {
                try hotkey.start(key: settings.payload.pushToTalkKey) { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .pressed: self.startDictation()
                    case .released: self.finishDictation()
                    case .cancelledByChord: self.cancelDictation()
                    }
                }
                isDictationListening = true
            } catch {
                // Reaching here with the permission granted means this process
                // predates the grant. Only a restart fixes it.
                logger.notice("Event tap unavailable despite Input Monitoring being allowed.")
            }
        }

        hotkeys.start { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleMeeting: self.toggleMeeting()
            case .quickPaste: self.quickPaste.toggle()
            case .openMainWindow:
                self.openWindowHandler?(WindowID.main)
                NSApp.activate()
            }
        }
        var bindings: [GlobalHotkeyCenter.Action: ShortcutBinding] = [
            .toggleMeeting: settings.payload.meetingShortcut,
            .openMainWindow: settings.payload.openWindowShortcut,
        ]
        if settings.payload.quickPasteEnabled {
            bindings[.quickPaste] = settings.payload.quickPasteShortcut
        }
        hotkeys.apply(bindings)
        shortcutConflicts = hotkeys.conflicts
    }

    func resetShortcuts() {
        settings.resetShortcuts()
        configureHotkeys()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try settings.setLaunchAtLogin(enabled)
        } catch {
            bannerMessage = "Login item could not be changed: \(error.localizedDescription)"
        }
    }

    /// The Dock icon is optional; the menu bar is the permanent home.
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.payload.showDockIcon ? .regular : .accessory)
    }

    // MARK: - Dictation

    func startDictation() {
        guard phase == .idle else {
            if activeMeeting != nil {
                bannerMessage = "A meeting is recording, so the microphone is busy."
            }
            return
        }
        guard permissions.dictationReady else {
            bannerMessage = "Finish setup before dictating."
            return
        }
        phase = .preparing(.dictation)
        // `.preparing` is the one phase nothing else can leave on the app's behalf:
        // the key is already down, so no release is coming to close it, and the pill
        // it shows says "Listening" — which is a lie the moment starting fails. It
        // has failed here in practice, and not always by throwing: AVFAudio reports
        // an already-tapped input bus as an Objective-C exception, which unwinds past
        // every `catch` below and abandons this method between the two lines that
        // would have set the phase to something else. Hence a deadline rather than
        // trust in the paths out of here.
        armDictationStartWatchdog()
        dictationTarget = FocusedTargetCapture.capture()
        do {
            try microphone.start()
            dictationStartWatchdog?.cancel()
            dictationStartWatchdog = nil
            startLevelTicker(microphone.levels)
            phase = .recording(.dictation, startedAt: Date())
            playCue(named: "Tink")
            let ceiling = settings.payload.maximumDictationSeconds
            dictationSafetyTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ceiling))
                guard !Task.isCancelled else { return }
                self?.bannerMessage = "Dictation reached its time limit and was inserted."
                self?.finishDictation()
            }
        } catch {
            fail(error)
        }
    }

    func finishDictation() {
        // The key can come back up before capture is running — the owner tapped it,
        // or starting is taking a moment. There is no take to finish, but the phase
        // still has to be closed out, because the gesture that would have closed it
        // has already happened.
        if case .preparing(.dictation) = phase { return abandonDictationStart() }
        guard case .recording(.dictation, _) = phase else { return }
        dictationSafetyTask?.cancel()
        dictationSafetyTask = nil
        phase = .stopping(.dictation)
        stopLevelTicker()
        guard let captured = microphone.stop() else {
            phase = .idle
            return
        }
        playCue(named: "Pop")
        // A brush against the talk key is not a dictation. Discard it silently
        // rather than showing an error for something that was never intended.
        guard captured.duration >= settings.payload.minimumDictationSeconds else {
            try? FileManager.default.removeItem(at: captured.url)
            phase = .idle
            return
        }
        let target = dictationTarget
        dictationTarget = nil
        processingTask = Task { [weak self] in
            await self?.processDictation(captured, target: target)
        }
    }

    func cancelDictation() {
        if case .preparing(.dictation) = phase { return abandonDictationStart() }
        guard case .recording(.dictation, _) = phase else { return }
        dictationSafetyTask?.cancel()
        dictationSafetyTask = nil
        stopLevelTicker()
        microphone.cancel()
        dictationTarget = nil
        phase = .idle
    }

    /// Gives up on a dictation that never got as far as recording.
    ///
    /// Safe to call when there is nothing to give up on: the recorder tolerates a
    /// `cancel` it never started, and that tolerance is the point — this runs from a
    /// watchdog that cannot know how far the start actually got.
    private func abandonDictationStart() {
        dictationStartWatchdog?.cancel()
        dictationStartWatchdog = nil
        dictationSafetyTask?.cancel()
        dictationSafetyTask = nil
        stopLevelTicker()
        microphone.cancel()
        dictationTarget = nil
        phase = .idle
    }

    private func armDictationStartWatchdog() {
        dictationStartWatchdog?.cancel()
        dictationStartWatchdog = nil
        dictationStartWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.dictationStartDeadline)
            guard !Task.isCancelled, let self, case .preparing(.dictation) = self.phase else { return }
            self.logger.error("Dictation never reached recording; clearing the indicator.")
            self.abandonDictationStart()
            self.bannerMessage = "The microphone did not start. Try dictating again."
            self.hud.flashFailure("The microphone did not start")
        }
    }

    /// How long starting capture may take before the attempt is written off. Long
    /// enough for a Bluetooth input to wake up, short enough that a stuck pill is a
    /// blink rather than something to be quit out of.
    private static let dictationStartDeadline: Duration = .seconds(4)

    /// Strips the noises of speaking from a dictation, if the owner wants that.
    ///
    /// The engine's untouched output is still what gets stored as the segment's
    /// original text, so nothing said is actually lost — the detail view can show
    /// what was really heard.
    private func tidied(_ text: String) -> String {
        guard settings.payload.tidyDictation else { return text }
        return DisfluencyFilter.apply(to: text)
    }

    /// Turns an engine's stage report into the phase the HUD renders.
    ///
    /// `span` exists because a meeting runs three jobs back to back — two
    /// transcriptions and speaker separation — and the owner is watching one bar.
    /// Model preparation is deliberately *not* mapped into that span: it is not
    /// progress through the meeting, it is a prerequisite, and folding it in is what
    /// made a long download read as a stalled transcription.
    private func report(
        _ stage: TranscriptionStage,
        _ fraction: Double?,
        kind: WorkflowKind,
        span: ClosedRange<Double> = 0...1
    ) {
        switch stage {
        case .downloadingModel:
            phase = .preparingModel(kind, isDownloading: true, progress: fraction)
        case .loadingModel:
            phase = .preparingModel(kind, isDownloading: false, progress: fraction)
        case .running:
            let value = fraction ?? 0
            phase = .transcribing(kind, progress: span.lowerBound + value * (span.upperBound - span.lowerBound))
        }
    }

    private func processDictation(_ captured: CapturedAudio, target: FocusedTextTarget?) async {
        phase = .transcribing(.dictation, progress: 0)
        let profile = settings.payload.dictationProfile
        do {
            let result = try await transcription.transcribe(
                audioURL: captured.url,
                profile: profile,
                vocabulary: settings.payload.vocabulary,
                channel: .microphone
            ) { stage, fraction in
                Task { @MainActor [weak self] in
                    self?.report(stage, fraction, kind: .dictation)
                }
            }
            let faithful = TextCleaner.clean(tidied(result.text))
            var output = faithful
            if settings.payload.localAI.rewriteEnabled {
                phase = .rewriting
                do {
                    output = try await localAI.rewrite(faithful, configuration: settings.payload.localAI)
                } catch {
                    // A failed rewrite must never cost the owner their words.
                    logger.notice("Local rewrite skipped: \(error.localizedDescription)")
                    bannerMessage = "Rewrite was skipped — inserted what you actually said."
                }
            }
            try Task.checkCancellation()
            phase = .inserting
            let outcome = await textInserter.insert(output, into: target)
            try persistDictation(output, result: result, target: target, profile: profile, duration: captured.duration)
            try? FileManager.default.removeItem(at: captured.url)
            processingTask = nil
            phase = .idle
            lastInsertedText = output
            switch outcome {
            case .inserted:
                hud.flashInserted(wordCount: output.split(whereSeparator: \.isWhitespace).count)
            case .copiedBecauseTargetChanged:
                hud.flashCopied(reason: .targetChanged)
            case .copiedBecauseUnsupported:
                hud.flashCopied(reason: .unsupported)
            }
            reloadSessions()
        } catch is CancellationError {
            // The owner walked away from this take; its audio is temporary and goes
            // with it rather than accumulating as recoverable failures.
            try? FileManager.default.removeItem(at: captured.url)
            processingTask = nil
        } catch {
            guard !Task.isCancelled else { return }
            processingTask = nil
            let message = (error as? TranscriptionEngineError) == .noSpeech
                ? "No speech was heard."
                : error.localizedDescription
            if (error as? TranscriptionEngineError) == .noSpeech {
                // Nothing was said; there is nothing to recover and no failure to
                // report beyond a moment's acknowledgement.
                try? FileManager.default.removeItem(at: captured.url)
            } else {
                do {
                    try persistFailedDictation(
                        captured,
                        target: target,
                        profile: profile,
                        errorMessage: error.localizedDescription
                    )
                    reloadSessions()
                } catch {
                    logger.error("Could not preserve failed dictation: \(error.localizedDescription)")
                }
            }
            phase = .idle
            hud.flashFailure(message)
            logger.error("Dictation processing failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Meetings

    func toggleMeeting() {
        isMeetingActive ? stopMeeting() : startMeeting()
    }

    func startMeeting() {
        guard canStartMeeting else {
            if permissions.microphone != .granted {
                bannerMessage = "Allow microphone access before recording a meeting."
            }
            return
        }
        let id = UUID()
        let startedAt = Date()
        let relativePath = "Audio/\(id.uuidString)"
        let directoryURL = database.rootURL.appending(path: relativePath, directoryHint: .isDirectory)
        var record = SessionRecord(
            id: id,
            kind: .meeting,
            title: "Meeting · \(startedAt.formatted(date: .abbreviated, time: .shortened))",
            state: .recording,
            startedAt: startedAt,
            endedAt: nil,
            duration: 0,
            sourceApplication: nil,
            sourceBundleIdentifier: nil,
            modelSnapshot: encodedProfile(settings.payload.meetingProfile),
            audioRelativePath: relativePath,
            summary: nil,
            errorMessage: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        do {
            try database.insertSession(record)
            try meetingRecorder.start(directoryURL: directoryURL)
            startLevelTicker(meetingRecorder.levels)
            activeMeeting = record
            meetingStartedAt = startedAt
            phase = .recording(.meeting, startedAt: startedAt)
            playCue(named: "Tink")
            startElapsedTicker()
            reloadSessions()
        } catch {
            record.state = .failed
            record.errorMessage = error.localizedDescription
            record.updatedAt = Date()
            try? database.updateSession(record)
            fail(error)
        }
    }

    func stopMeeting() {
        guard var record = activeMeeting else { return }
        let files = meetingRecorder.stop()
        // The meeting leaves the recording state whatever the recorder returns.
        // Bailing out before this point on a failed teardown used to leave the app
        // believing a meeting was still running, with the shortcut that would stop it
        // now unable to — recoverable only by quitting.
        activeMeeting = nil
        meetingStartedAt = nil
        stopElapsedTicker()
        stopLevelTicker()
        record.endedAt = Date()
        record.updatedAt = Date()
        guard let files else {
            record.state = .failed
            record.errorMessage = "The recording stopped unexpectedly and could not be saved."
            try? database.updateSession(record)
            phase = .idle
            reloadSessions()
            hud.flashFailure(record.errorMessage ?? "The recording could not be saved")
            return
        }
        record.state = .processing
        record.duration = files.duration
        do {
            try database.updateSession(record)
        } catch {
            logger.error("Meeting update failed: \(error.localizedDescription)")
        }
        phase = .transcribing(.meeting, progress: 0)
        playCue(named: "Pop")
        reloadSessions()
        processingTask = Task { [weak self] in await self?.processMeeting(record: record, files: files) }
    }

    /// Transcribes one of a meeting's two tracks, tolerating an empty one.
    ///
    /// A digitally silent file is skipped before a model is even loaded — running a
    /// large speech model across an hour of nothing costs minutes and can only ever
    /// return nothing — and an engine that finds no speech in audible audio is
    /// likewise an empty result rather than an error that takes the meeting with it.
    private func transcribeTrack(
        at url: URL,
        channel: AudioChannel,
        profile: TranscriptionProfile,
        span: ClosedRange<Double>
    ) async throws -> TranscriptionResult {
        let empty = TranscriptionResult(text: "", detectedLanguage: nil, segments: [])
        let isSilent = await Task.detached(priority: .utility) { AudioProbe.isSilent(url) }.value
        guard !isSilent else {
            logger.notice("Meeting \(channel.rawValue) track held no signal; skipping transcription.")
            report(.running, 1, kind: .meeting, span: span)
            return empty
        }
        do {
            return try await transcription.transcribe(
                audioURL: url,
                profile: profile,
                vocabulary: settings.payload.vocabulary,
                channel: channel,
                progress: { stage, fraction in
                    Task { @MainActor [weak self] in
                        self?.report(stage, fraction, kind: .meeting, span: span)
                    }
                }
            )
        } catch TranscriptionEngineError.noSpeech {
            return empty
        }
    }

    private func processMeeting(record original: SessionRecord, files: MeetingAudioFiles) async {
        var record = original
        currentlyProcessingMeetingID = record.id
        defer { currentlyProcessingMeetingID = nil }
        do {
            let profile = settings.payload.meetingProfile
            let microphoneResult = try await transcribeTrack(
                at: files.microphoneURL, channel: .microphone, profile: profile, span: 0...0.35
            )
            let systemResult = try await transcribeTrack(
                at: files.systemURL, channel: .system, profile: profile, span: 0.35...0.7
            )
            // One silent track is normal, not a failure: a meeting where nobody else
            // is on this Mac's audio has an empty system track, and a meeting the
            // owner only listened to has an empty microphone track. Only a recording
            // with nothing at all in it has failed.
            guard !microphoneResult.segments.isEmpty || !systemResult.segments.isEmpty else {
                throw MeetingProcessingError.noSpeechInEitherTrack
            }

            let speakerIntervals: [SpeakerInterval]
            if systemResult.segments.isEmpty {
                // Speaker separation runs on the far end. With no far end there is
                // nobody to tell apart, and the models are worth neither the download
                // nor the minutes.
                speakerIntervals = []
                report(.running, 1, kind: .meeting, span: 0.7...1)
            } else {
                speakerIntervals = try await diarization.diarize(audioURL: files.systemURL) { stage, fraction in
                    Task { @MainActor [weak self] in
                        self?.report(stage, fraction, kind: .meeting, span: 0.7...1)
                    }
                }
            }
            let merged = MeetingTranscriptMerger.merge(
                microphone: microphoneResult.segments,
                system: systemResult.segments,
                speakers: speakerIntervals
            )
            let records = merged.enumerated().map { index, segment in
                TranscriptSegmentRecord(
                    id: segment.id,
                    sessionID: record.id,
                    position: index,
                    start: segment.start,
                    end: segment.end,
                    channel: segment.channel,
                    speaker: segment.speaker,
                    originalText: segment.text,
                    editedText: segment.text
                )
            }
            try Task.checkCancellation()
            record.state = .completed
            record.errorMessage = nil
            record.updatedAt = Date()
            try database.updateSession(record)
            try database.replaceSegments(records, for: record)
            processingTask = nil

            if settings.payload.meetingAudioRetention == .discardAfterTranscription {
                try? database.discardAudio(for: record.id)
            }

            phase = .idle
            bannerMessage = "“\(record.title)” is ready."
            reloadSessions()
            refreshStorageSizes()
            if selectedSessionID == record.id { loadSelectedDetail() }
        } catch is CancellationError {
            // `cancelProcessing` owns the state change; nothing to report.
        } catch {
            guard !Task.isCancelled else { return }
            record.state = .failed
            record.errorMessage = error.localizedDescription
            record.updatedAt = Date()
            try? database.updateSession(record)
            processingTask = nil
            phase = .idle
            hud.flashFailure(error.localizedDescription)
            bannerMessage = "Processing failed. The recording is safe — open the meeting to try again."
            reloadSessions()
        }
    }

    /// Abandons whatever is being transcribed, rewritten, or inserted.
    ///
    /// Waiting is the one part of dictation the owner cannot shorten, so being able
    /// to walk away from it matters. What happens to the work depends on whether it
    /// can be recovered: a dictation's audio is temporary and goes with it, while a
    /// meeting's recording is the irreplaceable part and is kept, with the meeting
    /// left in a state its own screen offers to retry.
    func cancelProcessing() {
        guard processingTask != nil else { return }
        processingTask?.cancel()
        processingTask = nil

        if case .transcribing(.meeting, _) = phase, let id = currentlyProcessingMeetingID {
            if var record = try? database.sessionDetail(id: id)?.session, record.state == .processing {
                record.state = .interrupted
                record.errorMessage = nil
                record.updatedAt = Date()
                try? database.updateSession(record)
            }
            reloadSessions()
            if selectedSessionID == id { loadSelectedDetail() }
            bannerMessage = "Stopped. The recording is kept — open the meeting to try again."
        }

        currentlyProcessingMeetingID = nil
        phase = .idle
        hud.dismissImmediately()
    }

    /// True while there is something worth cancelling.
    var isProcessing: Bool {
        processingTask != nil
    }

    // MARK: - Recovery

    func retrySession(id: UUID) {
        // Every way this can decline says so. A button that reports nothing back is
        // indistinguishable from a button that is broken, and the owner pressing it
        // is already someone whose last attempt did not work.
        guard phase == .idle else {
            bannerMessage = isProcessing
                ? "Something else is being transcribed. This can be retried once it finishes."
                : "Finish the recording in progress first."
            return
        }
        guard let detail = try? database.sessionDetail(id: id) else {
            bannerMessage = "This item could not be read."
            return
        }
        guard detail.session.state == .failed || detail.session.state == .interrupted else { return }
        guard let relativePath = detail.session.audioRelativePath else {
            bannerMessage = "The recording for this item is no longer available."
            return
        }
        let audioURL = database.rootURL.appending(path: relativePath)

        switch detail.session.kind {
        case .dictation:
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                bannerMessage = "The recording for this dictation is no longer available."
                return
            }
            phase = .transcribing(.dictation, progress: 0)
            markProcessing(id)
            processingTask = Task { [weak self] in await self?.retryDictation(detail.session, audioURL: audioURL) }

        case .meeting:
            let microphoneURL = audioURL.appending(path: "microphone.caf")
            let systemURL = audioURL.appending(path: "system.caf")
            guard FileManager.default.fileExists(atPath: microphoneURL.path),
                  FileManager.default.fileExists(atPath: systemURL.path) else {
                bannerMessage = "This meeting's recordings are incomplete."
                return
            }
            var record = detail.session
            record.state = .processing
            record.errorMessage = nil
            record.updatedAt = Date()
            try? database.updateSession(record)
            phase = .transcribing(.meeting, progress: 0)
            reloadSessions()
            // The screen the button lives on reads its state from here, so it has to
            // be re-read now rather than at whatever later moment happens to reload
            // it. Without this the recovery notice keeps offering "Try again" for a
            // retry that is already running, and pressing it again does nothing.
            if selectedSessionID == id { loadSelectedDetail() }
            let cancellableFiles = MeetingAudioFiles(
                directoryURL: audioURL,
                microphoneURL: microphoneURL,
                systemURL: systemURL,
                duration: record.duration
            )
            processingTask = Task { [weak self] in
                await self?.processMeeting(record: record, files: cancellableFiles)
            }
        }
    }

    /// Publishes "this one is being worked on now" to the screen showing it.
    private func markProcessing(_ id: UUID) {
        guard var record = try? database.sessionDetail(id: id)?.session else { return }
        record.state = .processing
        record.errorMessage = nil
        record.updatedAt = Date()
        try? database.updateSession(record)
        reloadSessions()
        if selectedSessionID == id { loadSelectedDetail() }
    }

    private func retryDictation(_ original: SessionRecord, audioURL: URL) async {
        var record = original
        // Re-use the profile the take was recorded with, not the current one: the
        // owner is recovering a specific dictation, not re-running today's settings.
        let profile = (try? JSONDecoder().decode(
            TranscriptionProfile.self,
            from: Data(original.modelSnapshot.utf8)
        )) ?? settings.payload.dictationProfile
        do {
            let result = try await transcription.transcribe(
                audioURL: audioURL,
                profile: profile,
                vocabulary: settings.payload.vocabulary,
                channel: .microphone
            ) { stage, fraction in
                Task { @MainActor [weak self] in
                    self?.report(stage, fraction, kind: .dictation)
                }
            }
            let text = TextCleaner.clean(tidied(result.text))
            record.title = Self.summarise(text)
            record.state = .completed
            record.errorMessage = nil
            record.audioRelativePath = nil
            record.updatedAt = Date()
            try database.updateSession(record)
            try database.replaceSegments([TranscriptSegmentRecord(
                id: UUID(), sessionID: record.id, position: 0,
                start: 0, end: record.duration, channel: .microphone,
                speaker: "You", originalText: result.text, editedText: text
            )], for: record)
            try? FileManager.default.removeItem(at: audioURL)
            phase = .idle
            copy(text, note: "Recovered and copied.")
            reloadSessions()
            selectedSessionID = record.id
        } catch {
            record.state = .failed
            record.errorMessage = error.localizedDescription
            record.updatedAt = Date()
            try? database.updateSession(record)
            phase = .idle
            hud.flashFailure(error.localizedDescription)
        }
    }

    // MARK: - Reuse

    func copy(_ text: String, note: String?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let note { bannerMessage = note }
    }

    /// Puts previously dictated text back into whatever the owner was using.
    ///
    /// Invoked from the main window, so MyWhispr is frontmost and there is no
    /// meaningful target yet. Hiding first returns focus to the previous app, and
    /// only then is the focused element worth asking about.
    func insertAgain(_ text: String) {
        Task { [weak self] in
            guard let self else { return }
            NSApp.hide(nil)
            for _ in 0..<24 {
                try? await Task.sleep(for: .milliseconds(25))
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                    break
                }
            }
            let target = FocusedTargetCapture.capture()
            let outcome = await self.textInserter.insert(text, into: target)
            self.lastInsertedText = text
            switch outcome {
            case .inserted:
                self.hud.flashInserted(wordCount: text.split(whereSeparator: \.isWhitespace).count)
            case .copiedBecauseTargetChanged, .copiedBecauseUnsupported:
                self.hud.flashCopied(reason: .unsupported)
            }
        }
    }

    /// Used by the menu bar and the quick-paste palette, where the target was
    /// captured before this app took focus.
    func insertFromHistory(sessionID: UUID, into target: FocusedTextTarget? = nil) {
        guard let detail = try? database.sessionDetail(id: sessionID) else { return }
        let text = detail.transcript
        guard !text.isEmpty else { return }
        if let target {
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.textInserter.insertRestoringFocus(text, into: target)
                self.lastInsertedText = text
                switch outcome {
                case .inserted:
                    self.hud.flashInserted(wordCount: text.split(whereSeparator: \.isWhitespace).count)
                case .copiedBecauseTargetChanged, .copiedBecauseUnsupported:
                    self.hud.flashCopied(reason: .unsupported)
                }
            }
        } else {
            insertAgain(text)
        }
    }

    // MARK: - Editing

    func updateSegment(_ segment: TranscriptSegmentRecord, text: String, speaker: String) {
        do {
            try database.updateSegment(id: segment.id, text: text, speaker: speaker)
            loadSelectedDetail()
            reloadSessions()
        } catch {
            fail(error)
        }
    }

    func renameSession(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var session = try? database.sessionDetail(id: id)?.session,
              session.title != trimmed else { return }
        session.title = trimmed
        session.updatedAt = Date()
        do {
            try database.updateSession(session)
            loadSelectedDetail()
            reloadSessions()
        } catch {
            fail(error)
        }
    }

    func renameSpeaker(from original: String, to updated: String, in sessionID: UUID) {
        do {
            try database.renameSpeaker(from: original, to: updated, in: sessionID)
            loadSelectedDetail()
        } catch {
            fail(error)
        }
    }

    func deleteSession(id: UUID) {
        do {
            if selectedSessionID == id {
                selectedSessionID = nil
                selectedDetail = nil
                playback.stop()
            }
            try database.deleteSession(id: id)
            reloadSessions()
            refreshStorageSizes()
        } catch {
            fail(error)
        }
    }

    func eraseAllContent() {
        do {
            selectedSessionID = nil
            selectedDetail = nil
            playback.stop()
            try database.deleteEverything()
            reloadSessions()
            refreshStorageSizes()
            bannerMessage = "Everything was deleted."
        } catch {
            fail(error)
        }
    }

    func revealStorageInFinder() {
        try? FileManager.default.createDirectory(at: database.rootURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([database.rootURL])
    }

    // MARK: - Local AI

    func discoverLocalModels() {
        localAIStatus = .checking
        let configuration = settings.payload.localAI
        Task { [weak self] in
            guard let self else { return }
            do {
                let discovered = try await localAI.discoverModels(configuration: configuration)
                self.localModels = discovered
                self.localAIStatus = .connected(models: discovered.count)
                // Choosing the first model for the owner turns "connected but does
                // nothing" into "ready", which is what they came here for.
                if self.settings.payload.localAI.model.isEmpty, let first = discovered.first {
                    self.settings.payload.localAI.model = first
                }
            } catch {
                self.localModels = []
                self.localAIStatus = .failed(error.localizedDescription)
            }
        }
    }

    func generateSummary(for sessionID: UUID) {
        guard summaryGeneration.start(for: sessionID),
              let detail = try? database.sessionDetail(id: sessionID),
              !detail.transcript.isEmpty else {
            summaryGeneration.finish(for: sessionID)
            return
        }
        let configuration = settings.payload.localAI
        summaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await localAI.summarize(detail.annotatedTranscript, configuration: configuration)
                guard !Task.isCancelled else { return }
                self.updateGeneratedSummary(summary, for: sessionID)
                self.finishSummaryGeneration(for: sessionID)
            } catch {
                guard !Task.isCancelled else { return }
                self.finishSummaryGeneration(for: sessionID)
                self.bannerMessage = "Summary failed: \(error.localizedDescription)"
            }
        }
    }

    func cancelSummary(for sessionID: UUID) {
        guard summaryGeneration.isGenerating(for: sessionID) else { return }
        summaryTask?.cancel()
        summaryTask = nil
        summaryGeneration.finish(for: sessionID)
    }

    private func finishSummaryGeneration(for sessionID: UUID) {
        summaryTask = nil
        summaryGeneration.finish(for: sessionID)
    }

    func updateSummary(_ summary: String, for sessionID: UUID) {
        guard var session = try? database.sessionDetail(id: sessionID)?.session else { return }
        session.summary = summary
        session.updatedAt = Date()
        do {
            try database.updateSession(session)
            loadSelectedDetail()
            reloadSessions()
        } catch {
            fail(error)
        }
    }

    private func updateGeneratedSummary(_ generated: MeetingSummary, for sessionID: UUID) {
        guard var session = try? database.sessionDetail(id: sessionID)?.session else { return }
        session.title = generated.title
        session.summary = generated.markdown
        session.updatedAt = Date()
        do {
            // One database update makes the generated title and notes atomic: the
            // sidebar can never show a new title paired with stale notes.
            try database.updateSession(session)
            loadSelectedDetail()
            reloadSessions()
        } catch {
            fail(error)
        }
    }

    // MARK: - Storage bookkeeping

    func applyRetentionPolicies() {
        if let cutoff = settings.payload.historyRetention.cutoff() {
            try? database.pruneDictations(olderThan: cutoff)
        }
        // Audio from a failed dictation is a recovery affordance with a deadline,
        // independent of how long the owner keeps text.
        try? database.pruneFailedDictations(olderThan: Date().addingTimeInterval(-86_400))
    }

    func refreshStorageSizes() {
        let audioRoot = database.audioRootURL
        let store = database.storeSize()
        Task.detached(priority: .utility) {
            let audio = ModelStorage.size(of: audioRoot)
            await MainActor.run {
                self.meetingAudioBytes = audio
                self.databaseBytes = store
            }
        }
        models.refresh()
    }

    // MARK: - Plumbing

    /// Pumps the waveform from the realtime audio relay.
    ///
    /// 30 Hz, which is smoother than the eye needs and far cheaper than the ~47
    /// buffers a second the tap produces. The tap itself never calls into this
    /// class — it cannot — so this is the only path by which levels arrive.
    private func startLevelTicker(_ relay: AudioLevelRelay) {
        stopLevelTicker()
        meter.reset()
        levelTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                self.meter.push(relay.drain())
                if let error = relay.takeError() {
                    self.logger.error("Recording error: \(error.localizedDescription)")
                    self.bannerMessage = error.localizedDescription
                }
            }
        }
    }

    private func stopLevelTicker() {
        levelTicker?.cancel()
        levelTicker = nil
    }

    private func startElapsedTicker() {
        stopElapsedTicker()
        // Drives the menu-bar elapsed time. The HUD keeps its own faster timer.
        elapsedTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isMeetingActive else { return }
                self.meetingTick &+= 1
            }
        }
    }

    private func stopElapsedTicker() {
        elapsedTicker?.cancel()
        elapsedTicker = nil
    }

    private func persistDictation(
        _ text: String,
        result: TranscriptionResult,
        target: FocusedTextTarget?,
        profile: TranscriptionProfile,
        duration: TimeInterval
    ) throws {
        guard settings.payload.historyRetention != .none else { return }
        let now = Date()
        let session = SessionRecord(
            id: UUID(), kind: .dictation,
            title: Self.summarise(text),
            state: .completed,
            startedAt: now.addingTimeInterval(-duration), endedAt: now, duration: duration,
            sourceApplication: target?.applicationName,
            sourceBundleIdentifier: target?.bundleIdentifier,
            modelSnapshot: encodedProfile(profile), audioRelativePath: nil,
            summary: nil, errorMessage: nil, createdAt: now, updatedAt: now
        )
        try database.insertSession(session)
        try database.replaceSegments([TranscriptSegmentRecord(
            id: UUID(), sessionID: session.id, position: 0,
            start: 0, end: duration, channel: .microphone,
            speaker: "You", originalText: result.text, editedText: text
        )], for: session)
    }

    private func persistFailedDictation(
        _ captured: CapturedAudio,
        target: FocusedTextTarget?,
        profile: TranscriptionProfile,
        errorMessage: String
    ) throws {
        let id = UUID()
        let directory = database.audioRootURL.appending(path: "FailedDictations", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let retainedURL = directory.appending(path: "\(id.uuidString).caf")
        if FileManager.default.fileExists(atPath: retainedURL.path) {
            try FileManager.default.removeItem(at: retainedURL)
        }
        try FileManager.default.moveItem(at: captured.url, to: retainedURL)
        let now = Date()
        try database.insertSession(SessionRecord(
            id: id,
            kind: .dictation,
            title: "Dictation that needs another try · \(now.formatted(date: .omitted, time: .shortened))",
            state: .failed,
            startedAt: now.addingTimeInterval(-captured.duration),
            endedAt: now,
            duration: captured.duration,
            sourceApplication: target?.applicationName,
            sourceBundleIdentifier: target?.bundleIdentifier,
            modelSnapshot: encodedProfile(profile),
            audioRelativePath: "Audio/FailedDictations/\(id.uuidString).caf",
            summary: nil,
            errorMessage: errorMessage,
            createdAt: now,
            updatedAt: now
        ))
    }

    /// A dictation's title is its own first words, trimmed to a scannable length.
    private static func summarise(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > 72 else { return flattened }
        return String(flattened.prefix(69)) + "…"
    }

    private func encodedProfile(_ profile: TranscriptionProfile) -> String {
        guard let data = try? JSONEncoder().encode(profile) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func fail(_ error: any Error) {
        logger.error("\(error.localizedDescription)")
        dictationStartWatchdog?.cancel()
        dictationStartWatchdog = nil
        bannerMessage = error.localizedDescription
        phase = .idle
        hud.flashFailure(error.localizedDescription)
    }

    private func reloadSessions() {
        do {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            sessions = trimmed.isEmpty
                ? try database.recentSessions(kind: filter)
                : try database.search(trimmed, kind: filter)
            recentDictations = try database.recentDictations()
        } catch {
            logger.error("History load failed: \(error.localizedDescription)")
        }
    }

    private func loadSelectedDetail() {
        guard let selectedSessionID else {
            selectedDetail = nil
            chat.reset()
            playback.stop()
            return
        }
        do {
            selectedDetail = try database.sessionDetail(id: selectedSessionID)
            chat.load(selectedDetail)
            // Playback is offered for a failed or interrupted meeting too. "Did it
            // even record me?" is the first question when processing goes wrong, and
            // the audio is right there.
            if let relativePath = selectedDetail?.session.audioRelativePath,
               selectedDetail?.session.kind == .meeting,
               selectedDetail?.session.state != .recording {
                do {
                    try playback.load(directoryURL: database.rootURL.appending(path: relativePath))
                } catch {
                    playback.stop()
                    logger.notice("Meeting audio could not be loaded: \(error.localizedDescription)")
                }
            } else {
                playback.stop()
            }
        } catch {
            fail(error)
        }
    }

    private func playCue(named name: String) {
        guard settings.payload.playCues else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
