import SwiftUI

@main
struct JamfReportsApp: App {
    @State private var workspace = WorkspaceStore()

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workspace)
                .frame(minWidth: 1200, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // ⌘0 cycles the sidebar — a HIG-shaped affordance the prototype calls out.
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Cycle Sidebar") {
                    NotificationCenter.default.post(name: .cycleSidebar, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let cycleSidebar = Notification.Name("JamfReports.cycleSidebar")
}
