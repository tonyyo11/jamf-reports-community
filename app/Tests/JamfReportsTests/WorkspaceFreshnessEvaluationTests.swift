import XCTest
@testable import JamfReports

/// Call-site test for `WorkspaceStore.evaluateFreshness` — the wiring between
/// on-disk `StateFileStore` state, the `skipExpensiveCollections` toggle, and
/// the pure `DataFreshnessHealth.evaluate` seam `DataFreshnessHealthTests`
/// already covers in the abstract. This pins that the wiring reads the right
/// state directory and honors the toggle, not the evaluator's own rules.
final class WorkspaceFreshnessEvaluationTests: XCTestCase {

    private var root: URL!
    private let profile = "freshnesscallsite"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let skipExpensiveKey = "skipExpensiveCollections"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Freshness-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        // Restore the default (absent key reads as false, same as the app's
        // @AppStorage default) so this test can never leak into another.
        UserDefaults.standard.removeObject(forKey: skipExpensiveKey)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func stateStore() throws -> StateFileStore {
        StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
    }

    // MARK: - Never collected

    func testNeverCollectedWorkspaceHasNoIssuesAndReportsNotCollectedBefore() {
        UserDefaults.standard.set(false, forKey: skipExpensiveKey)
        let issues = WorkspaceStore.evaluateFreshness(profile: profile, now: now)
        XCTAssertTrue(issues.isEmpty,
                      "A workspace that has never collected must not alarm on every kind")
    }

    // MARK: - skipExpensiveCollections toggle

    func testExpensiveKindsAreExcludedWhenSkipToggleIsOn() throws {
        try stateStore().record(.landed, report: "overview", at: now)
        UserDefaults.standard.set(true, forKey: skipExpensiveKey)

        let issues = WorkspaceStore.evaluateFreshness(profile: profile, now: now)
        let reportedKinds = Set(issues.map(\.snapshotKind))
        for expensive in ReportEngine.expensivePerDeviceKinds {
            XCTAssertFalse(reportedKinds.contains(expensive),
                           "\(expensive) is deliberately opted out — must not alarm")
        }
    }

    func testExpensiveKindsAreIncludedWhenSkipToggleIsOff() throws {
        try stateStore().record(.landed, report: "overview", at: now)
        UserDefaults.standard.set(false, forKey: skipExpensiveKey)

        let issues = WorkspaceStore.evaluateFreshness(profile: profile, now: now)
        let reportedKinds = Set(issues.map(\.snapshotKind))
        // Every expensive kind has never landed on an established workspace —
        // a real gap the operator should see when the toggle is off.
        for expensive in ReportEngine.expensivePerDeviceKinds {
            XCTAssertTrue(reportedKinds.contains(expensive),
                          "\(expensive) must alarm when expensive collection is not skipped")
        }
    }

    // MARK: - hasCollectedBefore derivation

    func testHasCollectedBeforeIsDerivedFromAnyRecordedSuccess() throws {
        UserDefaults.standard.set(false, forKey: skipExpensiveKey)
        try stateStore().record(.landed, report: "overview", at: now)

        let issues = WorkspaceStore.evaluateFreshness(profile: profile, now: now)
        // update-device-failures has never landed; on an established
        // workspace (overview HAS landed) that is a real gap, not silence.
        XCTAssertTrue(issues.map(\.snapshotKind).contains("update-device-failures"))
    }

    func testFailuresAloneDoNotCountAsHavingCollectedBefore() throws {
        UserDefaults.standard.set(false, forKey: skipExpensiveKey)
        // A `.fail` file with no `.last` anywhere — one failure is below the
        // failing threshold (2), and hasCollectedBefore must stay false.
        try stateStore().record(.failed(exitCode: 1), report: "overview", at: now)

        let issues = WorkspaceStore.evaluateFreshness(profile: profile, now: now)
        XCTAssertTrue(issues.isEmpty)
    }
}
