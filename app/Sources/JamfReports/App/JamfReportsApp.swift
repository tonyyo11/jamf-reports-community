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

            CommandGroup(after: .newItem) {
                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshActiveTab, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Find...") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button(workspace.demoMode ? "Disable Demo Mode" : "Enable Demo Mode") {
                    workspace.setDemoMode(!workspace.demoMode)
                }
                .keyboardShortcut("d", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let cycleSidebar = Notification.Name("JamfReports.cycleSidebar")
    static let navigateToTab = Notification.Name("JamfReports.navigateToTab")
    static let refreshActiveTab = Notification.Name("JamfReports.refreshActiveTab")
    static let focusSearch = Notification.Name("JamfReports.focusSearch")
}
