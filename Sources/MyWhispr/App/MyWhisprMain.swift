import Darwin
import SwiftUI

/// Selects the process surface before AppKit starts.
///
/// With no arguments this is the ordinary menu-bar application. Supplying an
/// argument turns the same binary into a finite command-line process, which avoids
/// starting hotkeys, permissions, windows, or the application database merely to
/// transcribe a file.
@main
enum MyWhisprMain {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments
        if CommandLineInterface.isInvocation(arguments) {
            let status = await CommandLineInterface.run(arguments: arguments)
            if status != 0 { exit(status) }
            return
        }

        MyWhisprApp.main()
    }
}
