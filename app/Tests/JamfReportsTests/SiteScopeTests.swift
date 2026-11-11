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

    private func mobile(_ name: String) throws -> [MobileDeviceInventoryItem] {
        let url = TestFixtures.dir("site-scope").appendingPathComponent("\(name).json")
        return try JSONDecoder().decode(
            [MobileDeviceInventoryItem].self, from: Data(contentsOf: url))
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
            mobileDevices: try mobile("limited-mobile-devices-list"))
        XCTAssertEqual(scope, .limited(
            computers: .init(seen: 1, total: 2), mobileDevices: .init(seen: 0, total: 1)))
        XCTAssertEqual(scope.summary, "1 of 2 managed computers, and 0 of 1 managed mobile device")
    }

    func testTheWholeFixturesAreWhole() throws {
        let scope = SiteScope.evaluate(
            auth: token, overview: try fixture("limited-overview"),
            computers: try fixture("whole-computers"),
            mobileDevices: try mobile("whole-mobile-devices-list"))
        XCTAssertEqual(scope, .whole)
    }

    func testComputersLimitedWithMobileWholeNamesComputersOnly() throws {
        let scope = SiteScope.evaluate(
            auth: token, overview: try fixture("limited-overview"),
            computers: try fixture("limited-computers"),
            mobileDevices: try mobile("whole-mobile-devices-list"))
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
            + "managed mobile device in Jamf Pro "
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

    func testMobileThatWasNotSavedThisRunIsNotJudged() async throws {
        try seed("mobile-devices-list", fixture: "limited-mobile-devices-list",
                 stamp: "20200101T000000")
        let (lines, _) = try await collect(
            auth: "token", computers: "limited-computers", failing: ["mobile"])
        XCTAssertEqual(
            SiteScopeRecord.load(stateDir: try WorkspacePaths.stateDir(for: profile)),
            .limited(computers: .init(seen: 1, total: 2), mobileDevices: nil), "\(lines)")
    }

    func testAnOverviewNeitherSavedNorStampedTodayKeepsTheEarlierVerdict() async throws {
        try seed("overview", fixture: "limited-overview", stamp: "20200101T000000")
        await raiseItem()
        let stateDir = try WorkspacePaths.stateDir(for: profile)
        try SiteScopeRecord(scope: .whole, collectedAt: Date(), profile: profile)
            .save(stateDir: stateDir)
        let (lines, open) = try await collect(
            auth: "token", computers: "limited-computers", failing: ["overview"])
        XCTAssertFalse(lines.contains { $0.contains("this login sees") }, "\(lines)")
        XCTAssertEqual(SiteScopeRecord.load(stateDir: stateDir), .whole)
        XCTAssertEqual(open.map(\.code), [.siteLimitedLogin])
    }

    func testAnOverviewStampedTodayCountsEvenWhenNotSavedThisRun() async throws {
        try seed("overview", fixture: "limited-overview", stamp: todayStamp)
        let (lines, open) = try await collect(
            auth: "token", computers: "limited-computers", failing: ["overview", "mobile"])
        XCTAssertTrue(lines.contains { $0.hasPrefix("[warn] this login sees 1 of 2") }, "\(lines)")
        XCTAssertEqual(open.map(\.code), [.siteLimitedLogin])
    }

    func testANilAuthMethodTouchesNothing() async throws {
        await raiseItem()
        let stateDir = try WorkspacePaths.stateDir(for: profile)
        let earlier = SiteScope.limited(computers: .init(seen: 1, total: 2), mobileDevices: nil)
        try SiteScopeRecord(scope: earlier, collectedAt: Date(), profile: profile)
            .save(stateDir: stateDir)
        let (lines, open) = try await collect(auth: nil, computers: "whole-computers")
        XCTAssertFalse(lines.contains { $0.contains("site scope") || $0.contains("this login") })
        XCTAssertEqual(SiteScopeRecord.load(stateDir: stateDir), earlier)
        XCTAssertEqual(open.map(\.code), [.siteLimitedLogin])
    }

    func testATokenLoginThatSeesEverythingIsWholeAndClearsTheItem() async throws {
        await raiseItem()
        let (_, open) = try await collect(
            auth: "token", computers: "whole-computers", failing: ["mobile"])
        XCTAssertTrue(open.isEmpty)
        XCTAssertEqual(
            SiteScopeRecord.load(stateDir: try WorkspacePaths.stateDir(for: profile)), .whole)
    }

    func testAnApiClientIsNotApplicableEvenWhenNothingWasSaved() async throws {
        await raiseItem()
        let (_, open) = try await collect(
            auth: "oauth2", computers: "whole-computers",
            failing: ["overview", "computers", "mobile"])
        XCTAssertTrue(open.isEmpty)
        XCTAssertEqual(
            SiteScopeRecord.load(stateDir: try WorkspacePaths.stateDir(for: profile)),
            .notApplicable)
    }

    func testARefusedStateFolderStillWarnsAndRaises() async throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dataDir.appendingPathComponent("state"), withDestinationURL: elsewhere)
        let (lines, open) = try await collect(auth: "token", computers: "limited-computers")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[warn] this login sees") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[warn] state is not used") }, "\(lines)")
        XCTAssertEqual(open.map(\.code), [.siteLimitedLogin])
    }

    func testAFailedSaveLeavesTheItemOpen() async throws {
        _ = try await collect(auth: "token", computers: "limited-computers")
        let stateDir = try WorkspacePaths.stateDir(for: profile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateDir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: stateDir.path)
        }
        let (lines, open) = try await collect(auth: "oauth2", computers: "limited-computers")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[warn] site scope not saved") }, "\(lines)")
        XCTAssertEqual(open.map(\.code), [.siteLimitedLogin])
    }

    func testTheManagedWordsHaveOneReader() {
        let table: [(String, Bool?)] = [
            ("true", true), (" Yes ", true), ("1", true), ("Managed", true),
            ("false", false), ("NO", false), ("0", false), ("unmanaged", false),
            ("", nil), ("stale", nil), ("maybe", nil),
        ]
        for (text, expected) in table {
            XCTAssertEqual(BinaryMissing.managed(text), expected, text)
            XCTAssertEqual(BinaryMissing.isUnmanaged(text), expected == false, text)
        }
    }

    func testTheFleetTotalTakesNumbersAndGroupedDigitsOnly() {
        let rows: [Any] = [["id": "1", "general": ["managed": true]]]
        func scope(_ value: Any) -> SiteScope {
            SiteScope.evaluate(
                auth: token,
                overview: [["section": "Fleet", "resource": "Managed Computers", "value": value]],
                computers: rows, mobileDevices: nil)
        }
        let limited = SiteScope.limited(
            computers: .init(seen: 1, total: 1234), mobileDevices: nil)
        XCTAssertEqual(scope("1,234"), limited)
        XCTAssertEqual(scope(1234), limited)
        XCTAssertEqual(scope("12,34"), .unknown)
        XCTAssertEqual(scope(true), .unknown)
        XCTAssertEqual(
            scope("1").summary, nil, "1 of 1 is whole, so there is no limited summary")
        XCTAssertEqual(
            SiteScope.limited(computers: .init(seen: 0, total: 1), mobileDevices: nil).summary,
            "0 of 1 managed computer")
    }

    // MARK: - Helpers

    private var dataDir: URL { get throws { try WorkspacePaths.dataDir(for: profile) } }

    /// A snapshot as an earlier collect left it, stamped `stamp` (`yyyyMMdd'T'HHmmss`).
    private func seed(_ kind: String, fixture: String, stamp: String) throws {
        let dir = try dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: TestFixtures.dir("site-scope").appendingPathComponent("\(fixture).json"),
            to: dir.appendingPathComponent("\(kind)_\(stamp).json"))
    }

    private var todayStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private func raiseItem() async {
        let profile = profile
        await AttentionLog.recording(profile: profile) {
            AttentionLog.raise(.siteLimitedLogin, "earlier")
        }
    }

    private func collect(
        auth: String?, computers: String, failComputers: Bool = false,
        failing: Set<String> = []
    ) async throws -> ([String], [AttentionItem]) {
        let fixtures = TestFixtures.dir("site-scope")
        let stub = root.appendingPathComponent("bin/stub-cli")
        let failing = failComputers ? failing.union(["computers"]) : failing
        func answer(_ kind: String, _ file: String) -> String {
            failing.contains(kind) ? "exit 1" : "cat \"\(fixtures.path)/\(file).json\""
        }
        let authField = auth.map { ",\"auth-method\":\"\($0)\"" } ?? ""
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && {
          printf '%s' '[{"name":"\(profile)"\(authField)}]'; exit 0; }
        case "$*" in
          *--version*) echo "jamf-cli version 1.36.0" ;;
          *"pro overview"*) \(answer("overview", "limited-overview")) ;;
          *"pro computers list"*) \(answer("computers", computers)) ;;
          *"pro mobile-devices list"*) \(answer("mobile", "limited-mobile-devices-list")) ;;
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
