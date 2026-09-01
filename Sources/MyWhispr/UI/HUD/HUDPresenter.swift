import AppKit
import Observation
import SwiftUI

/// Owns the HUD panel and translates ``RecordingPhase`` into ``HUDState``.
///
/// The runtime deliberately knows nothing about the HUD. It publishes a phase; this
/// type decides what a human should see, including the things that are presentation
/// concerns rather than domain state: how long a success flash lingers, and when a
/// long meeting's pill collapses to stop being furniture.
@MainActor
@Observable
final class HUDPresenter {
    private(set) var state: HUDState = .hidden

    @ObservationIgnored private var panel: HUDPanel?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var meetingCollapsed = false
    @ObservationIgnored private weak var runtime: AppRuntime?

    /// How long a terminal state stays on screen before the pill shrinks away.
    private enum Linger {
        static let success: Duration = .milliseconds(1_100)
        static let copied: Duration = .seconds(3)
        static let failure: Duration = .seconds(4)
    }

    /// A meeting pill sheds its waveform after this long so an hour-long recording
    /// is a quiet marker rather than a permanent distraction.
    private static let meetingCollapseDelay: Duration = .seconds(6)

    func attach(runtime: AppRuntime) {
        self.runtime = runtime
    }

    /// Called whenever the runtime's phase changes.
    func update(phase: RecordingPhase, enabled: Bool) {
        guard enabled else {
            transition(to: .hidden)
            return
        }
        switch phase {
        case .idle:
            // Terminal flashes own their own dismissal; do not stomp them when the
            // runtime returns to idle a few milliseconds after inserting.
            if case .working = state { transition(to: .hidden) }
            else if state == .armed { transition(to: .hidden) }
            else if case .listening = state { transition(to: .hidden) }
            else if case .meeting = state { transition(to: .hidden) }

        case .preparing(.dictation):
            cancelDismiss()
            transition(to: .armed)

        case .preparing(.meeting):
            cancelDismiss()

        case .recording(.dictation, let startedAt):
            cancelDismiss()
            transition(to: .listening(startedAt: startedAt))

        case .recording(.meeting, let startedAt):
            cancelDismiss()
            scheduleMeetingCollapse()
            transition(to: .meeting(startedAt: startedAt, collapsed: meetingCollapsed))

        case .stopping:
            cancelDismiss()

        case .preparingModel(let kind, let isDownloading, let progress):
            cancelDismiss()
            transition(to: .working(kind, isDownloading ? .downloadingModel : .loadingModel, progress: progress))

        case .transcribing(let kind, let progress):
            cancelDismiss()
            transition(to: .working(kind, .transcribing, progress: progress > 0 ? progress : nil))

        // Rewriting and inserting only ever follow a dictation: a meeting's text goes
        // to the transcript, not to whatever happens to have the cursor.
        case .rewriting:
            cancelDismiss()
            transition(to: .working(.dictation, .rewriting, progress: nil))

        case .inserting:
            cancelDismiss()
            transition(to: .working(.dictation, .inserting, progress: nil))

        case .failed(let message):
            flash(.failed(message), for: Linger.failure)
        }
    }

    /// Terminal confirmations the runtime reports explicitly, because "inserted 14
    /// words" is not recoverable from a phase that has already returned to idle.
    func flashInserted(wordCount: Int) {
        flash(.inserted(words: wordCount), for: Linger.success)
    }

    func flashCopied(reason: HUDState.CopyReason) {
        flash(.copied(reason: reason), for: Linger.copied)
    }

    func flashFailure(_ message: String) {
        flash(.failed(message), for: Linger.failure)
    }

    /// Takes the pill away at once, with no confirmation flash.
    ///
    /// Used when the owner cancels: they already know what happened, and a
    /// "cancelled" badge would just be the app repeating their own action back.
    func dismissImmediately() {
        cancelDismiss()
        transition(to: .hidden)
    }

    // MARK: - Panel lifecycle

    private func transition(to next: HUDState) {
        guard next != state else { return }
        state = next
        if next.isVisible {
            showPanel()
        } else {
            meetingCollapsed = false
            collapseTask?.cancel()
            collapseTask = nil
            hidePanel()
        }
    }

    private func flash(_ next: HUDState, for duration: Duration) {
        cancelDismiss()
        state = next
        showPanel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.transition(to: .hidden)
        }
    }

    private func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func scheduleMeetingCollapse() {
        guard collapseTask == nil, !meetingCollapsed else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.meetingCollapseDelay)
            guard !Task.isCancelled, let self else { return }
            self.meetingCollapsed = true
            if case .meeting(let startedAt, _) = self.state {
                self.state = .meeting(startedAt: startedAt, collapsed: true)
            }
        }
    }

    private func showPanel() {
        let panel = existingPanel()
        // Re-place on every show: the owner may have moved to another display since
        // the last dictation, and the HUD belongs on the screen they are working on.
        panel.positionAtBottomCentre(inset: 0)
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        guard let panel else { return }
        // A transient HUD owns its panel only while the interaction is visible.
        self.panel = nil
        panel.contentView = nil
        panel.close()
    }

    private func existingPanel() -> HUDPanel {
        if let panel { return panel }
        let created = HUDPanel(size: Metrics.hudPanelSize)
        // The panel is hosted outside the app's scene graph, so the runtime is
        // handed over explicitly rather than read from the SwiftUI environment.
        let host = NSHostingView(rootView: HUDHost(presenter: self, runtime: runtime))
        // Hit-testing is delegated to SwiftUI: the transparent canvas around the
        // pill returns no hit, so clicks fall through to whatever is underneath.
        created.contentView = host
        panel = created
        return created
    }
}

/// Thin bridge so the panel's hosted view observes the presenter and the runtime's
/// meter without the presenter needing to own SwiftUI state.
private struct HUDHost: View {
    var presenter: HUDPresenter
    var runtime: AppRuntime?

    var body: some View {
        if let runtime {
            RecordingHUD(
                state: presenter.state,
                meter: runtime.meter,
                onCancel: { runtime.cancelDictation() },
                onStopMeeting: { runtime.stopMeeting() },
                onCancelProcessing: { runtime.cancelProcessing() }
            )
        }
    }
}
