import AppKit
import Observation
import SwiftUI

/// Owns the single ``AppRuntime``, the windows, and the one-time startup sequence.
///
/// The runtime opens a database, installs a system-wide event tap, and registers
/// global hotkeys, so it is built exactly once at launch by the app delegate rather
/// than lazily by whichever view happens to appear first. That distinction is not
/// cosmetic in a menu-bar app: MyWhispr can launch with no window at all, so
/// anything hung off a window's lifecycle would simply never run.
@MainActor
@Observable
final class AppBootstrap {
    static let shared = AppBootstrap()

    private(set) var runtime: AppRuntime?
    private(set) var failure: String?

    @ObservationIgnored let windows = WindowCoordinator()
    @ObservationIgnored private var menu: MainMenuBuilder?

    private init() {}

    func start() {
        guard runtime == nil, failure == nil else { return }

        // Installed before anything can show a window, so the first window to open
        // already has working editing commands.
        let menu = MainMenuBuilder { [windows] id in windows.show(id) }
        menu.install()
        self.menu = menu

        do {
            let created = try AppRuntime()
            windows.attach(runtime: created)
            created.openWindowHandler = { [windows] id in windows.show(id) }
            created.closeWindowHandler = { [windows] id in windows.close(id) }
            created.start()
            runtime = created

            // First run, or a permission that was granted and later revoked. Either
            // way the owner cannot dictate, and setup is the one screen that fixes it.
            if !created.settings.payload.hasCompletedSetup || !created.permissions.dictationReady {
                windows.show(WindowID.setup)
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppBootstrap.shared.start()
        }
    }

    /// Closing every window must not quit a menu-bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking a Dock icon, when the owner has opted into one, reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !hasVisibleWindows {
                AppBootstrap.shared.windows.show(WindowID.main)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // A meeting in progress is closed cleanly so its two tracks are finalised
            // rather than left for interruption recovery on the next launch.
            AppBootstrap.shared.runtime?.prepareForTermination()
        }
    }
}

struct MyWhisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var bootstrap = AppBootstrap.shared

    var body: some Scene {
        // The menu bar is the whole scene graph. Every other surface is an AppKit
        // window owned by `WindowCoordinator`, which is what lets a global hotkey or
        // the app delegate open one without a view to ask.
        MenuBarExtra {
            if let runtime = bootstrap.runtime {
                MenuBarPanel()
                    .environment(runtime)
            } else {
                StartupFailureView(message: bootstrap.failure)
            }
        } label: {
            if let runtime = bootstrap.runtime {
                MenuBarLabel(runtime: runtime)
            } else {
                Image(systemName: "waveform.badge.exclamationmark")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Shown when the store cannot be opened — the only failure that prevents startup.
struct StartupFailureView: View {
    var message: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.trianglebadge.exclamationmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.danger)
            Text("MyWhispr could not open its storage")
                .font(.system(size: 14, weight: .semibold))
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.glass)
        }
        .padding(28)
        .frame(minWidth: 300)
    }
}
