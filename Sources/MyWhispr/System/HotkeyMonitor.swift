import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Watches one physical modifier key for the hold-to-talk gesture.
///
/// This is a `listenOnly` tap on purpose: the key it watches (Right Command by
/// default) still has to work as a modifier for every other app while MyWhispr is
/// running. Consuming it would break ⌘C for anyone whose right thumb reaches for
/// the right Command key.
///
/// Discrete chords such as the meeting toggle live in ``GlobalHotkeyCenter``
/// instead, where they *are* consumed — see the note there for why that split
/// matters.
@MainActor
final class HotkeyMonitor {
    enum Event {
        case pressed
        case released
        /// Another key was struck while the talk key was held. Treated as "the owner
        /// was typing a shortcut, not dictating" and discards the take.
        case cancelledByChord
    }

    private var talkKey: PushToTalkKey = .rightCommand
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var talkKeyIsDown = false
    private var handler: ((Event) -> Void)?

    var isRunning: Bool { eventTap != nil }

    func start(key: PushToTalkKey, handler: @escaping (Event) -> Void) throws {
        stop()
        self.handler = handler
        talkKey = key

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                MainActor.assumeIsolated {
                    monitor.consume(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            throw HotkeyError.eventTapUnavailable
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        runLoopSource = nil
        eventTap = nil
        talkKeyIsDown = false
        handler = nil
    }

    private func consume(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system disables a slow or contended tap. Re-arm it, and close out
            // any take that was live so audio is never left recording invisibly.
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            if talkKeyIsDown {
                talkKeyIsDown = false
                handler?(.released)
            }
            return
        }

        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if talkKeyIsDown, !isRepeat {
                talkKeyIsDown = false
                handler?(.cancelledByChord)
            }
            return
        }

        guard type == .flagsChanged else { return }

        // Read the device-dependent modifier bits rather than comparing key codes.
        // Some keyboards report the right Command key using the left Command key
        // code, so key-code matching silently never fires; these bits come from the
        // HID layer and state which physical side is actually held.
        let isDown = (event.flags.rawValue & talkKey.deviceFlagMask) != 0
        guard isDown != talkKeyIsDown else { return }
        talkKeyIsDown = isDown
        handler?(isDown ? .pressed : .released)
    }
}

enum HotkeyError: LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
        "MyWhispr could not watch the dictation key. Turn on Input Monitoring and Accessibility in System Settings."
    }
}
