import AppKit
import SwiftUI

// Entry point lives in main.swift (top-level code) which dispatches to either
// the SwiftUI UI path or the --scheduled-run / --check CLI paths. The @main
// attribute on this App struct conflicts with main.swift's top-level code.
struct JamfReportsApp: App {
    /// Narrowest supported window width (points). 960 satisfies WCAG 1.4.10
    /// Reflow at 200% Dynamic Type and lets the app run on a 13" MacBook.
    /// Update `ResponsiveLayoutTests` if this constant changes.
    static let minSupportedWidth: CGFloat = 960
    @State private var workspace = WorkspaceStore()

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workspace)
                .frame(minWidth: Self.minSupportedWidth, minHeight: 760)
                .preferredColorScheme(.dark)
                .task {
                    // `swift run` dev binaries don't auto-activate, so TextField
                    // never becomes first responder and keystrokes drop. Promote
                    // to `.regular` and key the first window. No-op for
                    // Launch-Services-launched .app bundles.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
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

                Divider()

                CheckForUpdatesView()
                AcknowledgementsMenuButton()
            }
        }

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .windowResizability(.contentSize)
    }
}

extension Notification.Name {
    static let cycleSidebar = Notification.Name("JamfReports.cycleSidebar")
    static let navigateToTab = Notification.Name("JamfReports.navigateToTab")
    static let refreshActiveTab = Notification.Name("JamfReports.refreshActiveTab")
    static let focusSearch = Notification.Name("JamfReports.focusSearch")
    static let popToRootNavigation = Notification.Name("JamfReports.popToRootNavigation")
}
