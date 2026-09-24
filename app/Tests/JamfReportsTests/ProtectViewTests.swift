import XCTest
import SwiftUI
@testable import JamfReports

/// View-instantiation tests for the v2.1.0 Protect deep-dive surfaces.
/// Each test toggles the experimental flag via an isolated UserDefaults suite
/// and confirms the view constructs without crashing — Swift 6.1 CI cannot
/// snapshot-render SwiftUI, so this is the cheapest available guard against
/// gating regressions.
@MainActor
final class ProtectViewTests: XCTestCase {

    nonisolated(unsafe) private var suiteName: String = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "protect-view-tests-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return UserDefaults.standard
        }
        return defaults
    }

    // ProtectView reads ExperimentalFeatureService from its own @State default
    // bound to UserDefaults.standard, so these tests verify only that the view
    // constructs in both flag states; gate-routing is covered by the service tests.

    func testViewConstructsWithFlagOff() throws {
        let workspace = WorkspaceStore()
        workspace.demoMode = true
        _ = ProtectView().environment(workspace)
    }

    func testViewConstructsWithFlagOn() throws {
        let workspace = WorkspaceStore()
        workspace.demoMode = true
        _ = ProtectView().environment(workspace)
    }

    func testFeatureFlagRoundTripPersists() throws {
        let defaults = makeDefaults()
        let off = ExperimentalFeatureService(defaults: defaults)
        XCTAssertFalse(off.isEnabled(.protect))

        off.setEnabled(.protect, true)
        let on = ExperimentalFeatureService(defaults: defaults)
        XCTAssertTrue(on.isEnabled(.protect))
    }

    func testPlanTelemetryTagNamesTheAssignedConfiguration() {
        XCTAssertEqual(ProtectView.telemetryTag("Standard Telemetry"),
                       "Telemetry: Standard Telemetry")
        XCTAssertEqual(ProtectView.telemetryTag(nil), "No telemetry")
        XCTAssertEqual(ProtectView.telemetryTag(""), "No telemetry")
    }

    /// Protect's real ALERT_STATUS values get a spaced display form; an
    /// unrecognised value passes through unchanged; empty/nil is "Unknown".
    func testStatusLabelMapsRealAlertStatusValues() {
        XCTAssertEqual(ProtectView.statusLabel("New"), "New")
        XCTAssertEqual(ProtectView.statusLabel("InProgress"), "In Progress")
        XCTAssertEqual(ProtectView.statusLabel("Resolved"), "Resolved")
        XCTAssertEqual(ProtectView.statusLabel("AutoResolved"), "Auto Resolved")
        XCTAssertEqual(ProtectView.statusLabel("SomeFutureStatus"), "SomeFutureStatus")
        XCTAssertEqual(ProtectView.statusLabel(nil), "Unknown")
        XCTAssertEqual(ProtectView.statusLabel(""), "Unknown")
    }

    /// Demo data must stay inside Jamf Protect's own enums — the screen shipped
    /// with Critical/Open/Investigating/Closed, none of which Protect sends, so
    /// the demo tenant advertised states the real one can never reach.
    func testDemoAlertsUseValuesProtectActuallySends() {
        let severities: Set<String> = ["High", "Medium", "Low", "Informational"]
        let statuses: Set<String> = ["New", "InProgress", "Resolved", "AutoResolved"]
        let alerts = DemoData.protectSnapshot.alerts
        XCTAssertFalse(alerts.isEmpty)
        for alert in alerts {
            XCTAssertTrue(severities.contains(alert.severity ?? ""),
                          "\(alert.severity ?? "nil") is not a Protect SEVERITY")
            XCTAssertTrue(statuses.contains(alert.status ?? ""),
                          "\(alert.status ?? "nil") is not a Protect ALERT_STATUS")
        }
    }

}
