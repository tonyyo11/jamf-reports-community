import XCTest
@testable import JamfReports

/// Site-limited login detection: the pure rule, the persisted verdict, the Doctor row and a
/// collect against a stub (never a real jamf-cli).
final class SiteScopeTests: XCTestCase {
    private var root: URL!
    private let profile = "sitescope"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SiteScope-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile)
                .appendingPathComponent("automation", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ name: String) throws -> [Any] {
        let url = TestFixtures.dir("site-scope").appendingPathComponent("\(name).json")
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
    }

    private func overview(computers: String, devices: String = "1") -> [Any] {
        [["section": "Fleet", "resource": "Managed Computers", "value": computers],
         ["section": "Fleet", "resource": "Managed Devices", "value": devices]]
    }

    private let token = JamfCLIAuthMethod.other("token")

    // MARK: - Rule

    func testOnlyAnUnlistedAuthMethodIsJudged() throws {
        let limited = try fixture("limited-overview")
        for auth in [JamfCLIAuthMethod.oauth2, .platform, .apiKey, .security] {
            XCTAssertEqual(
                SiteScope.evaluate(
                    auth: auth, overview: limited, computers: [], mobileDevices: nil),
                .notApplicable)
        }
        XCTAssertEqual(
            SiteScope.evaluate(auth: nil, overview: limited, computers: [], mobileDevices: nil),
            .unknown)
    }

    func testTheLimitedFixturesAreLimitedOnBothTypes() throws {
        let scope = SiteScope.evaluate(
            auth: token, overview: try fixture("limited-overview"),
            computers: try fixture("limited-computers"),
            mobileDevices: try fixture("limited-mobile-devices-list"))
        XCTAssertEqual(scope, .limited(
            computers: .init(seen: 1, total: 2), mobileDevices: .init(seen: 0, total: 1)))
        XCTAssertEqual(scope.summary, "1 of 2 managed computers, and 0 of 1 managed mobile devices")
    }

    func testTheWholeFixturesAreWhole() throws {
        let scope = SiteScope.evaluate(
            auth: token, overview: try fixture("limited-overview"),
            computers: try fixture("whole-computers"),
            mobileDevices: try fixture("whole-mobile-devices-list"))
        XCTAssertEqual(scope, .whole)
    }

    func testComputersLimitedWithMobileWholeNamesComputersOnly() throws {
        let scope = SiteScope.evaluate(
            auth: token, overview: try fixture("limited-overview"),
            computers: try fixture("limited-computers"),
            mobileDevices: try fixture("whole-mobile-devices-list"))
        XCTAssertEqual(scope, .limited(computers: .init(seen: 1, total: 2), mobileDevices: nil))
    }

    func testZeroOfNIsLimited() throws {
        XCTAssertEqual(
            SiteScope.evaluate(
                auth: token, overview: overview(computers: "5"), computers: [], mobileDevices: nil),
            .limited(computers: .init(seen: 0, total: 5), mobileDevices: nil))
    }

    func testMoreSeenThanTheTotalIsWhole() throws {
        let rows = try fixture("limited-computers") + (try fixture("limited-computers"))
        XCTAssertEqual(
            SiteScope.evaluate(
                auth: token, overview: overview(computers: "1"), computers: rows,
                mobileDevices: nil),
            .whole)
    }

    func testAnUnreadableTotalOrAMissingKeyCompareNothing() throws {
        let rows = try fixture("limited-computers")
        for total in ["N/A", "", "two", "-1", "1.5"] {
            XCTAssertEqual(
                SiteScope.evaluate(
                    auth: token, overview: overview(computers: total), computers: rows,
                    mobileDevices: nil),
                .unknown, total)
        }
        XCTAssertEqual(
            SiteScope.evaluate(auth: token, overview: [["section": "Fleet"]], computers: rows,
                               mobileDevices: nil),
            .unknown)
    }

    func testARowWithAnUnknownManagedStateMakesThatTypeNil() {
        let rows: [Any] = [["id": "1"]]
        XCTAssertEqual(
            SiteScope.evaluate(
                auth: token, overview: overview(computers: "3"), computers: rows,
                mobileDevices: nil),
            .unknown)
    }

    // MARK: - State file

    func testTheVerdictRoundTripsAndEverythingElseIsUnknown() throws {
        let stateDir = try WorkspacePaths.stateDir(for: profile)
        XCTAssertEqual(SiteScopeRecord.load(stateDir: stateDir), .unknown, "missing")
        let scope = SiteScope.limited(computers: .init(seen: 1, total: 2), mobileDevices: nil)
        try SiteScopeRecord(scope: scope, collectedAt: Date(), profile: profile)
            .save(stateDir: stateDir)
        XCTAssertEqual(SiteScopeRecord.load(stateDir: stateDir), scope)
        let file = stateDir.appendingPathComponent(SiteScopeRecord.fileName)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        XCTAssertEqual(mode as? Int, 0o600)

        try Data("{not json".utf8).write(to: file)
        XCTAssertEqual(SiteScopeRecord.load(stateDir: stateDir), .unknown, "unreadable")

        try FileManager.default.removeItem(at: file)
        let target = root.appendingPathComponent("elsewhere.json")
        try SiteScopeRecord(scope: scope, collectedAt: Date(), profile: profile)
            .save(stateDir: stateDir)
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertEqual(SiteScopeRecord.load(stateDir: stateDir), .unknown, "a link")
    }

    // MARK: - Doctor

    func testTheDoctorRowShowsOnlyForALimitedVerdict() {
        let limited = SiteScope.limited(computers: .init(seen: 1, total: 2), mobileDevices: nil)
        let rows = ConfigDoctorService.siteScopeRows(limited)
        XCTAssertEqual(rows.map(\.id), ["accuracy.site_scope"])
        XCTAssertEqual(rows.first?.severity, .warn)
        XCTAssertEqual(rows.first?.detail, "1 of 2 managed computers")
        for scope in [SiteScope.whole, .unknown, .notApplicable] {
            XCTAssertTrue(ConfigDoctorService.siteScopeRows(scope).isEmpty)
        }
    }

    // MARK: - Collect

    func testATokenLoginThatSeesLessIsWarnedRaisedAndSaved() async throws {
        let (lines, open) = try await collect(auth: "token", computers: "limited-computers")
        let warns = lines.filter { $0.hasPrefix("[warn] this login sees") }
        XCTAssertEqual(warns, ["[warn] this login sees 1 of 2 managed computers, and 0 of 1 "
            + "managed mobile devices in Jamf Pro "
            + "(a site-limited user account); reports cover only what it sees"], "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("[partial]") && $0.contains("login") })
        XCTAssertEqual(open.map(\.code), [.siteLimitedLogin])
        XCTAssertEqual(
            SiteScopeRecord.load(stateDir: try WorkspacePaths.stateDir(for: profile)),
            .limited(computers: .init(seen: 1, total: 2), mobileDevices: .init(seen: 0, total: 1)))
    }

    func testARunThatSavedOnlyOneKindKeepsTheVerdictAndSaysNothing() async throws {
        let stateDir = try WorkspacePaths.stateDir(for: profile)
        let earlier = SiteScope.limited(computers: .init(seen: 1, total: 2), mobileDevices: nil)
        try SiteScopeRecord(scope: earlier, collectedAt: Date(), profile: profile)
            .save(stateDir: stateDir)
        let (lines, _) = try await collect(
            auth: "token", computers: "whole-computers", failComputers: true)
        XCTAssertFalse(lines.contains { $0.contains("this login sees") }, "\(lines)")
        XCTAssertEqual(SiteScopeRecord.load(stateDir: stateDir), earlier)
    }

    func testAnApiClientClearsTheItem() async throws {
        let stateDir = try WorkspacePaths.stateDir(for: profile)
        _ = try await collect(auth: "token", computers: "limited-computers")
        let (_, open) = try await collect(auth: "oauth2", computers: "limited-computers")
        XCTAssertTrue(open.isEmpty)
        XCTAssertEqual(SiteScopeRecord.load(stateDir: stateDir), .notApplicable)
    }

    // MARK: - Helpers

    private func collect(
        auth: String, computers: String, failComputers: Bool = false
    ) async throws -> ([String], [AttentionItem]) {
        let fixtures = TestFixtures.dir("site-scope")
        let stub = root.appendingPathComponent("bin/stub-cli")
        let computersCommand = failComputers
            ? "exit 1" : "cat \"\(fixtures.path)/\(computers).json\""
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && {
          printf '%s' '[{"name":"\(profile)","auth-method":"\(auth)"}]'; exit 0; }
        case "$*" in
          *--version*) echo "jamf-cli version 1.36.0" ;;
          *"pro overview"*) cat "\(fixtures.path)/limited-overview.json" ;;
          *"pro computers list"*) \(computersCommand) ;;
          *"pro mobile-devices list"*) cat "\(fixtures.path)/limited-mobile-devices-list.json" ;;
          *) printf '[]' ;;
        esac
        exit 0
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        ProfileAuthMethod.invalidateCache()
        let box = LineBox()
        let profile = profile
        try await AttentionLog.recording(profile: profile) {
            _ = try await ReportEngine.collect(
                workspace: WorkspaceID(validating: profile), profile: profile,
                workspacePaths: WorkspacePaths.self, force: true,
                authConfirmationProbe: { _, _ in false }, locateJamfCLI: { stub },
                refreshSOFA: { _ in (.empty, []) }, onLine: box.append)
        }
        return (box.texts, AttentionLog.openItems(profile: profile))
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var texts: [String] { lock.withLock { storage } }
    func append(_ line: CLIBridge.LogLine) { lock.withLock { storage.append(line.text) } }
}
