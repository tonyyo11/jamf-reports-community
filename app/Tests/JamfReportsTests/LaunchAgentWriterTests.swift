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

    func testAutomationPathExpectationsMatchPythonGeneratedNames() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let label = "\(prefix).dummy.daily"

        XCTAssertTrue(
            LaunchAgentWriter.isExpectedConfigURL(
                root.appendingPathComponent("config.yaml"),
                root: root
            )
        )
        XCTAssertFalse(
            LaunchAgentWriter.isExpectedConfigURL(
                root.appendingPathComponent("alternate.yaml"),
                root: root
            )
        )

        let status = root
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("\(label)_status.json")
        XCTAssertEqual(LaunchAgentWriter.expectedStatusURL(label: label, root: root), status)
        XCTAssertTrue(LaunchAgentWriter.isExpectedStatusURL(status, label: label, root: root))
        XCTAssertFalse(
            LaunchAgentWriter.isExpectedStatusURL(
                root.appendingPathComponent("config.yaml"),
                label: label,
                root: root
            )
        )
    }

    func testTrustedJamfCLIExecutableRejectsTempBasename() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fakeJamfCLI = tempRoot.appendingPathComponent("jamf-cli")
        try "#!/bin/sh\nexit 0\n".write(to: fakeJamfCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeJamfCLI.path
        )

        XCTAssertFalse(LaunchAgentWriter.isTrustedJamfCLIExecutable(fakeJamfCLI.path))
    }

    /// M-01 fourth-site closure: even when a candidate `jamf-cli` matches the
    /// located path (via test seam), `isTrustedJamfCLIExecutable` must refuse
    /// it when the codesign gate rejects the binary. This is the same
    /// rejection `CLIBridge`'s codesign gate enforces at every jamf-cli
    /// spawn site.
    func testIsTrustedJamfCLIExecutableEnforcesCodesignGate() throws {
        JamfCLIIdentity.clearVerificationCacheForTesting()
        addTeardownBlock { JamfCLIIdentity.clearVerificationCacheForTesting() }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Unsigned fake binary basenamed `jamf-cli`. With the
        // _testLocatedOverride seam pinning the located URL to the same fake,
        // the path-identity guard passes, and the codesign gate must reject
        // the unsigned binary — returning false.
        let fakeJamfCLI = tempRoot.appendingPathComponent("jamf-cli")
        try Data("not-a-real-binary".utf8).write(to: fakeJamfCLI)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fakeJamfCLI.path
        )

        // Sanity-check the test fixture itself: the gate must refuse it.
        let direct = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: fakeJamfCLI)
        switch direct {
        case .success:
            XCTFail("Test setup invalid: unsigned fake jamf-cli passed verification")
        case .failure:
            break
        }

        XCTAssertFalse(
            LaunchAgentWriter.isTrustedJamfCLIExecutable(
                fakeJamfCLI.path,
                _testLocatedOverride: fakeJamfCLI
            ),
            "Path-identity match must not bypass the codesign gate"
        )
    }

    func testFilenameComponentMatchesPythonShapeForLaunchAgentLabels() {
        XCTAssertEqual(LaunchAgentWriter.filenameComponent("\(prefix).dummy"), "\(prefix).dummy")
        XCTAssertEqual(LaunchAgentWriter.filenameComponent(" bad/value  "), "bad_value")
        XCTAssertEqual(LaunchAgentWriter.filenameComponent("..."), "jamf_report")
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
