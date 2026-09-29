// App — thin macOS SwiftUI shell.
//
// Nearly all logic lives in the local Swift packages; this target is intentionally a thin shell
// (R-BUILD-1.2). It depends on GamesUI, Persistence, and DesignSystem (design.md §1) and is built via
// the XcodeGen-generated Xcode project (project.yml; R-BUILD-1.3), never by SwiftPM.
//
// The empty window, menu-bar skeleton, logging, and debug overlay hook are added in task 1.5. This
// scaffold provides the minimal `App` entry point so the generated project builds.

import SwiftUI

@main
struct ParlorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Minimum window 1024×700 (R-APP-6.4); enforced fully in task 1.5.
                .frame(minWidth: 1024, minHeight: 700)
        }
    }
}

struct ContentView: View {
    var body: some View {
        // Placeholder content; the real empty-window shell + menu bar land in task 1.5.
        Text("Parlor")
            .font(.largeTitle)
            .padding()
    }
}
