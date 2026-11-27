import XCTest
@testable import JamfReports

/// Boundaries the 2.13 mutation sweep found unpinned: the sort's tie-breaks, the reader's count and
/// flag rules, the state files and the age rule.
final class DeploymentHealthBoundaryTests: XCTestCase {

    private let levels = DeploymentHealth.Levels.defaults

    private func policy(
        _ id: String, name: String? = "P", enabled: Bool? = true, failed: Int? = 0,
        inScope: Int? = 100
    ) -> DeploymentHealth.Row {
        .init(source: .patchPolicy, id: id, name: name, enabled: enabled, failed: failed,
              inScope: inScope, assignedElsewhere: nil, deployedVersion: nil,
              latestVersion: nil, updateBehavior: nil, completed: nil, deferred: nil,
              pending: nil, targetVersion: nil, softwareTitle: nil)
    }

    // MARK: - Shares and order

    func testNothingInScopeHasNoShare() {
        let row = policy("1", failed: 0, inScope: 0)
        XCTAssertNil(DeploymentHealth.share(row))
        XCTAssertEqual(DeploymentHealth.shareText(row, levels: levels, format: .standard), "")
    }

    func testAShareBelowTheLevelsNeverRoundsOntoWarning() {
        let row = policy("1", failed: 996, inScope: 10_000)
        XCTAssertEqual(DeploymentHealth.judge(row, levels: levels), .belowLevels)
        let text = DeploymentHealth.shareText(row, levels: levels, format: .standard)
        XCTAssertTrue(text.hasPrefix("9.9"), "9.96% is printed beside the 10% level: \(text)")
    }

    func testEqualSharesAndNamesFallBackToTheID() {
        let rows = [policy("2", name: "Same", failed: 30), policy("1", name: "Same", failed: 30)]
        XCTAssertEqual(DeploymentHealth.atLevel(rows, levels: levels).map(\.row.id), ["1", "2"])
    }

    func testNamesSortNumericallyAndWithoutCase() {
        let rows = [policy("1", name: "Policy 10", failed: 30),
                    policy("2", name: "policy 9", failed: 30),
                    policy("3", name: "Apple", failed: 30),
                    policy("4", name: "banana", failed: 30)]
        XCTAssertEqual(DeploymentHealth.atLevel(rows, levels: levels).map(\.row.id),
                       ["3", "4", "2", "1"])
    }

    func testTheTabOrderRanksEveryJudgement() {
        let rows = [
            policy("notJudged", enabled: false, failed: 50),
            policy("unmeasured", failed: nil),
            policy("nothing", inScope: 0),
            policy("small", failed: 1, inScope: 5),
            policy("below", failed: 1),
            policy("warning", failed: 10),
            policy("critical", failed: 30),
        ]
        let expected = ["critical", "warning", "below", "small", "nothing", "unmeasured", "notJudged"]
        XCTAssertEqual(DeploymentHealth.tabOrder(rows, levels: levels).map(\.id), expected)
        XCTAssertEqual(DeploymentHealth.tabOrder(rows.reversed(), levels: levels).map(\.id),
                       expected)
    }

    func testNotJudgedCountsHoldEveryReason() {
        let counts = DeploymentHealth.notJudgedCounts([
            policy("1", enabled: false), policy("2", failed: nil), policy("3", inScope: 0),
            policy("4", failed: 1, inScope: 5), policy("5", failed: 1, inScope: 5),
            policy("6", failed: 30),
        ], levels: levels)
        XCTAssertEqual(counts, [.notJudged: 1, .unmeasured: 1, .nothingInScope: 1,
                                .belowMinimumScope: 2])
    }

    func testABlankLatestVersionIsUnknown() {
        let row = DeploymentHealth.Row(
            source: .appInstallers, id: "1", name: "App", enabled: true, failed: 0, inScope: 10,
            assignedElsewhere: 0, deployedVersion: "1.0", latestVersion: " ",
            updateBehavior: "AUTOMATIC", completed: nil, deferred: nil, pending: nil,
            targetVersion: nil, softwareTitle: nil)
        XCTAssertEqual(DeploymentHealth.versionState(row), .unknown)
    }

    // MARK: - Reading a row from a peer-writable snapshot

    private func patchRow(_ overrides: [String: Any]) -> DeploymentHealth.Row? {
        var dict: [String: Any] = ["id": "1", "policyEnabled": true, "failed": 1,
                                   "completed": 5, "deferred": 0, "pending": 0]
        dict.merge(overrides) { _, new in new }
        return DeploymentHealth.row(.patchPolicy, dict)
    }

    func testACountMustBeAWholeNonNegativeNumber() throws {
        XCTAssertNil(try XCTUnwrap(patchRow(["failed": -1])).failed)
        XCTAssertNil(try XCTUnwrap(patchRow(["failed": 1.5])).failed)
        XCTAssertNil(try XCTUnwrap(patchRow(["failed": true])).failed, "a boolean is no count")
        let max = SummaryJSONParser.maxSummaryNumber
        XCTAssertEqual(try XCTUnwrap(patchRow(["failed": max])).failed, max, "the seam itself is read")
    }

    func testOnlyABooleanIsAFlag() throws {
        XCTAssertNil(try XCTUnwrap(patchRow(["policyEnabled": 1])).enabled)
        XCTAssertEqual(try XCTUnwrap(patchRow(["policyEnabled": false])).enabled, false)
    }

    func testAnEmptyIDLeavesTheRowOut() {
        XCTAssertNil(patchRow(["id": ""]))
    }

    func testAnAppInstallersRowMissingAStatusIsUnmeasured() throws {
        let row = try XCTUnwrap(DeploymentHealth.row(.appInstallers, [
            "id": "1", "enabled": true,
            "computerStatuses": ["installed": 10, "inProgress": 0, "failed": 2],
        ]))
        XCTAssertNil(row.inScope, "available is missing")
        XCTAssertEqual(row.failed, 2)
    }

    // MARK: - Source states

    private func dataDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-deploy-b-\(UUID().uuidString)", isDirectory: true)
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

    private func stamp(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: text)!
    }

    func testAListWithANonObjectIsUnreadable() throws {
        let dir = try dataDir()
        try write(#"[1, {"id":"1"}]"#, kind: "patch-policies", in: dir)
        XCTAssertEqual(DeploymentHealth.load(dataDir: dir)[.patchPolicy], .unreadable)
    }

    func testASourceThatFailedSinceIsMarkedAsOfItsSnapshot() throws {
        let dir = try dataDir()
        try write("[]", kind: "patch-policies", in: dir)
        StateFileStore(directory: dir.appendingPathComponent("state")).record(
            .failed(exitCode: 1), report: "patch-policies", at: Date())
        XCTAssertEqual(DeploymentHealth.load(dataDir: dir)[.patchPolicy],
                       .rows([], asOf: stamp("20261125T120000"), leftOut: 0))
    }

    /// Spec: "not set up" is exit 4 on file and never landed. App Installers is quiet on exit 4
    /// only until its first landing.
    func testNotSetUpNeedsTheKindNeverToHaveLanded() throws {
        let dir = try dataDir()
        try write("[]", kind: "app-installers-deployments", in: dir)
        let store = StateFileStore(directory: dir.appendingPathComponent("state"))
        store.record(.landed, report: "app-installers-deployments", at: stamp("20261125T120000"))
        store.record(.failed(exitCode: 4), report: "app-installers-deployments", at: Date(),
                     cause: FailureCause(kind: .notConfiguredOnServer, names: [], hint: nil,
                                         exitCode: 4))
        XCTAssertEqual(DeploymentHealth.load(dataDir: dir)[.appInstallers],
                       .rows([], asOf: stamp("20261125T120000"), leftOut: 0))
    }

    func testASnapshotInsideTheAgeLimitIsCurrent() throws {
        let dir = try dataDir()
        try write("[]", kind: "patch-policies", in: dir)
        let now = stamp("20261125T130000")
        XCTAssertEqual(DeploymentHealth.load(dataDir: dir, now: now, maxAgeHours: 2)[.patchPolicy],
                       .rows([], asOf: nil, leftOut: 0), "one hour old, two allowed")
        XCTAssertEqual(DeploymentHealth.load(dataDir: dir, now: now, maxAgeHours: 0)[.patchPolicy],
                       .rows([], asOf: stamp("20261125T120000"), leftOut: 0))
    }

    // MARK: - Levels

    func testOneHundredIsAUsableLevel() throws {
        let yaml = "thresholds:\n  deployment_failure_warning_percent: 100\n"
            + "  deployment_failure_critical_percent: 100\n"
        XCTAssertEqual(try ConfigLoader.loadFromString(yaml).thresholds?.resolvedDeploymentLevels,
                       .init(warning: 100, critical: 100))
    }
}
