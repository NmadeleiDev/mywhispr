import Foundation
import Testing
@testable import MyWhispr

@MainActor
@Suite("Settings persistence")
struct SettingsStoreTests {
    @Test func roundTripsIndependentWorkflowModels() throws {
        let suite = "MyWhisprTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SettingsStore(defaults: defaults)
        first.payload.dictationProfile = .init(
            engine: .whisperKit, modelID: "small", language: .fixed("en")
        )
        first.payload.meetingProfile = .meetingDefault

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.payload.dictationProfile.modelID == "small")
        #expect(restored.payload.meetingProfile.modelID == "large-v3-v20240930_626MB")
        #expect(restored.payload.dictationProfile != restored.payload.meetingProfile)
    }

    @Test("The two former per-workflow word lists become one shared vocabulary")
    func migratesSplitVocabularies() throws {
        let suite = "MyWhisprTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Written the way the previous build stored it: a list inside each profile,
        // none shared.
        let legacy = #"""
        {
          "dictationProfile": {
            "engine": "fluidAudio", "modelID": "parakeet-tdt-v3",
            "language": {"automatic": {}}, "vocabulary": ["darwinapps", "Parakeet"]
          },
          "meetingProfile": {
            "engine": "whisperKit", "modelID": "large-v3-v20240930_626MB",
            "language": {"automatic": {}}, "vocabulary": ["DARWINAPPS", "Neural Engine"]
          }
        }
        """#
        defaults.set(Data(legacy.utf8), forKey: "settings.payload.v2")

        let store = SettingsStore(defaults: defaults)
        // Merged in order, and a name that appeared in both lists appears once.
        #expect(store.payload.vocabulary == ["darwinapps", "Parakeet", "Neural Engine"])
        #expect(store.payload.dictationProfile.legacyVocabulary == nil)
        #expect(store.payload.meetingProfile.legacyVocabulary == nil)
        #expect(store.payload.dictationProfile.modelID == "parakeet-tdt-v3")
    }

    @Test("Migration leaves an already-shared vocabulary alone")
    func doesNotDisturbAMigratedInstall() throws {
        let suite = "MyWhisprTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.payload.vocabulary = ["darwinapps", "Parakeet"]

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.payload.vocabulary == ["darwinapps", "Parakeet"])
    }

    @Test("A saved profile no longer carries a word list of its own")
    func retiredFieldIsNotWrittenBack() throws {
        let suite = "MyWhisprTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.payload.vocabulary = ["darwinapps"]

        let saved = try #require(defaults.data(forKey: "settings.payload.v2"))
        let profile = try #require(
            try JSONSerialization.jsonObject(with: saved) as? [String: Any]
        )["dictationProfile"] as? [String: Any]
        #expect(profile?["vocabulary"] == nil)
    }
}
