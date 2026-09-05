import XCTest
@testable import JamfReports

final class ScheduleConsolidationTests: XCTestCase {
    private let prefix = LaunchAgentWriter.labelPrefix

    private func schedule(_ label: String, profile: String = "alpha") -> Schedule {
        Schedule(
            name: label.components(separatedBy: ".").last ?? label, profile: profile,
            schedule: "Daily 06:20", cadence: "custom", mode: .jamfCLIFull, next: "—",
            last: "—", lastStatus: .ok, artifacts: [], enabled: true, launchAgentLabel: label)
    }

    func testOnlyImportedPlistsStillOnDiskAreCandidates() {
        let imported = schedule("\(prefix).alpha.nightly")
        let notImported = schedule("\(prefix).alpha.weird")
        let managed = schedule("\(prefix).multi.managed-scan", profile: "")
        let out = ScheduleConsolidation.stillLoaded(
            installed: [imported, notImported, managed],
            storeLabels: ["\(prefix).alpha.nightly"])
        XCTAssertEqual(out.map(\.label), ["\(prefix).alpha.nightly"])
        XCTAssertEqual(out.first?.coveredBy, "the JamfReports background item")
    }

    func testNoPlistsNoCandidates() {
        XCTAssertTrue(ScheduleConsolidation.stillLoaded(installed: [], storeLabels: ["x"]).isEmpty)
    }
}
