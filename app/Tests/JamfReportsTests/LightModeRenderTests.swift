import XCTest
import SwiftUI
import AppKit
@testable import JamfReports

/// Smoke tests for the Phase 8 light-mode token migration.
/// Dynamic-color *resolution* across appearances is covered by `ThemeLightModeTests`
/// using `NSAppearance.performAsCurrentDrawingAppearance`. Mutating `NSApp.appearance`
/// in xctest is unreliable (the test runner's NSApplication is a placeholder), so we
/// don't try here. These tests just confirm the views and shared chrome components
/// instantiate without crashing after the sweep.
@MainActor
final class LightModeRenderTests: XCTestCase {

    func testMajorViewsInstantiate() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = true

        _ = OverviewView().environment(workspace)
        _ = DevicesView().environment(workspace)
        _ = TrendsView().environment(workspace)
        _ = ReportsView().environment(workspace)
        _ = ConfigView().environment(workspace)
        _ = SchedulesView().environment(workspace)
        _ = BackupsView().environment(workspace)
        _ = SourcesView().environment(workspace)
        _ = CustomizeView().environment(workspace)
        _ = FleetOverviewView().environment(workspace)
        _ = RunsView().environment(workspace)
        _ = SettingsView().environment(workspace)
    }

    func testComponentsInstantiate() throws {
        _ = Kicker(text: "TEST")
        _ = PageHeader(kicker: "TEST", title: "Test Page")
        _ = Card { Text("Test content") }
        _ = StatTile(label: "Test", value: "123")
        _ = Pill(text: "Test")
        _ = PNPButton(title: "Test")
        _ = PNPToggle(isOn: .constant(false))
        _ = StatusBar(status: "Ready")

        _ = Kicker(text: "TEST", tone: .muted)
        _ = Pill(text: "TEST", tone: .gold)
        _ = PNPButton(title: "TEST", style: .gold)
    }
}
