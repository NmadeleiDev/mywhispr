import Testing
@testable import MyWhispr

@Suite("Curated local model catalog")
struct ModelCatalogTests {
    @Test func defaultsExistAndMeetWorkflowRequirements() {
        let dictation = ModelDescriptor.curated.first {
            $0.id == TranscriptionProfile.dictationDefault.modelID
                && $0.engine == TranscriptionProfile.dictationDefault.engine
        }
        let meeting = ModelDescriptor.curated.first {
            $0.id == TranscriptionProfile.meetingDefault.modelID
                && $0.engine == TranscriptionProfile.meetingDefault.engine
        }
        #expect(dictation != nil)
        #expect(dictation?.supportsAutomaticLanguage == true)
        #expect(meeting?.supportsLongForm == true)
        #expect(meeting?.supportsWordTimestamps == true)
    }

    @Test func everyModelHasLicenseMetadata() {
        #expect(ModelDescriptor.curated.allSatisfy { !$0.license.isEmpty })
    }
}
