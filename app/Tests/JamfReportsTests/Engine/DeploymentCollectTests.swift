import XCTest
@testable import JamfReports

/// Collect against a stub that answers the two deployment-health commands from files and
/// everything else with an empty list.
final class DeploymentCollectTests: XCTestCase {

    private var root: URL!
    private var answers: URL!
    private let profile = "deploycapture"
    private let appInstallers = "app-installers-deployments"
    private let patchPolicies = "patch-policies"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Deploy-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        answers = root.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        ProfileAuthMethod.invalidateCache()
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var store: StateFileStore {
        get throws { StateFileStore(directory: try WorkspacePaths.stateDir(for: profile)) }
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: TestFixtures.dir("deployment-health/\(name)"), encoding: .utf8)
    }

    private func answer(_ name: String, _ text: String) throws {
        try text.write(to: answers.appendingPathComponent(name), atomically: true,
                       encoding: .utf8)
    }

    /// Sets what `kind` answers: stdout and exit code.
    private func set(_ kind: String, stdout: String, exit: Int) throws {
        try answer("\(kind).out", stdout)
        try answer("\(kind).exit", "\(exit)")
    }

    /// One refresh collect. `version` is what `jamf-cli --version` prints.
    @discardableResult
    private func collect(version: String = "jamf-cli version 1.38.0") async throws -> [String] {
        try answer("version", version)
        let stub = root.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        A="\(answers.path)"
        [ "$1" = "--version" ] && { cat "$A/version"; exit 0; }
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        for k in \(appInstallers) \(patchPolicies); do
          case "$*" in
            *" $k list"*)
              [ -f "$A/$k.out" ] && cat "$A/$k.out" || printf '[]'
              [ -f "$A/$k.exit" ] && exit "$(cat "$A/$k.exit")"
              exit 0 ;;
          esac
        done
        printf '[]'; exit 0
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let log = DeploymentLog()
        _ = try? await ReportEngine.collect(
            workspace: WorkspaceID(validating: profile), profile: profile,
            workspacePaths: WorkspacePaths.self, tiers: [.refresh], force: true,
            locateJamfCLI: { stub }, onLine: log.append)
        return log.texts
    }

    private func partial(_ log: [String], _ kind: String) -> [String] {
        log.filter { $0.hasPrefix("[partial]") && $0.contains(kind) }
    }

    func testBothLandReducedOnASupportedJamfCLI() async throws {
        try set(appInstallers, stdout: try fixture("app-installers-deployments-list.json"),
                exit: 0)
        try set(patchPolicies, stdout: try fixture("patch-policies-list.json"), exit: 0)
        try await collect()
        XCTAssertNotNil(try store.lastRun(report: appInstallers))
        XCTAssertNotNil(try store.lastRun(report: patchPolicies))
        let dir = try WorkspacePaths.dataDir(for: profile).appendingPathComponent(appInstallers)
        let url = try XCTUnwrap(FileManager.newestJSONFile(in: dir))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("iconUrl"))
        XCTAssertFalse(text.contains("All Example Macs"), "the smart group name is dropped")
        let deployments = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual((deployments.first?["computerStatuses"] as? [String: Any])?["failed"]
            as? Int, 40)
        let policyDir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent(patchPolicies)
        let policyURL = try XCTUnwrap(FileManager.newestJSONFile(in: policyDir))
        let policies = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: policyURL)) as? [[String: Any]])
        XCTAssertEqual(policies.count, 4)
        XCTAssertEqual(policies.first?["failed"] as? Int, 15)
        XCTAssertEqual(policies.first?["policyEnabled"] as? Bool, true)
        XCTAssertNil(policies.first?["policyDeploymentMethod"])
    }

    func testExitFourBeforeALandingIsQuiet() async throws {
        try set(appInstallers, stdout: try fixture("app-installers-not-found.json"), exit: 4)
        let log = try await collect()
        XCTAssertEqual(try store.cause(for: appInstallers)?.kind, .notConfiguredOnServer)
        XCTAssertTrue(try store.isAdvisory(kind: appInstallers))
        XCTAssertTrue(log.contains("[info] \(appInstallers): not set up on this Jamf Pro server"),
                      "\(log)")
        XCTAssertTrue(partial(log, appInstallers).isEmpty, "\(log)")
        let until = try XCTUnwrap(try store.advisoryHoldUntil(report: appInstallers))
        XCTAssertGreaterThan(until.timeIntervalSinceNow, 6 * 86_400, "held about a week")
    }

    func testExitFourAfterALandingIsAnOrdinaryRetryableFailure() async throws {
        try set(appInstallers, stdout: "[]", exit: 0)
        try await collect()
        XCTAssertNotNil(try store.lastRun(report: appInstallers))
        try set(appInstallers, stdout: try fixture("app-installers-not-found.json"), exit: 4)
        let log = try await collect()
        let cause = try XCTUnwrap(try store.cause(for: appInstallers))
        XCTAssertNotEqual(cause.kind, .notConfiguredOnServer)
        XCTAssertFalse(cause.isPermanent, "a same-day retry or self-repair still tries it")
        XCTAssertFalse(try store.isAdvisory(kind: appInstallers))
        XCTAssertFalse(partial(log, appInstallers).isEmpty, "\(log)")
        XCTAssertFalse(log.contains { $0.contains("not set up on this Jamf Pro server") }, "\(log)")
    }

    func testExitFourOnPatchPoliciesIsAFailure() async throws {
        try set(patchPolicies, stdout: "", exit: 4)
        let log = try await collect()
        XCTAssertFalse(try store.isAdvisory(kind: patchPolicies))
        XCTAssertNotEqual(try store.cause(for: patchPolicies)?.kind, .notConfiguredOnServer)
        XCTAssertFalse(partial(log, patchPolicies).isEmpty, "\(log)")
    }

    func testExitSevenSavesNothingForEither() async throws {
        try set(appInstallers, stdout: try fixture("app-installers-deployments-list.json"),
                exit: 7)
        try set(patchPolicies, stdout: try fixture("patch-policies-list.json"), exit: 7)
        let log = try await collect()
        XCTAssertNil(try store.lastRun(report: appInstallers))
        XCTAssertNil(try store.lastRun(report: patchPolicies))
        XCTAssertFalse(partial(log, appInstallers).isEmpty, "\(log)")
        XCTAssertFalse(partial(log, patchPolicies).isEmpty, "\(log)")
    }

    func testAPayloadThatIsNotAListSavesNothingAndFails() async throws {
        try set(patchPolicies, stdout: #"{"unexpected":true}"#, exit: 0)
        let log = try await collect()
        XCTAssertNil(try store.lastRun(report: patchPolicies))
        XCTAssertTrue(log.contains(
            "[warn] \(patchPolicies): unexpected payload shape — snapshot not saved"), "\(log)")
        XCTAssertNotNil(try store.failures(report: patchPolicies)?.last)
    }

    func testAnOlderOrUnknownJamfCLISkipsBoth() async throws {
        for version in ["jamf-cli version 1.34.9", "not a version"] {
            let log = try await collect(version: version)
            for kind in [appInstallers, patchPolicies] {
                XCTAssertTrue(log.contains {
                    $0.hasPrefix("[skip] \(kind): needs jamf-cli 1.35.0 or later")
                }, "\(version): \(log)")
                XCTAssertNil(try store.lastRun(report: kind))
            }
        }
    }

    func testBothGetTheShortCallLimit() {
        for kind in [appInstallers, patchPolicies] {
            XCTAssertEqual(ReportEngine.callTimeout(for: kind, kindTimeout: 3_600),
                           ReportEngine.serverHealthTimeout)
        }
        XCTAssertEqual(ReportEngine.callTimeout(for: "computers", kindTimeout: 3_600), 3_600)
    }
}

/// The planner's decisions for the two kinds, without running jamf-cli.
final class DeploymentCollectPlanTests: XCTestCase {

    private func plan(
        now: Date, lastRun: Date?, collectSkip: Set<String> = [], force: Bool = false,
        platform: Bool = false
    ) -> [String: ReportEngine.CollectSkipReason?] {
        var inputs = ReportEngine.CollectPlanInputs(
            tiers: [.refresh], force: force, skipExpensive: false, nonPlatformAuth: nil,
            tenantLevel: false, collectSkip: collectSkip, dashboardSupported: true,
            installedVersion: "1.38.0", now: now)
        inputs.workspaceAuthIsPlatform = platform
        let planned = ReportEngine.planCollect(
            commands: ReportEngine.collectCommandMatrix(profile: "p", staleDays: 30),
            inputs: inputs, lastRun: { _ in lastRun })
        return Dictionary(uniqueKeysWithValues: planned
            .filter { ReportEngine.deploymentKinds.contains($0.kind) }
            .map { ($0.kind, $0.skip) })
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func testTheFirstRunOfANewDayCollectsInsideTheCadence() {
        let decisions = plan(now: date(25, 1), lastRun: date(24, 23))
        XCTAssertEqual(decisions.count, 2)
        for (_, skip) in decisions { XCTAssertNil(skip) }
    }

    func testASecondRunTheSameDayWaitsForTheCadence() {
        let decisions = plan(now: date(25, 14), lastRun: date(25, 8))
        for (_, skip) in decisions {
            guard case .notDue? = skip else { return XCTFail("\(String(describing: skip))") }
        }
    }

    func testTheSameDayCollectsAgainOnceTheCadencePasses() {
        let decisions = plan(now: date(25, 21), lastRun: date(25, 8))
        XCTAssertEqual(decisions.count, 2)
        for (_, skip) in decisions { XCTAssertNil(skip) }
    }

    /// As for every kind, a stamp ahead of now cannot hold a source back
    /// (`CadenceResolver.isDue` reads it as due).
    func testAFutureStampStillCollects() {
        let decisions = plan(now: date(25, 8), lastRun: date(26, 9))
        XCTAssertEqual(decisions.count, 2)
        for (_, skip) in decisions { XCTAssertNil(skip) }
    }

    func testCollectSkipTurnsEachOff() {
        let decisions = plan(now: date(25, 8), lastRun: nil,
                             collectSkip: ["patch-policies"])
        XCTAssertEqual(decisions["patch-policies"], .collectSkip)
        XCTAssertEqual(decisions["app-installers-deployments"], .some(nil))
    }

    func testAPlatformProfileStillCollectsBoth() {
        let decisions = plan(now: date(25, 8), lastRun: nil, platform: true)
        for (_, skip) in decisions { XCTAssertNil(skip) }
    }
}

private final class DeploymentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.withLock { self.lines.append(line.text) } }
    }

    var texts: [String] { lock.withLock { lines } }
}

/// Data Freshness expects the two kinds only where `collect` would run them.
final class DeploymentExpectedKindsTests: XCTestCase {

    private let kinds = ["app-installers-deployments", "patch-policies"]

    private func expected(supported: Bool, advisory: Set<String> = []) -> Set<String> {
        Set(WorkspaceStore.expectedKinds(
            skipExpensive: false, authMethod: "oauth2", advisory: advisory,
            deploymentSourcesSupported: supported))
    }

    func testBothAreExpectedOnASupportedJamfCLI() {
        XCTAssertTrue(expected(supported: true).isSuperset(of: kinds))
    }

    func testNeitherIsExpectedOnAnOldOrUnknownJamfCLI() {
        XCTAssertTrue(expected(supported: false).isDisjoint(with: kinds))
        XCTAssertTrue(Set(WorkspaceStore.expectedKinds(skipExpensive: false, authMethod: "oauth2"))
            .isDisjoint(with: kinds), "the default is the unknown-version answer")
    }

    func testAQuietAppInstallersIsNotExpected() {
        let set = expected(supported: true, advisory: ["app-installers-deployments"])
        XCTAssertFalse(set.contains("app-installers-deployments"))
        XCTAssertTrue(set.contains("patch-policies"))
    }
}
