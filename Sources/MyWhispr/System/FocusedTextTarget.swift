import AppKit
import ApplicationServices
import Foundation

struct FocusedTextTarget: @unchecked Sendable {
    let processIdentifier: pid_t
    let applicationName: String
    let bundleIdentifier: String?
    let element: AXUIElement
    let isSecure: Bool
}

@MainActor
enum FocusedTargetCapture {
    static func capture() -> FocusedTextTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value else { return nil }

        let element = unsafeDowncast(value, to: AXUIElement.self)
        var subroleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        let subrole = subroleValue as? String
        return FocusedTextTarget(
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName ?? "Unknown App",
            bundleIdentifier: application.bundleIdentifier,
            element: element,
            isSecure: subrole == kAXSecureTextFieldSubrole as String
        )
    }

    static func isStillFocused(_ target: FocusedTextTarget) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            return false
        }
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value else { return false }
        return CFEqual(target.element, value)
    }
}

@MainActor
final class TextInserter {
    enum Outcome: Sendable {
        case inserted
        case copiedBecauseTargetChanged
        case copiedBecauseUnsupported
    }

    /// Inserts after handing focus back to the application the target belongs to.
    ///
    /// The quick-paste palette takes key focus for its own arrow keys, which makes
    /// MyWhispr frontmost and would otherwise make every insertion fall back to the
    /// clipboard. Re-activating the original app first restores the precondition
    /// that ``insert(_:into:)`` checks, so text still lands at the live cursor.
    func insertRestoringFocus(_ text: String, into target: FocusedTextTarget?) async -> Outcome {
        guard let target else { return await insert(text, into: nil) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier,
           let application = NSRunningApplication(processIdentifier: target.processIdentifier) {
            application.activate()
            // Activation is asynchronous; the focused element is not authoritative
            // until the app has actually come forward. Poll rather than sleep a flat
            // interval so a fast switch is not punished by a worst-case delay.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(25))
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    break
                }
            }
        }
        return await insert(text, into: target)
    }

    func insert(_ text: String, into target: FocusedTextTarget?) async -> Outcome {
        guard let target, !target.isSecure else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .copiedBecauseUnsupported
        }
        guard FocusedTargetCapture.isStillFocused(target) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .copiedBecauseTargetChanged
        }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            target.element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success,
        settable.boolValue,
        AXUIElementSetAttributeValue(
            target.element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success {
            return .inserted
        }

        return await pasteWithClipboardPreservation(text) ? .inserted : .copiedBecauseUnsupported
    }

    private func pasteWithClipboardPreservation(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        let injectedChangeCount = pasteboard.changeCount

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        try? await Task.sleep(for: .milliseconds(180))

        if pasteboard.changeCount == injectedChangeCount {
            snapshot.restore(to: pasteboard)
        }
        return true
    }
}

private struct PasteboardSnapshot {
    struct Entry {
        var values: [(NSPasteboard.PasteboardType, Data)]
    }

    let entries: [Entry]

    init(pasteboard: NSPasteboard) {
        entries = (pasteboard.pasteboardItems ?? []).map { item in
            Entry(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = entries.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry.values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
