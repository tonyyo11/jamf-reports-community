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
    /// it when the codesign gate rejects the binary. This is the rejection the
    /// legacy multi runMultiNow path now enforces (via
    /// `multiProgramArgumentsAreTrusted` → `isTrustedJamfCLIExecutable`),
    /// closing the 4th spawn site identified in the M-01 review.
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
                "XDG_CONFIG_HOME": safeXDGConfigHome,
            ],
        ]

        let env = LaunchAgentWriter.launchEnvironment(from: plist)

        XCTAssertEqual(env["HOME"], home)
        XCTAssertEqual(env["PATH"], safeLaunchPath)
        XCTAssertEqual(env["XDG_CONFIG_HOME"], safeXDGConfigHome)
        XCTAssertNil(env["JAMFCLI_PATH"])
        // Python env vars must not be injected into native-only launch environments.
        XCTAssertNil(env["PYTHONDONTWRITEBYTECODE"])
        XCTAssertNil(env["PYTHONNOUSERSITE"])
        XCTAssertNil(env["PYTHONUNBUFFERED"])
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

    func testExpectedMultiLogURLRejectsSymlinkedLogFile() throws {
        let label = "\(prefix).multi.\(UUID().uuidString.lowercased())"
        let logURL = LaunchAgentWriter.expectedMultiLogURL(label: label, filename: "stdout.log")
        let logDir = logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }

        XCTAssertTrue(
            LaunchAgentWriter.isExpectedMultiLogURL(logURL, label: label, filename: "stdout.log")
        )

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let outside = tempRoot.appendingPathComponent("outside.log")
        try "outside\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: logURL, withDestinationURL: outside)

        XCTAssertFalse(
            LaunchAgentWriter.isExpectedMultiLogURL(logURL, label: label, filename: "stdout.log")
        )
    }

    // MARK: - nativeSingleWrite structural test

    func testNativeSingleWrite_plistContentIsCorrect() throws {
        let sched = schedule(name: "Test-Native-Write")
        guard let agentLabel = LaunchAgentWriter.label(for: sched) else {
            XCTFail("Expected a valid label for schedule")
            return
        }

        let plan = try LaunchAgentWriter.nativeSingleWrite(for: sched, load: false)
        defer {
            // Clean up: remove the plist and any log directory created.
            try? FileManager.default.removeItem(at: plan.plistURL)
            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/JamfReports/\(agentLabel)", isDirectory: true)
            try? FileManager.default.removeItem(at: logDir)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plan.plistURL.path),
            "plist must exist after nativeSingleWrite"
        )

        let data = try Data(contentsOf: plan.plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]

        let args = plist["ProgramArguments"] as? [String]
        XCTAssertNotNil(args, "ProgramArguments must be present")
        XCTAssertTrue(args?.contains("--scheduled-run") == true,
                      "ProgramArguments must contain --scheduled-run")
        XCTAssertTrue(args?.contains("--profile") == true,
                      "ProgramArguments must contain --profile")
        XCTAssertTrue(args?.contains("dummy") == true,
                      "ProgramArguments must contain the profile name")
        // Profile name must follow --profile flag
        if let args, let profileIdx = args.firstIndex(of: "--profile") {
            XCTAssertTrue(profileIdx + 1 < args.count, "--profile must have a following value")
            XCTAssertEqual(args[profileIdx + 1], "dummy")
        }

        let runAtLoad = plist["RunAtLoad"] as? Bool
        XCTAssertEqual(runAtLoad, false, "RunAtLoad must be false")

        let disabled = plist["Disabled"] as? Bool
        XCTAssertEqual(disabled, true, "Disabled must be true when load: false")

        XCTAssertEqual(plan.label, agentLabel)
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

    // MARK: - WorkingDirectory contract (Phase: schedule fix 9804b69, 5d69c28)

    /// Self-heal contract: a missing key returns true; the caller substitutes
    /// `ProfileService.workspacesRoot()`. Locks behavior for pre-existing plists.
    func testIsExpectedMultiWorkingDirectoryAcceptsNil() {
        XCTAssertTrue(LaunchAgentWriter.isExpectedMultiWorkingDirectory(nil))
    }

    func testIsExpectedMultiWorkingDirectoryAcceptsCanonicalRoot() {
        let root = ProfileService.workspacesRoot().path
        XCTAssertTrue(LaunchAgentWriter.isExpectedMultiWorkingDirectory(root))
    }

    func testIsExpectedMultiWorkingDirectoryRejectsWrongPath() {
        XCTAssertFalse(LaunchAgentWriter.isExpectedMultiWorkingDirectory("/tmp/wrong"))
        XCTAssertFalse(LaunchAgentWriter.isExpectedMultiWorkingDirectory("/Users/elsewhere"))
    }

    func testIsExpectedMultiWorkingDirectoryRejectsMalformedPath() {
        // Non-absolute paths and empty strings must be rejected.
        XCTAssertFalse(LaunchAgentWriter.isExpectedMultiWorkingDirectory(""))
    }

    /// Round-trip: `nativeMultiWrite` must persist `WorkingDirectory` so a
    /// future `runMultiNow` validates without the self-heal branch.
    func testNativeMultiWritePersistsWorkingDirectory() throws {
        let scheduleObj = schedule(name: "Test-Multi-WorkingDir")
        guard let agentLabel = LaunchAgentWriter.label(for: scheduleObj) else {
            XCTFail("Expected a valid label for schedule")
            return
        }
        let tempExec = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-jamf-reports-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempExec.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: tempExec.path
        )
        defer { try? FileManager.default.removeItem(at: tempExec) }

        let plan = try LaunchAgentWriter.nativeMultiWrite(
            for: scheduleObj,
            executableURL: tempExec,
            load: false
        )
        defer {
            try? FileManager.default.removeItem(at: plan.plistURL)
            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/JamfReports/\(agentLabel)", isDirectory: true)
            try? FileManager.default.removeItem(at: logDir)
        }

        let data = try Data(contentsOf: plan.plistURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: Any] else {
            return XCTFail("plist did not deserialize as dictionary")
        }
        let workingDir = plist["WorkingDirectory"] as? String
        XCTAssertEqual(workingDir, ProfileService.workspacesRoot().path)
        XCTAssertTrue(LaunchAgentWriter.isExpectedMultiWorkingDirectory(workingDir))
    }
}
