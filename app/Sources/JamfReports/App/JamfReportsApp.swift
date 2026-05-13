import SwiftUI
import Sparkle

// Entry point lives in main.swift (top-level code) which dispatches to either
// the SwiftUI UI path or the --scheduled-run / --check CLI paths. The @main
// attribute on this App struct conflicts with main.swift's top-level code.
struct JamfReportsApp: App {
    /// Narrowest supported window width (points). 960 satisfies WCAG 1.4.10
    /// Reflow at 200% Dynamic Type and lets the app run on a 13" MacBook.
    /// Update `ResponsiveLayoutTests` if this constant changes.
    static let minSupportedWidth: CGFloat = 960
    @State private var workspace = WorkspaceStore()

    /// Sparkle updater — single shared instance for the app's lifetime.
    /// Configuration (SUFeedURL + SUPublicEDKey) lives in Info.plist set by
    /// `build-app.sh`. See ADR-W23-sparkle-integration.md.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workspace)
                .frame(minWidth: Self.minSupportedWidth, minHeight: 760)
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

                Divider()

                CheckForUpdatesView(updater: updaterController.updater)
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
