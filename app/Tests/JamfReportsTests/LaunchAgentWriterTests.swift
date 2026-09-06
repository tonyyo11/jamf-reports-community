import Foundation
import XCTest
@testable import JamfReports

final class LaunchAgentWriterTests: XCTestCase {
    private let prefix = LaunchAgentWriter.labelPrefix

    func testLabelValidationMatchesPythonContract() {
        let valid = [
            "\(prefix).dummy",
            "\(prefix).dummy.daily",
            "\(prefix).fixture-edu_v2",
            "\(prefix).school-test.weekly-mon",
        ]
        for label in valid {
            XCTAssertTrue(LaunchAgentWriter.isValidLabel(label), label)
        }

        let invalid = [
            "\(prefix).Dummy",
            "\(prefix).DAILY",
            "\(prefix).dummy.",
            "\(prefix).dummy..weekly",
            "\(prefix).dummy daily",
            "\(prefix).dummy/weekly",
            "com.example.other.dummy",
            prefix,
            "\(prefix).",
            "  \(prefix).dummy  ",
        ]
        for label in invalid {
            XCTAssertFalse(LaunchAgentWriter.isValidLabel(label), label)
        }
    }

    func testLabelGenerationRevalidatesCandidateLabel() {
        let normal = schedule(name: "Daily Snapshot")
        XCTAssertEqual(
            LaunchAgentWriter.label(for: normal),
            "\(prefix).dummy.daily-snapshot"
        )

        XCTAssertNil(LaunchAgentWriter.label(for: schedule(name: "daily.")))
        XCTAssertNil(LaunchAgentWriter.label(for: schedule(name: "daily..snapshot")))
    }

    private func schedule(name: String) -> Schedule {
        Schedule(
            name: name,
            profile: "dummy",
            schedule: "Daily 07:00",
            cadence: "daily",
            mode: .jamfCLIOnly,
            next: "-",
            last: "-",
            lastStatus: .ok,
            artifacts: [],
            enabled: true
        )
    }
}
