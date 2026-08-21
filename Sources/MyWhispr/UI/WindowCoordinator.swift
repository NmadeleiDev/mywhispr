import AppKit
import SwiftUI

/// Creates and reuses the app's windows.
///
/// SwiftUI's `Window` scenes can only be opened through `openWindow`, which is only
/// reachable from inside a live view. That is a bad fit here for two reasons: a
/// menu-bar app can launch with no window at all, so there may be no view to ask;
/// and the global "open MyWhispr" hotkey arrives on a Carbon callback with no
/// SwiftUI environment anywhere in reach. Owning the windows directly makes opening
/// one an ordinary function call from any of those places.
///
/// Windows use a full-size content view with a transparent titlebar so each surface
/// can draw its own header rather than inheriting system toolbar chrome.
@MainActor
final class WindowCoordinator: NSObject {
    private weak var runtime: AppRuntime?
    private var windows: [String: NSWindow] = [:]

    func attach(runtime: AppRuntime) {
        self.runtime = runtime
    }

    func show(_ id: String) {
        guard let runtime else { return }
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window: NSWindow
        switch id {
        case WindowID.main:
            window = makeWindow(
                id: id,
                title: "MyWhispr",
                size: CGSize(width: 1_020, height: 660),
                minSize: CGSize(width: 820, height: 520),
                resizable: true,
                root: MainWindow().environment(runtime)
            )
        case WindowID.setup:
            window = makeWindow(
                id: id,
                title: "Set Up MyWhispr",
                size: CGSize(width: 520, height: 640),
                minSize: CGSize(width: 520, height: 640),
                resizable: false,
                root: SetupWindow().environment(runtime)
            )
        case WindowID.settings:
            window = makeWindow(
                id: id,
                title: "MyWhispr Settings",
                size: CGSize(width: 820, height: 600),
                minSize: CGSize(width: 700, height: 460),
                resizable: true,
                root: SettingsWindow().environment(runtime)
            )
        default:
            return
        }
        windows[id] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    private func makeWindow<Root: View>(
        id: String,
        title: String,
        size: CGSize,
        minSize: CGSize,
        resizable: Bool,
        root: Root
    ) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        // Lets code that runs outside a view — key monitors, menu validation — ask
        // which surface is frontmost without matching on the localized title.
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Keeping the window alive across closes preserves scroll position and the
        // current selection, so reopening returns the owner where they left off.
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.delegate = self
        return window
    }
}

extension WindowCoordinator: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down: windows are intentionally retained so state survives
        // a close. This exists so the delegate relationship is explicit.
    }
}

extension WindowID {
    static let settings = "settings"
}
