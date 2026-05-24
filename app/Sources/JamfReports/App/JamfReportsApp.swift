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
                    // `swift run` subprocesses launched from Terminal do not
                    // always get foreground activation, so TextField never
                    // becomes first responder and keystrokes drop while
                    // clicks (which don't need key-window status) still
                    // register. Launch Services-launched .app bundles
                    // activate automatically.
                    //
                    // setActivationPolicy(.regular) is the key piece for the
                    // SwiftPM-launched binary path — without an Info.plist
                    // declaring LSUIElement=false, the launcher may infer
                    // an inactive policy and `activate()` alone won't
                    // promote it to foreground. `.regular` is the default
                    // for bundled apps so this is a no-op there. The
                    // makeKeyAndOrderFront on the first window covers
                    // multi-window scenes where the activation lands but
                    // the window isn't key.
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
