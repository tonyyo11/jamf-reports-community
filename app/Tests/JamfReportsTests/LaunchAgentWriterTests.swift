import Foundation
import XCTest
@testable import JamfReports

final class LaunchAgentWriterTests: XCTestCase {
    private let prefix = LaunchAgentWriter.labelPrefix
    private let safeLaunchPath = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")

    func testLabelValidationMatchesPythonContract() {
        let valid = [
            "\(prefix).dummy",
            "\(prefix).dummy.daily",
            "\(prefix).harbor-edu_v2",
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

    func testTrustedJRCScriptRejectsSameBasenameOutsideAppCandidates() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fakeScript = tempRoot.appendingPathComponent("jamf-reports-community.py")
        try "#!/usr/bin/env python3\n".write(to: fakeScript, atomically: true, encoding: .utf8)

        XCTAssertFalse(LaunchAgentWriter.isTrustedJRCScript(fakeScript.path))
    }

    func testTrustedPythonExecutableRejectsNonexistentTrustedLookingPath() {
        XCTAssertFalse(
            LaunchAgentWriter.isTrustedPythonExecutable(
                "/opt/homebrew/Cellar/python@9.99/9.99.99/bin/python3"
            )
        )
    }

    func testLaunchEnvironmentIgnoresPlistControlledPathAndJamfCLIPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let safeXDGConfigHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let plist: [String: Any] = [
            "EnvironmentVariables": [
                "HOME": "/tmp/evil-home",
                "PATH": "/tmp/evil-bin",
                "JAMFCLI_PATH": "/tmp/evil-bin/jamf-cli",
                "PYTHONDONTWRITEBYTECODE": "0",
                "PYTHONHOME": "/tmp/evil-pythonhome",
                "PYTHONNOUSERSITE": "0",
                "PYTHONPATH": "/tmp/evil-pythonpath",
                "PYTHONUNBUFFERED": "0",
                "XDG_CONFIG_HOME": safeXDGConfigHome,
            ],
        ]

        let env = LaunchAgentWriter.launchEnvironment(from: plist)

        XCTAssertEqual(env["HOME"], home)
        XCTAssertEqual(env["PATH"], safeLaunchPath)
        XCTAssertEqual(env["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertEqual(env["PYTHONNOUSERSITE"], "1")
        XCTAssertEqual(env["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(env["XDG_CONFIG_HOME"], safeXDGConfigHome)
        XCTAssertNil(env["JAMFCLI_PATH"])
        XCTAssertNil(env["PYTHONHOME"])
        XCTAssertNil(env["PYTHONPATH"])
    }

    func testLaunchEnvironmentIgnoresUnsafeXDGConfigHome() {
        let plist: [String: Any] = [
            "EnvironmentVariables": [
                "XDG_CONFIG_HOME": "/tmp/evil-config",
            ],
        ]

        let env = LaunchAgentWriter.launchEnvironment(from: plist)

        XCTAssertNil(env["XDG_CONFIG_HOME"])
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
