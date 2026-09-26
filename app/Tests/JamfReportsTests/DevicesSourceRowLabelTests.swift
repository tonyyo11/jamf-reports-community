import XCTest
@testable import JamfReports

@MainActor
final class DevicesSourceRowLabelTests: XCTestCase {

    func testSnapshotsOfDifferentKindsGetDifferentLabels() {
        let root = "~/Jamf-Reports/dummy/jamf-cli-data"
        let failures = DevicesView.sourceRowLabel(
            "\(root)/patch-device-failures/patch-device-failures_20260925T110340.json")
        let status = DevicesView.sourceRowLabel(
            "\(root)/patch-status/patch-status_20260925T110340.json")
        XCTAssertEqual(failures, "patch-device-failures_20260925T110340.json")
        XCTAssertEqual(status, "patch-status_20260925T110340.json")
    }

    func testCSVKeepsItsFilename() {
        XCTAssertEqual(
            DevicesView.sourceRowLabel(
                "~/Jamf-Reports/meridian-prod/Generated Reports/inventory_2026-04-25.csv"),
            "inventory_2026-04-25.csv")
    }

    func testBareNameIsReturnedUnchanged() {
        XCTAssertEqual(DevicesView.sourceRowLabel("computers.json"), "computers.json")
        XCTAssertEqual(DevicesView.sourceRowLabel(""), "")
    }
}
