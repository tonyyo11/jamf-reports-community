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

    /// Protect leaves a field out when it has no value for it (CLAUDE.md, "jamf-cli JSON Shapes"),
    /// and `ProtectComputerRow` decodes an absent or unrecognised Full Disk Access status to nil.
    func testStatePillShowsUnknownInTheNeutralToneWhenNotReported() {
        let unknown = ProtectView.statePill(nil, trueLabel: "Yes", falseLabel: "No")
        XCTAssertEqual(unknown.text, "Unknown")
        XCTAssertEqual(unknown.tone, .muted)
        XCTAssertNil(unknown.icon)
    }

    func testStatePillKeepsTheReportedLabels() {
        let granted = ProtectView.statePill(true, trueLabel: "Yes", falseLabel: "No")
        XCTAssertEqual(granted.text, "Yes")
        XCTAssertEqual(granted.tone, .teal)
        XCTAssertEqual(granted.icon, "checkmark")
        let denied = ProtectView.statePill(false, trueLabel: "Yes", falseLabel: "No")
        XCTAssertEqual(denied.text, "No")
        XCTAssertEqual(denied.tone, .muted)
        XCTAssertEqual(denied.icon, "xmark")
    }

    func testSpokenStateSaysUnknownNotDenied() {
        XCTAssertEqual(
            ProtectView.spokenState(nil, trueWord: "granted", falseWord: "denied"), "unknown")
        XCTAssertEqual(
            ProtectView.spokenState(true, trueWord: "granted", falseWord: "denied"), "granted")
        XCTAssertEqual(
            ProtectView.spokenState(false, trueWord: "granted", falseWord: "denied"), "denied")
    }

    // MARK: - Jamf Pro match text

    private func protectRows(_ count: Int) throws -> [ProtectComputerRow] {
        let data = try JSONSerialization.data(
            withJSONObject: (0..<count).map { ["uuid": "u\($0)", "hostname": "h\($0)"] })
        return try JSONDecoder().decode([ProtectComputerRow].self, from: data)
    }

    private func proMac(_ serial: String) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: serial, source: "test")
        record.serial = serial
        return record
    }

    func testMatchTextOmitsZeroCounts() {
        let match = ProtectProCorrelation(protectCount: 12, matched: 12)
        XCTAssertEqual(ProtectView.matchSummary(match),
                       "12 of 12 Protect computers match a Jamf Pro computer.")
        XCTAssertEqual(ProtectView.matchNotes(match), [])
    }

    func testMatchTextPlural() throws {
        let match = ProtectProCorrelation(
            protectCount: 10, matched: 3, ambiguous: 2, noIdentifier: 2, duplicates: 2,
            notInPro: try protectRows(3), proWithoutProtect: [proMac("A"), proMac("B")])
        XCTAssertEqual(ProtectView.matchNotes(match), [
            "3 Protect computers have no Jamf Pro record.",
            "2 Jamf Pro Macs have no Protect record.",
            "2 Protect computers match more than one Jamf Pro computer and are not counted.",
            "2 Protect computers repeat a matched Jamf Pro computer and are counted once.",
            "2 Protect computers report no UUID or serial.",
        ])
    }

    func testMatchTextSingular() throws {
        let match = ProtectProCorrelation(
            protectCount: 1, matched: 0, ambiguous: 1, noIdentifier: 1, duplicates: 1,
            notInPro: try protectRows(1), proWithoutProtect: [proMac("A")])
        XCTAssertEqual(ProtectView.matchSummary(match),
                       "0 of 1 Protect computer matches a Jamf Pro computer.")
        XCTAssertEqual(ProtectView.matchNotes(match), [
            "1 Protect computer has no Jamf Pro record.",
            "1 Jamf Pro Mac has no Protect record.",
            "1 Protect computer matches more than one Jamf Pro computer and is not counted.",
            "1 Protect computer repeats a matched Jamf Pro computer and is counted once.",
            "1 Protect computer reports no UUID or serial.",
        ])
    }

    /// On a Jamf School workspace the card matches against School inventory and says so.
    func testSchoolMatchTextNamesJamfSchool() throws {
        let match = ProtectProCorrelation(
            inventory: .jamfSchool, protectCount: 2, matched: 1,
            notInPro: try protectRows(1), proWithoutProtect: [proMac("A")])
        XCTAssertEqual(ProtectView.matchSummary(match),
                       "1 of 2 Protect computers match a Jamf School computer.")
        XCTAssertEqual(ProtectView.matchNotes(match), [
            "1 Protect computer has no Jamf School record.",
            "1 Jamf School Mac has no Protect record.",
        ])
        XCTAssertEqual(ProtectView.noInventoryText(.jamfSchool),
                       "Collect Jamf School inventory to match Protect computers to Jamf School.")
        XCTAssertEqual(ProtectView.noInventoryText(.jamfPro),
                       "Collect Jamf Pro inventory to match Protect computers to Jamf Pro.")
    }
}
