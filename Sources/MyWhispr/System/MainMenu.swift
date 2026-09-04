import AppKit

extension Notification.Name {
    /// Posted by Edit ▸ Find. The main window's search field listens for it, which
    /// keeps the menu item working without the menu knowing anything about views.
    static let myWhisprFocusSearch = Notification.Name("app.mywhispr.mac.focusSearch")
    /// Routes a durable chat source into the Library without coupling the answer
    /// renderer to the main window's private navigation state.
    static let myWhisprOpenLibrary = Notification.Name("app.mywhispr.mac.openLibrary")
}

/// Builds and installs the application's main menu.
///
/// A menu-bar-only app still needs one. `LSUIElement` means the menus are never
/// drawn — MyWhispr does not own the menu bar — but `NSApplication` still routes
/// every key-down through `mainMenu.performKeyEquivalent(_:)` before the responder
/// chain sees it. With no main menu at all there are no key equivalents, so ⌘C, ⌘V,
/// ⌘A and ⌘Z do nothing in *any* text field the app shows: the transcript editor,
/// the meeting name, the search field, the local-AI prompts. Standard editing
/// commands are not a feature to be designed, they are the floor.
///
/// Items with a `nil` target are dispatched down the responder chain, which is also
/// what validates them — so Copy dims itself when nothing is selected without this
/// type knowing what a selection is.
@MainActor
final class MainMenuBuilder: NSObject {
    private let openWindow: (String) -> Void

    init(openWindow: @escaping (String) -> Void) {
        self.openWindow = openWindow
    }

    func install() {
        let main = NSMenu()
        main.addItem(applicationMenuItem())
        main.addItem(editMenuItem())
        main.addItem(windowMenuItem())
        NSApp.mainMenu = main
    }

    // MARK: - Menus

    private func applicationMenuItem() -> NSMenuItem {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)

        menu.addItem(
            withTitle: "About \(name)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let window = NSMenuItem(
            title: "\(name) Window",
            action: #selector(openMainWindow),
            keyEquivalent: "0"
        )
        window.target = self
        menu.addItem(window)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide \(name)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit \(name)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        menu.addItem(.separator())
        let find = NSMenuItem(title: "Find", action: #selector(focusSearch), keyEquivalent: "f")
        find.target = self
        menu.addItem(find)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        let item = NSMenuItem()
        item.submenu = menu
        // Handing the menu to AppKit lets it list open windows and check the active
        // one, which is the behaviour people expect from a Window menu.
        NSApp.windowsMenu = menu
        return item
    }

    // MARK: - Actions

    @objc private func openSettings() {
        openWindow(WindowID.settings)
    }

    @objc private func openMainWindow() {
        openWindow(WindowID.main)
    }

    @objc private func focusSearch() {
        // Find is meaningful even with no window open: the thing being searched is
        // the history, so open the window that shows it and then focus the field.
        openWindow(WindowID.main)
        NotificationCenter.default.post(name: .myWhisprFocusSearch, object: nil)
    }
}
