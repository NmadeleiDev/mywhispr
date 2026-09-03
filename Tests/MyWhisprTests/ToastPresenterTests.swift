import Foundation
import Testing
@testable import MyWhispr

@MainActor
@Suite("Window toast lifecycle")
struct ToastPresenterTests {
    @Test("A toast dismisses itself after its lifetime")
    func dismissesAutomatically() async throws {
        let presenter = ToastPresenter()

        presenter.present("Summary copied.", tone: .success, for: .milliseconds(20))
        #expect(presenter.current?.text == "Summary copied.")
        #expect(presenter.current?.tone == .success)

        for _ in 0..<100 where presenter.current != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(presenter.current == nil)
    }

    @Test("An older timer cannot dismiss a newer toast")
    func replacementOwnsItsLifetime() async throws {
        let presenter = ToastPresenter()

        presenter.present("First", for: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(10))
        presenter.present("Second", tone: .warning, for: .seconds(60))
        try await Task.sleep(for: .milliseconds(30))

        #expect(presenter.current?.text == "Second")
        #expect(presenter.current?.tone == .warning)
        presenter.dismiss()
    }

    @Test("A toast can be dismissed immediately")
    func dismissesManually() {
        let presenter = ToastPresenter()

        presenter.present("Copied", tone: .success)
        presenter.dismiss()

        #expect(presenter.current == nil)
    }
}
