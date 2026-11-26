import XCTest
@testable import JamfReports

/// A routed collect (`landedSources` bound, as `CollectRouter` binds it) writes the change
/// parts into today's summary. The stub is not named `jamf-cli` (codesign gate).
final class FleetChangeCollectTests: XCTestCase {

    private var root: URL!
    private let profile = "changesprof"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Changes-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try """
        jamf_cli:
          profile: "\(profile)"
        """.write(to: workspace.appendingPathComponent("config.yaml"),
                  atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Fixed once, so the seeded file name and the assertion name the same second.
    private let yesterday = Date().addingTimeInterval(-86_400)

    private func seed(_ kind: String, _ json: String) throws {
        let dir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent(
            "\(kind)_\(GoldenFleetClock.stamp(yesterday)).json"))
    }

    private func todaysSummary() throws -> DailySummary {
        let dir = try WorkspacePaths.summariesDir(for: profile)
        let name = "summary_\(SummaryJSONParser.dateFormatter.string(from: Date())).json"
        return try SummaryJSONParser.decode(Data(contentsOf: dir.appendingPathComponent(name)))
    }

    private static let healthyScan =
        #"[{"section":"device_failures","data":[],"fetch_error":""}]"#

    private func collect(
        landed: LandedSources?, scan: String = healthyScan,
        lines: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) async throws {
        let computers = #"[{"id":"1","general":{"name":"Mac-1"},"#
            + #""diskEncryption":{"fileVault2Enabled":false}},"#
            + #"{"id":"2","general":{"name":"Mac-2"}}]"#
        let rules = #"[{"benchmark":"CIS","ruleId":"r1","rule":"Rule 1","failed":2}]"#
        let security = #"[{"section":"summary","data":{"total_devices":2,"#
            + #""filevault_encrypted":1,"gatekeeper_enabled":2,"sip_enabled":2,"#
            + #""firewall_enabled":2}}]"#
        let stub = root.appendingPathComponent("stub-cli")
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        case "$*" in
          --version) echo "jamf-cli version 1.31.1"; exit 0 ;;
          *"computers list"*) printf '%s' '\(computers)'; exit 0 ;;
          *"compliance-benchmarks list"*) printf '%s' '[{"title":"CIS"}]'; exit 0 ;;
          *"compliance-rules"*) printf '%s' '\(rules)'; exit 0 ;;
          *"report security"*) printf '%s' '\(security)'; exit 0 ;;
          *"patch-status"*"--scan-failures"*) printf '%s' '\(scan)'; exit 0 ;;
          *) printf '[]'; exit 0 ;;
        esac
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let run = {
            try await ReportEngine.collect(
                workspace: WorkspaceID(validating: self.profile), profile: self.profile,
                workspacePaths: WorkspacePaths.self, tiers: Set(CollectionTier.allCases),
                force: true, locateJamfCLI: { stub }, onLine: lines ?? { _ in })
        }
        if let landed {
            try await ReportEngine.$landedSources.withValue(landed) { try await run() }
        } else {
            try await run()
        }
    }

    func testRoutedCollectWritesTheChangeParts() async throws {
        try seed("computers", #"[{"id":"1","diskEncryption":{"fileVault2Enabled":true}},"#
                 + #"{"id":"3"}]"#)
        try seed("compliance-rules", #"[{"benchmark":"CIS","ruleId":"r1","rule":"Rule 1","#
                 + #""failed":0}]"#)
        try await collect(landed: LandedSources())
        let changes = try XCTUnwrap(try todaysSummary().changes)
        let computers = try XCTUnwrap(changes.computers)
        XCTAssertEqual(computers.joined, 1)
        XCTAssertEqual(computers.left, 1)
        XCTAssertEqual(computers.fileVaultOff, 1)
        XCTAssertEqual(computers.currentCount, 2)
        XCTAssertEqual(computers.baselineStamp, GoldenFleetClock.stamp(yesterday))
        XCTAssertEqual(changes.benchmarks?.newlyFailing, 1)
    }

    func testCollectWithoutTheRouterWritesNoChanges() async throws {
        try seed("computers", #"[{"id":"1"}]"#)
        try await collect(landed: nil)
        XCTAssertNil(try todaysSummary().changes)
    }

    // MARK: - Patch (B2b)

    func testRoutedCollectWritesThePatchPart() async throws {
        try seed("computers", #"[{"id":"101"},{"id":"1"}]"#)
        try seed("patch-device-failures",
                 #"[{"device_id":"1","policy_id":"11"},{"device_id":"99","policy_id":"11"}]"#)
        let captured = try String(contentsOf: TestFixtures.dir("patch")
            .appendingPathComponent("patch-scan-failures-captured.json"), encoding: .utf8)
        try await collect(landed: LandedSources(),
                          scan: captured.replacingOccurrences(of: "\n", with: " "))
        let patch = try XCTUnwrap(try todaysSummary().changes?.patch)
        XCTAssertEqual(patch.startedFailing, 1, "the captured Mac 101 on policy 11")
        XCTAssertEqual(patch.stoppedFailing, 1, "Mac 1 is in this run's computers")
        XCTAssertEqual(patch.notInComputers, 1, "Mac 99 is not")
        let stamp = try XCTUnwrap(patch.computersStamp)
        XCTAssertNotNil(PatchReleaseDateService.stampDate(stamp))
        XCTAssertNotEqual(stamp, GoldenFleetClock.stamp(yesterday),
                          "the landed computers snapshot's stamp, not the seeded file's")
    }

    func testScanWithNoDeviceSectionIsNotSavedAndHasACause() async throws {
        try seed("patch-device-failures", "[]")
        let lines = Lines()
        try await collect(landed: LandedSources(),
                          scan: #"[{"section":"title_compliance","data":[]}]"#,
                          lines: lines.append)
        XCTAssertNil(try todaysSummary().changes?.patch)
        let warnings = lines.texts.filter { $0.contains("no device_failures section") }
        XCTAssertEqual(warnings.count, 1, "\(lines.texts)")
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(store.cause(for: "patch-device-failures"))
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.lock(); defer { self.lock.unlock() }; self.lines.append(line.text) }
    }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
