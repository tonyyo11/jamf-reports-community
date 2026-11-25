import XCTest
@testable import JamfReports

final class DeploymentHealthTests: XCTestCase {

    private let levels = DeploymentHealth.Levels.defaults

    private func app(
        _ id: String = "1", name: String? = "App", enabled: Bool? = true, failed: Int? = 0,
        inScope: Int? = 100, deployed: String? = "1.0", latest: String? = "1.0",
        behavior: String? = "AUTOMATIC"
    ) -> DeploymentHealth.Row {
        .init(source: .appInstallers, id: id, name: name, enabled: enabled, failed: failed,
              inScope: inScope, assignedElsewhere: 0, deployedVersion: deployed,
              latestVersion: latest, updateBehavior: behavior, completed: nil, deferred: nil,
              pending: nil, targetVersion: nil, softwareTitle: nil)
    }

    // MARK: - Judging

    func testTheRulesApplyInOrder() {
        XCTAssertEqual(DeploymentHealth.judge(app(enabled: false, failed: nil), levels: levels),
                       .notJudged, "not enabled wins over a missing count")
        XCTAssertEqual(DeploymentHealth.judge(app(enabled: nil), levels: levels), .notJudged)
        XCTAssertEqual(DeploymentHealth.judge(app(failed: nil), levels: levels), .unmeasured)
        XCTAssertEqual(DeploymentHealth.judge(app(inScope: 0), levels: levels), .nothingInScope)
        XCTAssertEqual(DeploymentHealth.judge(app(failed: 9, inScope: 9), levels: levels),
                       .belowMinimumScope, "9 of 9 is under the 10-Mac floor")
        XCTAssertEqual(DeploymentHealth.judge(app(failed: 9, inScope: 100), levels: levels),
                       .belowLevels)
    }

    func testExactlyALevelIsAtThatLevel() {
        XCTAssertEqual(DeploymentHealth.judge(app(failed: 10, inScope: 100), levels: levels),
                       .warning)
        XCTAssertEqual(DeploymentHealth.judge(app(failed: 24, inScope: 100), levels: levels),
                       .warning)
        XCTAssertEqual(DeploymentHealth.judge(app(failed: 25, inScope: 100), levels: levels),
                       .critical)
        XCTAssertEqual(DeploymentHealth.judge(app(failed: 1, inScope: 10), levels: levels),
                       .warning, "10 Macs is enough to be judged")
    }

    func testAtLevelIsCriticalFirstThenShareThenName() {
        let rows = [
            app("1", name: "B", failed: 12, inScope: 100),
            app("2", name: "A", failed: 12, inScope: 100),
            app("3", name: "C", failed: 30, inScope: 100),
            app("4", name: "D", failed: 20, inScope: 100),
            app("5", name: "E", failed: 1, inScope: 100),
        ]
        XCTAssertEqual(DeploymentHealth.atLevel(rows, levels: levels).map(\.row.id),
                       ["3", "4", "2", "1"])
    }

    func testFiguresCountJudgedAndAtLevelRows() {
        let figures = DeploymentHealth.figures([
            app(failed: 30), app(failed: 12), app(failed: 1), app(enabled: false),
            app(inScope: 0),
        ], levels: levels)
        XCTAssertEqual(figures, .init(judged: 3, atWarning: 1, atCritical: 1))
    }

    func testVersionsArePinnedLaggingOrUnknown() {
        XCTAssertEqual(DeploymentHealth.versionState(app()), .same)
        XCTAssertEqual(DeploymentHealth.versionState(app(deployed: "1.0", latest: "2.0",
                                                         behavior: "MANUAL")), .pinned)
        XCTAssertEqual(DeploymentHealth.versionState(app(deployed: "1.0", latest: "2.0")),
                       .lagging)
        XCTAssertEqual(DeploymentHealth.versionState(app(deployed: " ", latest: "2.0")), .unknown)
    }

    func testANameIsShownOrMarkedMissing() {
        XCTAssertEqual(app(name: nil).displayName, "(no name)")
        XCTAssertEqual(app(name: "").displayName, "(no name)")
    }

    // MARK: - Rows from a snapshot

    func testRowsReadTheReducedShapeAndLeaveOutUnqualified() throws {
        let data = try Data(contentsOf: TestFixtures.dir(
            "deployment-health/app-installers-deployments-list.json"))
        let reduced = try XCTUnwrap(DeploymentSourceReduction.reduce(
            kind: "app-installers-deployments", payload: data))
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: reduced) as? [[String: Any]])
        let row = try XCTUnwrap(DeploymentHealth.row(.appInstallers, list[0]))
        XCTAssertEqual(row.failed, 40)
        XCTAssertEqual(row.inScope, 400, "installed 360 + failed 40; unqualified is apart")
        XCTAssertEqual(row.assignedElsewhere, 12)
        XCTAssertNil(DeploymentHealth.row(.appInstallers, ["name": "no id"]))
        let partial = try XCTUnwrap(DeploymentHealth.row(.patchPolicy, [
            "id": "9", "policyEnabled": true, "failed": 1, "completed": 5, "deferred": 0,
        ]))
        XCTAssertNil(partial.inScope, "pending is missing, so the row is unmeasured")
    }

    // MARK: - Source states

    private func dataDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-deploy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ text: String, kind: String, in dir: URL,
                       stamp: String = "20261125T120000") throws {
        let kindDir = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        try text.write(to: kindDir.appendingPathComponent("\(kind)_\(stamp).json"),
                       atomically: true, encoding: .utf8)
    }

    func testEachSourceStateIsTold() throws {
        let dir = try dataDir()
        var states = DeploymentHealth.load(dataDir: dir)
        XCTAssertEqual(states[.appInstallers], .notCollected)

        try write("[]", kind: "patch-policies", in: dir)
        try write("not json", kind: "app-installers-deployments", in: dir)
        states = DeploymentHealth.load(dataDir: dir)
        XCTAssertEqual(states[.patchPolicy], .rows([], asOf: nil, leftOut: 0))
        XCTAssertEqual(DeploymentHealth.stateText(states[.patchPolicy]!), "None on this server")
        XCTAssertEqual(states[.appInstallers], .unreadable)
    }

    func testNotSetUpComesFromTheStateFiles() throws {
        let dir = try dataDir()
        StateFileStore(directory: dir.appendingPathComponent("state")).record(
            .failed(exitCode: 4), report: "app-installers-deployments", at: Date(),
            cause: FailureCause(kind: .notConfiguredOnServer, names: [], hint: nil, exitCode: 4))
        XCTAssertEqual(DeploymentHealth.load(dataDir: dir)[.appInstallers], .notSetUp)
    }

    func testAPlantedNewestFileIsUnreadable() throws {
        let dir = try dataDir()
        let kindDir = dir.appendingPathComponent("patch-policies", isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: kindDir.appendingPathComponent("patch-policies_20261125T120000.json"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertEqual(DeploymentHealth.load(dataDir: dir)[.patchPolicy], .unreadable)
    }

    func testAnOldSnapshotIsMarkedAsOf() throws {
        let dir = try dataDir()
        try write(#"[{"id":"1","policyEnabled":true,"completed":1,"deferred":0,"failed":0,"pending":0}]"#,
                  kind: "patch-policies", in: dir, stamp: "20261101T120000")
        let now = ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")!
        guard case .rows(_, let asOf, _) = DeploymentHealth.load(
            dataDir: dir, now: now, maxAgeHours: 168)[.patchPolicy] else {
            return XCTFail("rows expected")
        }
        XCTAssertNotNil(asOf)
        guard case .rows(_, let fresh, _) = DeploymentHealth.load(
            dataDir: dir, now: now, maxAgeHours: nil)[.patchPolicy] else {
            return XCTFail("rows expected")
        }
        XCTAssertNil(fresh, "no age rule configured")
    }
}

/// `thresholds.deployment_failure_*_percent`: one resolver, which Config Doctor reports.
final class DeploymentLevelsConfigTests: XCTestCase {

    private func levels(_ yaml: String) throws -> DeploymentHealth.Levels {
        try ConfigLoader.loadFromString(yaml).thresholds?.resolvedDeploymentLevels ?? .defaults
    }

    func testTheResolver() throws {
        XCTAssertEqual(try levels("thresholds: {}\n"), .defaults)
        XCTAssertEqual(try levels("thresholds:\n  deployment_failure_warning_percent: 5\n"),
                       .init(warning: 5, critical: 25))
        XCTAssertEqual(try levels("thresholds:\n  deployment_failure_warning_percent: 150\n"
                                  + "  deployment_failure_critical_percent: 40\n"),
                       .init(warning: 10, critical: 40), "only the bad value falls back")
        XCTAssertEqual(try levels("thresholds:\n  deployment_failure_warning_percent: \"ten\"\n"),
                       .defaults)
        XCTAssertEqual(try levels("thresholds:\n  deployment_failure_warning_percent: 30\n"
                                  + "  deployment_failure_critical_percent: 20\n"),
                       .defaults, "an inverted pair takes both defaults")
        XCTAssertEqual(try levels("thresholds:\n  deployment_failure_warning_percent: 20\n"
                                  + "  deployment_failure_critical_percent: 20\n"),
                       .init(warning: 20, critical: 20))
    }

    func testDoctorReportsWhatTheResolverUses() throws {
        let yaml = "thresholds:\n  deployment_failure_warning_percent: 30\n"
            + "  deployment_failure_critical_percent: 0\n"
        let config = try ConfigLoader.loadFromString(yaml)
        let rows = ConfigDoctorService.valueRows(
            config, raw: try ConfigLoader.rawMapping(fromYAML: yaml), workspace: nil,
            profile: "ws")
        let range = rows.first { $0.title == "thresholds.deployment_failure_critical_percent" }
        XCTAssertNotNil(range, "0 is out of range")
        let order = rows.first {
            $0.title == "thresholds.deployment_failure_warning_percent"
                && $0.detail.contains("above the critical level")
        }
        XCTAssertNotNil(order, "30 against the default 25 is inverted")
        XCTAssertTrue(order?.detail.contains("warning 10% and critical 25%") ?? false)
    }
}
