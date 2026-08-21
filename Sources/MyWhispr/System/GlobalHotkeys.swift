import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog

/// System-wide hotkeys for the app's *discrete* actions.
///
/// These are registered through `RegisterEventHotKey` rather than the CGEvent tap
/// that handles push-to-talk, and the distinction is not incidental. The tap is
/// `listenOnly`, so anything it observes still reaches the frontmost app — fine for
/// a modifier that means nothing on its own, disastrous for ⌥⌘V, which is Paste and
/// Match Style nearly everywhere. A registered hotkey *consumes* the event, so the
/// quick-paste palette opens without also pasting into the document underneath.
///
/// Registering also costs no Input Monitoring permission, so meeting recording and
/// quick paste keep working even before the owner has finished granting the
/// permissions dictation needs.
@MainActor
final class GlobalHotkeyCenter {
    enum Action: UInt32, CaseIterable {
        case toggleMeeting = 1
        case quickPaste = 2
        case openMainWindow = 3
    }

    private var handlerReference: EventHandlerRef?
    private var registrations: [Action: EventHotKeyRef] = [:]
    private var handler: ((Action) -> Void)?
    private let logger = Logger(subsystem: "app.mywhispr.mac", category: "hotkeys")

    /// Errors are surfaced per-action rather than thrown, because one conflicting
    /// binding must not stop the others from working.
    private(set) var conflicts: Set<Action> = []

    func start(handler: @escaping (Action) -> Void) {
        self.handler = handler
        installHandlerIfNeeded()
    }

    /// Applies a full set of bindings, replacing whatever was registered before.
    func apply(_ bindings: [Action: ShortcutBinding]) {
        installHandlerIfNeeded()
        unregisterAll()
        for (action, binding) in bindings where binding.isEnabled {
            register(action, binding: binding)
        }
    }

    func stop() {
        unregisterAll()
        if let handlerReference {
            RemoveEventHandler(handlerReference)
            self.handlerReference = nil
        }
        handler = nil
    }

    // MARK: - Carbon plumbing

    private func installHandlerIfNeeded() {
        guard handlerReference == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return status }
                let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers on the main thread; assume rather than hop so the
                // action fires in the same run-loop turn the key was pressed.
                MainActor.assumeIsolated {
                    center.dispatch(identifier.id)
                }
                return noErr
            },
            1,
            &spec,
            context,
            &handlerReference
        )
        if status != noErr {
            logger.error("Could not install the hotkey handler (\(status)).")
        }
    }

    private func register(_ action: Action, binding: ShortcutBinding) {
        let identifier = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr, let reference {
            registrations[action] = reference
            conflicts.remove(action)
        } else {
            // `eventHotKeyExistsErr` means another app already owns the combination.
            conflicts.insert(action)
            logger.notice("\(binding.displayString, privacy: .public) is unavailable (\(status)).")
        }
    }

    private func unregisterAll() {
        for reference in registrations.values {
            UnregisterEventHotKey(reference)
        }
        registrations.removeAll()
        conflicts.removeAll()
    }

    private func dispatch(_ rawValue: UInt32) {
        guard let action = Action(rawValue: rawValue) else { return }
        handler?(action)
    }

    /// Four-character signature identifying this app's hotkeys to Carbon.
    private static let signature: OSType = {
        let characters = Array("MWSP".utf8)
        return characters.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()
}
