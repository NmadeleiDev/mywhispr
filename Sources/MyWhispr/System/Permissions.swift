import AppKit
import AVFoundation
import CoreGraphics
import Observation
import OSLog

@MainActor
@Observable
final class PermissionCenter {
    enum Status: Equatable {
        /// Never asked, or asked and not yet answered. The honest state for
        /// Accessibility and Input Monitoring, whose APIs cannot distinguish
        /// "not yet requested" from "refused".
        case unknown
        case granted
        case denied
    }

    var microphone: Status = .unknown
    var accessibility: Status = .unknown
    var inputMonitoring: Status = .unknown

    /// Fired when a capability flips to granted, so the runtime can rebuild the
    /// event tap the moment Input Monitoring is allowed rather than at next launch.
    var onGranted: (() -> Void)?

    private var pollTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.mywhispr.mac", category: "permissions")

    init() {
        refresh()
    }

    /// Dictation needs to hear you and to type for you. That is all.
    ///
    /// Input Monitoring is deliberately *not* required. An app trusted for
    /// Accessibility already has the right to observe keyboard events, which this
    /// app verified empirically: with the Input Monitoring list completely empty and
    /// only Accessibility granted, `CGPreflightListenEventAccess` reported access and
    /// the event tap delivered events normally. Demanding it as well would be asking
    /// for a permission the app does not use — and it is the most alarming-sounding
    /// permission on the list.
    var dictationReady: Bool {
        microphone == .granted && accessibility == .granted
    }

    /// Whether keyboard events can be observed at all, by either route.
    var canObserveKeyboard: Bool {
        accessibility == .granted || inputMonitoring == .granted
    }

    /// What is currently broken, phrased as the capability the owner loses rather
    /// than as the macOS permission's own name. "Accessibility is not granted" tells
    /// someone nothing about why their dictation key stopped working.
    ///
    /// Written as three whole sentences rather than assembled from fragments: the
    /// generic joiner produced "cannot hear you or notice the dictation key or type
    /// into other apps yet", which is technically accurate and unreadable.
    var blockedSummary: String {
        switch (microphone == .granted, accessibility == .granted) {
        case (true, true):
            "Dictation is ready."
        case (false, true):
            "MyWhispr cannot hear you yet."
        case (true, false):
            "MyWhispr cannot notice the dictation key or type into other apps yet."
        case (false, false):
            "MyWhispr needs permission to hear you and to type into other apps."
        }
    }

    func refresh() {
        let wasReady = dictationReady

        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .unknown
        @unknown default: .unknown
        }

        // `AXIsProcessTrusted` and `CGPreflightListenEventAccess` are booleans: there
        // is no API that separates "never asked" from "refused". Reporting a bare
        // false as `.denied` was wrong in a way that broke setup — it sent the owner
        // to System Settings to find an app that was not listed there yet, because
        // an app only appears in those lists once it has *requested* the permission.
        // Unknown is the truthful state, and it is the one that offers Allow.
        accessibility = AXIsProcessTrusted() ? .granted : .unknown
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .unknown

        if !wasReady, dictationReady { onGranted?() }
    }

    /// Polls while a surface that shows permission state is on screen.
    ///
    /// macOS posts no notification when a TCC toggle changes, and the owner grants
    /// these in another application, so the only way for the checkmarks to appear as
    /// they flip the switches is to keep asking.
    func beginPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func endPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    /// Prompts for Accessibility. The prompt is also what registers MyWhispr in the
    /// Accessibility list, so this stays useful even after a refusal.
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refresh()
    }

    /// Requests Input Monitoring, by two routes because one is not reliable.
    ///
    /// `CGRequestListenEventAccess` prompts at most once per app identity; once a
    /// decision exists it returns silently and the owner sees a button that does
    /// nothing. The dependable trigger is *attempting the restricted operation* —
    /// building a keyboard event tap — which is what makes TCC create a record and
    /// list the app at all.
    ///
    /// Note this cannot be gated on the permission already being granted, which
    /// would be circular: without the attempt the app never appears in the list, so
    /// it can never be switched on.
    func requestInputMonitoring() {
        let prompted = CGRequestListenEventAccess()
        logger.notice("CGRequestListenEventAccess returned \(prompted, privacy: .public)")
        refresh()
        guard inputMonitoring != .granted else { return }
        provokeEventTapRegistration()
        refresh()
        logger.notice("after tap attempt, preflight = \(CGPreflightListenEventAccess(), privacy: .public)")
    }

    /// Builds and immediately discards a keyboard tap purely so macOS registers
    /// MyWhispr as an app that wants Input Monitoring.
    private func provokeEventTapRegistration() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            logger.notice("tap creation refused — TCC should now list MyWhispr")
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }

    /// Shows the app in Finder so it can be dragged into the Input Monitoring list.
    ///
    /// The `+` button in System Settings opens a picker rooted at `/Applications`,
    /// and a locally built app is not there — so pointing at the bundle is the
    /// difference between a usable escape hatch and a dead end.
    func revealApplicationInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
