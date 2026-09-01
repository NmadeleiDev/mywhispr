import AppKit
import Foundation
import Testing
@testable import MyWhispr

@MainActor
@Suite("HUD panel lifecycle", .serialized)
struct HUDPresenterTests {
    @Test("A new visibility session receives a new panel")
    func renewsPanelAfterHiding() throws {
        let application = NSApplication.shared
        let existingPanels = Set(application.windows.compactMap { window in
            (window as? HUDPanel).map(ObjectIdentifier.init)
        })
        let presenter = HUDPresenter()

        presenter.update(phase: .preparing(.dictation), enabled: true)
        let first = try #require(
            application.windows.compactMap { $0 as? HUDPanel }
                .first { !existingPanels.contains(ObjectIdentifier($0)) }
        )
        let firstWindowNumber = first.windowNumber
        #expect(first.isVisible)

        presenter.update(
            phase: .recording(.dictation, startedAt: Date()),
            enabled: true
        )
        let duringRecording = try #require(
            application.windows.compactMap { $0 as? HUDPanel }
                .first { $0.windowNumber == firstWindowNumber }
        )
        #expect(duringRecording === first)

        presenter.update(phase: .idle, enabled: true)
        #expect(!first.isVisible)
        #expect(first.contentView == nil)

        presenter.update(phase: .preparing(.dictation), enabled: true)
        let second = try #require(
            application.windows.compactMap { $0 as? HUDPanel }
                .first { $0.isVisible && $0.windowNumber != firstWindowNumber }
        )
        #expect(second !== first)

        presenter.update(phase: .idle, enabled: true)
    }

    @Test("A disabled HUD never creates a panel")
    func disabledHUDHasNoPanelLifetime() {
        let application = NSApplication.shared
        let before = Set(application.windows.compactMap { window in
            (window as? HUDPanel).map(ObjectIdentifier.init)
        })
        let presenter = HUDPresenter()

        presenter.update(phase: .preparing(.dictation), enabled: false)

        let after = Set(application.windows.compactMap { window in
            (window as? HUDPanel).map(ObjectIdentifier.init)
        })
        #expect(after == before)
    }
}
