import AppKit
import Carbon.HIToolbox
import Foundation

/// A user-assignable key combination.
///
/// Stored as a raw virtual key code plus Carbon modifier mask so it survives
/// keyboard-layout changes: the owner who bound ⌃⌥⌘M on QWERTY keeps the same
/// physical key on Dvorak, which is what "the M key" means to a hand on a keyboard.
struct ShortcutBinding: Codable, Hashable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var carbonModifiers: UInt32
    var isEnabled: Bool = true

    static let meetingToggle = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_M),
        carbonModifiers: UInt32(cmdKey | optionKey | controlKey)
    )

    static let quickPaste = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(cmdKey | optionKey)
    )

    static let openMainWindow = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_O),
        carbonModifiers: UInt32(cmdKey | optionKey | controlKey)
    )

    var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.isEnabled = isEnabled
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        // A bare key with no modifiers would swallow ordinary typing system-wide.
        guard carbon != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
        self.isEnabled = true
    }

    /// `⌃⌥⌘M` — rendered with the same glyphs macOS uses in menus.
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    /// Resolves the virtual key code through the *current* keyboard layout, so a
    /// Dvorak user sees the letter their key actually produces.
    static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Which physical modifier is held down to dictate.
///
/// Right Command is the default because it is reachable by the right thumb without
/// leaving the home row and is unbound in almost every app. The alternatives exist
/// for owners who have already given that key to something else.
enum PushToTalkKey: String, Codable, CaseIterable, Sendable {
    case rightCommand
    case rightOption
    case rightControl
    /// For keyboards that do not distinguish the two Command keys at all. Pressing
    /// any other key while held cancels the take, so ⌘C still copies.
    case anyCommand
    case fn

    var displayName: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        case .anyCommand: "Either ⌘"
        case .fn: "Fn (Globe)"
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .rightCommand: CGKeyCode(kVK_RightCommand)
        case .rightOption: CGKeyCode(kVK_RightOption)
        case .rightControl: CGKeyCode(kVK_RightControl)
        case .anyCommand: CGKeyCode(kVK_Command)
        case .fn: CGKeyCode(kVK_Function)
        }
    }

    /// Device-dependent modifier bits, which are the authoritative source for
    /// left-versus-right.
    ///
    /// Matching on key codes is not reliable: some keyboards report the right
    /// Command key with the *left* Command key code, so a monitor looking for
    /// `kVK_RightCommand` never sees the key being pressed at all. These bits come
    /// straight from the HID layer and say which physical side is down.
    /// Values are the `NX_DEVICE*KEYMASK` constants from `IOLLEvent.h`.
    var deviceFlagMask: UInt64 {
        switch self {
        case .rightCommand: 0x0000_0010          // NX_DEVICERCMDKEYMASK
        case .rightOption: 0x0000_0040           // NX_DEVICERALTKEYMASK
        case .rightControl: 0x0000_2000          // NX_DEVICERCTLKEYMASK
        case .anyCommand: 0x0000_0018            // left | right command
        case .fn: 0x0080_0000                    // NX_SECONDARYFNMASK
        }
    }
}
