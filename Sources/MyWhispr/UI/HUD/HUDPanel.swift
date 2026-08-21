import AppKit
import SwiftUI

/// A borderless, non-activating panel used for the recording HUD.
///
/// Three properties matter and all three are load-bearing for the product's
/// defining moment — text landing at the live cursor:
///
/// 1. It never becomes key or main, so holding Right Command while typing in Mail
///    does not pull focus out of Mail's compose field.
/// 2. It joins all Spaces and sits at status-bar level, so it is visible over
///    full-screen apps, where dictation is most useful.
/// 3. Its content view is transparent and hit-testing is delegated to SwiftUI, so
///    clicks land on the pill but pass straight through the empty canvas around it.
@MainActor
final class HUDPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Excluded from window cycling and from screen sharing captures of the app.
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Variant used by the quick-paste palette, which *does* need arrow keys and Return.
///
/// It still uses `.nonactivatingPanel`, so MyWhispr never becomes the active
/// application: the panel takes key focus for its own keystrokes while the app the
/// owner was typing in stays frontmost-in-spirit and, crucially, keeps its own
/// focused text element alive for insertion afterwards.
@MainActor
final class KeyablePanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension NSPanel {
    /// Places the panel horizontally centred on the screen the pointer is on, with
    /// its bottom edge just above the Dock.
    ///
    /// `visibleFrame` already excludes the Dock and menu bar, so this stays correct
    /// on every Dock position and auto-hide setting without special cases.
    func positionAtBottomCentre(inset: CGFloat) {
        guard let screen = NSScreen.screenUnderPointer ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let origin = NSPoint(
            x: area.midX - frame.width / 2,
            y: area.minY + inset
        )
        setFrameOrigin(origin)
    }

    /// Centres the panel slightly above the optical middle of the screen, which is
    /// where the eye expects a summoned palette.
    func positionAtOpticalCentre() {
        guard let screen = NSScreen.screenUnderPointer ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let origin = NSPoint(
            x: area.midX - frame.width / 2,
            y: area.midY - frame.height / 2 + area.height * 0.08
        )
        setFrameOrigin(origin)
    }
}

extension NSScreen {
    /// The screen containing the pointer, which is the screen the owner is working
    /// on — not necessarily `NSScreen.main`.
    static var screenUnderPointer: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(location) }
    }
}
