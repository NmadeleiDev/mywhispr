import Foundation
import Observation
import OSLog
import ServiceManagement

struct LocalAIConfiguration: Codable, Equatable, Sendable {
    enum Provider: String, Codable, CaseIterable, Sendable {
        case ollama
        case openAICompatible

        var displayName: String {
            switch self {
            case .ollama: "Ollama"
            case .openAICompatible: "OpenAI-compatible"
            }
        }

        var defaultBaseURL: String {
            switch self {
            case .ollama: "http://127.0.0.1:11434"
            case .openAICompatible: "http://127.0.0.1:1234/v1"
            }
        }
    }

    var provider: Provider = .ollama
    var baseURL = "http://127.0.0.1:11434"
    /// Model used to rewrite a dictation before insertion.
    var model = ""
    /// Model used for meeting summaries. Empty means "use the rewrite model", which
    /// is the common case; a separate field lets a small fast model clean up
    /// dictation while a larger one writes meeting notes.
    var summaryModel = ""
    /// Model used only to embed meeting passages for semantic retrieval. Keeping
    /// it separate prevents an embedding-only model from ever being sent a chat.
    var embeddingModel = ""
    var rewriteEnabled = false
    var rewritePrompt = LocalAIConfiguration.defaultRewritePrompt
    var summaryPrompt = LocalAIConfiguration.defaultSummaryPrompt
    /// Language used for both the generated meeting title and its notes. Matching
    /// the transcript is the least surprising default for multilingual owners.
    var summaryLanguage = SummaryLanguage.transcript
    /// What the model is told before a question about a meeting.
    var chatPrompt = LocalAIConfiguration.defaultChatPrompt
    /// Rewriting runs inside the gap between releasing the key and seeing text
    /// appear, so it is bounded hard. Past this, the faithful transcript wins.
    var rewriteTimeoutSeconds: Double = 4
    var allowLAN = false
    /// The largest context window MyWhispr will ask a server to load.
    ///
    /// A meeting is asked about in full, so the window has to hold the whole
    /// transcript — but the window is memory, and a ceiling the owner controls is
    /// the difference between "the model read all of it" and a machine that swaps
    /// itself to a standstill. 32K holds roughly two hours of speech.
    var maxContextTokens = 32_768

    /// Decoded key by key, for the same reason ``SettingsStore/Payload`` is.
    ///
    /// The synthesized decoder throws when a key is absent, and the payload above
    /// catches that with `try?` — so adding a single field here would have silently
    /// reset the endpoint, the chosen models and the owner's edited prompts to
    /// factory defaults on the next launch, with nothing reported anywhere.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LocalAIConfiguration()

        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? `default`
        }

        provider = value(.provider, fallback.provider)
        baseURL = value(.baseURL, fallback.baseURL)
        model = value(.model, fallback.model)
        summaryModel = value(.summaryModel, fallback.summaryModel)
        embeddingModel = value(.embeddingModel, fallback.embeddingModel)
        rewriteEnabled = value(.rewriteEnabled, fallback.rewriteEnabled)
        rewritePrompt = value(.rewritePrompt, fallback.rewritePrompt)
        summaryPrompt = value(.summaryPrompt, fallback.summaryPrompt)
        summaryLanguage = value(.summaryLanguage, fallback.summaryLanguage)
        chatPrompt = value(.chatPrompt, fallback.chatPrompt)
        rewriteTimeoutSeconds = value(.rewriteTimeoutSeconds, fallback.rewriteTimeoutSeconds)
        allowLAN = value(.allowLAN, fallback.allowLAN)
        maxContextTokens = value(.maxContextTokens, fallback.maxContextTokens)
    }

    init() {}

    /// Ceilings offered in Settings, with roughly how much meeting each holds.
    static let contextChoices = [8_192, 16_384, 32_768, 65_536, 131_072]

    /// Answering questions about a meeting, not summarising one.
    ///
    /// The instruction that matters is the refusal: a model given a transcript and a
    /// question it cannot answer from that transcript will answer anyway, from what
    /// meetings usually contain. An invented decision read back in the owner's own
    /// meeting is worse than no answer at all, so "say you don't know" is stated
    /// before anything else.
    static let defaultChatPrompt = """
    You answer questions about a meeting, using the transcript below as your only \
    source.

    Answer from the transcript alone. If it does not contain the answer, say so \
    plainly rather than guessing or filling the gap with what usually happens in \
    meetings. Never invent a decision, a name, a number or a commitment.

    Cite the timestamp in square brackets when you point at something specific, and \
    quote the speaker's own words when the wording matters. Be brief unless asked \
    for detail. Answer in the language of the question. Format with Markdown.
    """

    static let defaultSummaryPrompt = """
    Create concise meeting notes with decisions and action items. Do not invent \
    facts. Return Markdown.
    """

    /// Polish, not rewriting.
    ///
    /// The instruction is negative on purpose. Asked to "rewrite this into clean
    /// prose", a model does exactly that — it paraphrases, and the words that come
    /// back are its own rather than the owner's. Dictation is the owner writing, so
    /// every transformation beyond tidying has to be closed off by name.
    static let defaultRewritePrompt = """
    You clean up dictated text. Return the same text with only these changes: \
    remove filler sounds, false starts and accidental repetitions; fix punctuation, \
    capitalisation, and obvious speech-recognition slips.

    Never paraphrase, summarise, translate, reorder, shorten or add anything. Keep \
    the speaker's own words, wording, tone and language. Keep names, technical \
    terms, identifiers and URLs exactly as written. If the text is already clean, \
    return it unchanged.

    Reply with the corrected text only — no preamble, quotes, code fences or notes.
    """

    /// Defaults that shipped previously. A stored prompt matching one of these was
    /// never edited by the owner, so it is theirs only by accident and is replaced;
    /// anything else is a deliberate choice and is left alone.
    static let retiredRewritePrompts = [
        "Rewrite this transcript into clean, concise prose. Preserve meaning, names, technical terms, and the original language. Return only the rewritten text.",
    ]

    /// The model a summary should actually use, resolving the "same as rewrite"
    /// default in one place instead of at every call site.
    var effectiveSummaryModel: String {
        summaryModel.isEmpty ? model : summaryModel
    }
}

/// The language of model-written meeting metadata, separate from the language the
/// speech recognizer listens for. A transcript may be detected automatically while
/// its owner still wants every set of notes written in one consistent language.
enum SummaryLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case transcript
    case en, ru, de, fr, es, it, pt, nl, pl, uk, tr, ja, ko, zh, ar, hi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcript: "Match transcript"
        case .en: "English"
        case .ru: "Russian"
        case .de: "German"
        case .fr: "French"
        case .es: "Spanish"
        case .it: "Italian"
        case .pt: "Portuguese"
        case .nl: "Dutch"
        case .pl: "Polish"
        case .uk: "Ukrainian"
        case .tr: "Turkish"
        case .ja: "Japanese"
        case .ko: "Korean"
        case .zh: "Chinese"
        case .ar: "Arabic"
        case .hi: "Hindi"
        }
    }

    var promptInstruction: String {
        switch self {
        case .transcript:
            "Write both the title and the summary in the predominant language of the transcript."
        default:
            "Write both the title and the summary in \(displayName)."
        }
    }
}

/// Where a dictation's text is allowed to live after it has been inserted.
enum HistoryRetention: Int, Codable, CaseIterable, Sendable, Identifiable {
    case none = 0
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case forever = -1

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .none: "Don't keep"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .forever: "Keep everything"
        }
    }

    /// The instant before which dictations should be discarded, or nil when nothing
    /// expires.
    func cutoff(from now: Date = Date()) -> Date? {
        switch self {
        case .forever: nil
        case .none: now
        default: Calendar.current.date(byAdding: .day, value: -rawValue, to: now)
        }
    }
}

/// What happens to a meeting's two audio tracks once it has been transcribed.
enum MeetingAudioRetention: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Keep audio so passages stay clickable and playback keeps working.
    case keep
    /// Discard audio after a successful transcript. Playback stops working; the
    /// transcript and summary remain.
    case discardAfterTranscription

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keep: "Keep the recording"
        case .discardAfterTranscription: "Delete after transcribing"
        }
    }

    var explanation: String {
        switch self {
        case .keep: "Playback and click-to-hear stay available."
        case .discardAfterTranscription: "Saves disk space. Playback is not available."
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let payload = "settings.payload.v2"
        static let legacyPayload = "settings.payload.v1"
    }

    struct Payload: Codable, Equatable, Sendable {
        var dictationProfile = TranscriptionProfile.dictationDefault
        var meetingProfile = TranscriptionProfile.meetingDefault
        var localAI = LocalAIConfiguration()

        /// Names, jargon, and product names the owner wants spelled their way.
        ///
        /// One list for the whole app rather than one per workflow: it describes the
        /// owner's world, not the job they happen to be doing, and splitting it means
        /// adding a name twice and silently not having it work in whichever half was
        /// forgotten.
        var vocabulary: [String] = []

        /// Removes the sounds of speaking from dictated text. Meeting transcripts
        /// are never touched: a meeting is a record of what was said.
        var tidyDictation = true

        var historyRetention: HistoryRetention = .thirtyDays
        var meetingAudioRetention: MeetingAudioRetention = .keep
        /// Writes notes as soon as a meeting transcript is ready. This remains a
        /// workflow preference rather than part of the connection: changing local
        /// AI providers must not silently change what happens after a meeting.
        var automaticallySummarizeMeetings = false

        var launchAtLogin = false
        var playCues = true
        var showHUD = true
        var showDockIcon = false
        /// The owner has been through the setup journey at least once. Suppresses
        /// the automatic setup window on later launches even if a permission is
        /// later revoked — the menu bar surfaces that case instead.
        var hasCompletedSetup = false

        var pushToTalkKey: PushToTalkKey = .rightCommand
        var pushToTalkEnabled = true
        var meetingShortcut = ShortcutBinding.meetingToggle
        var quickPasteShortcut = ShortcutBinding.quickPaste
        var openWindowShortcut = ShortcutBinding.openMainWindow
        var quickPasteEnabled = true

        /// Discards takes shorter than this, which is what an accidental brush
        /// against the talk key produces.
        var minimumDictationSeconds: Double = 0.35
        /// Hard ceiling on a single dictation, so a key stuck down by a wedged app
        /// cannot record until the disk fills.
        var maximumDictationSeconds: Double = 300

        // Legacy field kept for decoding v1 payloads; migrated in `init`.
        var dictationRetentionDays: Int?

        init() {}

        /// Decoded key by key against a fresh payload's defaults.
        ///
        /// Swift's synthesized decoder does *not* fall back to a property's default
        /// when its key is absent — it throws. With the synthesized version, adding
        /// any new setting made every previously stored payload undecodable, and the
        /// store's `else` branch then quietly handed back factory defaults: one app
        /// update and the owner's shortcuts, model choices and retention policy were
        /// gone with no error anywhere. Settings have to survive their own schema
        /// changing, so every key is optional on the way in.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = Payload()

            func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
                (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? `default`
            }

            dictationProfile = value(.dictationProfile, fallback.dictationProfile)
            meetingProfile = value(.meetingProfile, fallback.meetingProfile)
            localAI = value(.localAI, fallback.localAI)
            vocabulary = value(.vocabulary, fallback.vocabulary)
            tidyDictation = value(.tidyDictation, fallback.tidyDictation)
            historyRetention = value(.historyRetention, fallback.historyRetention)
            meetingAudioRetention = value(.meetingAudioRetention, fallback.meetingAudioRetention)
            automaticallySummarizeMeetings = value(
                .automaticallySummarizeMeetings,
                fallback.automaticallySummarizeMeetings
            )
            launchAtLogin = value(.launchAtLogin, fallback.launchAtLogin)
            playCues = value(.playCues, fallback.playCues)
            showHUD = value(.showHUD, fallback.showHUD)
            showDockIcon = value(.showDockIcon, fallback.showDockIcon)
            hasCompletedSetup = value(.hasCompletedSetup, fallback.hasCompletedSetup)
            pushToTalkKey = value(.pushToTalkKey, fallback.pushToTalkKey)
            pushToTalkEnabled = value(.pushToTalkEnabled, fallback.pushToTalkEnabled)
            meetingShortcut = value(.meetingShortcut, fallback.meetingShortcut)
            quickPasteShortcut = value(.quickPasteShortcut, fallback.quickPasteShortcut)
            openWindowShortcut = value(.openWindowShortcut, fallback.openWindowShortcut)
            quickPasteEnabled = value(.quickPasteEnabled, fallback.quickPasteEnabled)
            minimumDictationSeconds = value(.minimumDictationSeconds, fallback.minimumDictationSeconds)
            maximumDictationSeconds = value(.maximumDictationSeconds, fallback.maximumDictationSeconds)
            dictationRetentionDays = try? container.decodeIfPresent(Int.self, forKey: .dictationRetentionDays)
        }
    }

    var payload: Payload {
        didSet {
            guard payload != oldValue else { return }
            save()
        }
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "app.mywhispr.mac", category: "settings")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.payload),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = Self.migrated(decoded)
        } else if let legacy = defaults.data(forKey: Key.legacyPayload),
                  var decoded = try? JSONDecoder().decode(Payload.self, from: legacy) {
            // v1 stored retention as a bare day count. Map it onto the closest
            // named option so an existing install does not silently change policy.
            if let days = decoded.dictationRetentionDays {
                decoded.historyRetention = HistoryRetention(rawValue: days) ?? .thirtyDays
                decoded.dictationRetentionDays = nil
            }
            payload = Self.migrated(decoded)
        } else {
            payload = Payload()
        }
    }

    private static func migrated(_ payload: Payload) -> Payload {
        migratingRewritePrompt(migratingVocabulary(payload))
    }

    /// Moves an untouched install onto the current rewrite instruction.
    private static func migratingRewritePrompt(_ payload: Payload) -> Payload {
        var migrated = payload
        let stored = migrated.localAI.rewritePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if LocalAIConfiguration.retiredRewritePrompts.contains(stored) {
            migrated.localAI.rewritePrompt = LocalAIConfiguration.defaultRewritePrompt
        }
        return migrated
    }

    /// Folds the two former per-workflow word lists into the single shared one.
    ///
    /// Runs against the current payload as well as the legacy one, because the
    /// split lists shipped in v2 and an existing install has them under the same key.
    private static func migratingVocabulary(_ payload: Payload) -> Payload {
        var migrated = payload
        let inherited = (migrated.dictationProfile.legacyVocabulary ?? [])
            + (migrated.meetingProfile.legacyVocabulary ?? [])
        migrated.dictationProfile.legacyVocabulary = nil
        migrated.meetingProfile.legacyVocabulary = nil
        guard !inherited.isEmpty else { return migrated }

        var seen = Set(migrated.vocabulary.map { $0.lowercased() })
        for entry in inherited {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            migrated.vocabulary.append(trimmed)
        }
        return migrated
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        payload.launchAtLogin = enabled
    }

    /// Reconciles the stored preference with what the system actually reports, so a
    /// login item removed in System Settings does not leave a lying checkbox.
    func refreshLaunchAtLoginStatus() {
        payload.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func resetShortcuts() {
        payload.pushToTalkKey = .rightCommand
        payload.pushToTalkEnabled = true
        payload.meetingShortcut = .meetingToggle
        payload.quickPasteShortcut = .quickPaste
        payload.openWindowShortcut = .openMainWindow
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(payload), forKey: Key.payload)
        } catch {
            logger.error("Settings could not be saved: \(error.localizedDescription)")
        }
    }
}
