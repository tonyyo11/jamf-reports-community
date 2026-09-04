import XCTest
@testable import JamfReports

/// The decision `ReportEngine.collect` makes before it does anything expensive:
/// should this Mac stand down because a teammate's Mac already collected?
///
/// Exercised end-to-end against a real workspace on disk (redirected via
/// `JRC_TEST_WORKSPACES_ROOT`) rather than in the abstract, because the parts
/// most likely to break are the wiring — reading the config block, finding the
/// peer's activity file, resolving "is this folder shared" — not the pure
/// arbitration, which `SharedWorkspaceTests` already covers.
final class SharedWorkspaceCollectGateTests: XCTestCase {

    private var root: URL!
    private let profile = "gatetest"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Gate-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func writeConfig(_ yaml: String) throws {
        let url = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes a peer's activity file directly. `SharedWorkspace.recordActivity`
    /// can only ever write *this* machine's, so a second host has to be forged
    /// on disk — which is also exactly the shape a real peer would sync in.
    private func writePeerActivity(id: String, name: String, collectedAt: Date) throws {
        let dir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation/hosts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let activity = SharedWorkspace.HostActivity(
            host: SharedWorkspace.Host(id: id, name: name),
            lastCollectAt: collectedAt,
            appVersion: SharedWorkspace.appVersion
        )
        try encoder.encode(activity)
            .write(to: dir.appendingPathComponent("\(id).json"))
    }

    /// The stand-down reason, or nil when the gate says proceed. Keeps the
    /// freshness assertions below reading the way they did before the claim
    /// half was folded into the same gate.
    private func standDownReason(force: Bool = false) -> String? {
        guard case .standDown(let reason) =
                ReportEngine.coordinationGate(profile: profile, force: force) else {
            return nil
        }
        return reason
    }

    private func proceedState(force: Bool = false) -> ReportEngine.CoordinationState? {
        guard case .proceed(let state, _) =
                ReportEngine.coordinationGate(profile: profile, force: force) else {
            return nil
        }
        return state
    }

    // MARK: - Coordination off

    /// The single-Mac case, and the one that must not regress: with no
    /// `shared_workspace` block and a local workspace, the gate is inert.
    func testLocalWorkspaceNeverSkips() throws {
        try writeConfig("columns:\n  computer_name: \"Computer Name\"\n")
        try writePeerActivity(id: "PEER-1", name: "their-mac", collectedAt: Date())
        XCTAssertNil(standDownReason())
    }

    func testExplicitlyDisabledCoordinationNeverSkips() throws {
        try writeConfig("shared_workspace:\n  enabled: false\n")
        try writePeerActivity(id: "PEER-1", name: "their-mac", collectedAt: Date())
        XCTAssertNil(standDownReason())
    }

    // MARK: - Coordination on

    func testRecentPeerCollectSkipsAndNamesTheMachine() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n  min_collect_interval_hours: 12\n")
        try writePeerActivity(
            id: "PEER-1", name: "their-mac", collectedAt: Date().addingTimeInterval(-3600)
        )
        let skip = standDownReason()
        XCTAssertNotNil(skip, "a peer collected an hour ago inside a 12-hour window")
        XCTAssertTrue(skip?.contains("their-mac") == true, "the operator needs to know which Mac")
        XCTAssertTrue(skip?.contains("Refresh") == true, "and how to collect anyway")
    }

    func testOldPeerCollectDoesNotSkip() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n  min_collect_interval_hours: 12\n")
        try writePeerActivity(
            id: "PEER-1", name: "their-mac", collectedAt: Date().addingTimeInterval(-86_400)
        )
        XCTAssertNil(standDownReason())
    }

    func testNoPeersDoesNotSkip() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n")
        XCTAssertNil(standDownReason())
    }

    /// This machine's own activity must never gate it — the once-per-day guard
    /// owns that, and double-gating would break an explicit Refresh.
    func testOwnActivityDoesNotSkip() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n")
        SharedWorkspace.recordActivity(profile: profile)
        XCTAssertNil(standDownReason())
    }

    func testZeroIntervalDisablesTheSkip() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n  min_collect_interval_hours: 0\n")
        try writePeerActivity(id: "PEER-1", name: "their-mac", collectedAt: Date())
        XCTAssertNil(standDownReason())
    }

    /// The newest peer decides. An idle machine that last collected weeks ago
    /// must not drag the window open and cause a redundant collect.
    func testNewestPeerWins() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n  min_collect_interval_hours: 12\n")
        try writePeerActivity(
            id: "PEER-OLD", name: "idle-mac", collectedAt: Date().addingTimeInterval(-864_000)
        )
        try writePeerActivity(
            id: "PEER-NEW", name: "busy-mac", collectedAt: Date().addingTimeInterval(-600)
        )
        let skip = standDownReason()
        XCTAssertTrue(skip?.contains("busy-mac") == true)
    }

    // MARK: - Claim decision (previously unreachable without jamf-cli)

    /// The wiring that used to sit below the jamf-cli check, where no test on a
    /// machine without the binary could reach it. Moving the whole "should I
    /// collect" decision above "can I collect" is what makes these assertable.

    func testCoordinatingRunTakesTheClaim() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n")
        let state = proceedState()
        XCTAssertEqual(state, ReportEngine.CoordinationState(coordinating: true, holdsClaim: true))
        XCTAssertEqual(
            SharedWorkspace.readClaim(profile: profile)?.host, SharedWorkspace.currentHost,
            "proceeding under coordination must actually publish the claim"
        )
    }

    /// A local workspace must not claim anything — the single-Mac path stays
    /// untouched, and no coordination file appears in the workspace.
    func testUncoordinatedRunTakesNoClaim() throws {
        try writeConfig("columns:\n  computer_name: \"Computer Name\"\n")
        XCTAssertEqual(
            proceedState(),
            ReportEngine.CoordinationState(coordinating: false, holdsClaim: false)
        )
        XCTAssertNil(SharedWorkspace.readClaim(profile: profile))
    }

    /// A scheduled run defers to a peer that is mid-collect.
    func testLiveePeerClaimStandsDownAScheduledRun() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n")
        try writePeerClaim(expiresIn: 900)
        let reason = standDownReason()
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("busy-mac") == true, "say which Mac is working")
    }

    /// ...but a human who pressed Refresh wins, proceeds WITHOUT the claim, and
    /// is told what they are running alongside. Holding no claim is what stops
    /// the forced run releasing the peer's on its way out.
    func testForcedRunProceedsAlongsideAPeerWithoutTakingTheClaim() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n")
        try writePeerClaim(expiresIn: 900)
        guard case .proceed(let state, let notes) =
                ReportEngine.coordinationGate(profile: profile, force: true) else {
            return XCTFail("an explicit Refresh must not be blocked")
        }
        XCTAssertFalse(state.holdsClaim, "must not claim over a live peer")
        XCTAssertTrue(state.coordinating)
        XCTAssertTrue(notes.contains { $0.contains("busy-mac") }, "warn, don't fail silently")
        XCTAssertEqual(
            SharedWorkspace.readClaim(profile: profile)?.host.id, "PEER-BUSY",
            "the peer's claim must survive a forced run"
        )
    }

    /// A Mac that slept mid-collect leaves its claim behind. Taking it over is
    /// what stops one crashed machine wedging the folder for everyone.
    func testExpiredPeerClaimIsTakenOverWithANote() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n")
        try writePeerClaim(expiresIn: -3600, startedAgo: 86_400)
        guard case .proceed(let state, let notes) =
                ReportEngine.coordinationGate(profile: profile, force: false) else {
            return XCTFail("an expired claim must not block")
        }
        XCTAssertTrue(state.holdsClaim)
        XCTAssertTrue(notes.contains { $0.contains("expired claim") })
    }

    private func writePeerClaim(expiresIn: TimeInterval, startedAgo: TimeInterval = 60) throws {
        let dir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let claim = SharedWorkspace.Claim(
            host: SharedWorkspace.Host(id: "PEER-BUSY", name: "busy-mac"),
            operation: "collect",
            startedAt: Date().addingTimeInterval(-startedAgo),
            expiresAt: Date().addingTimeInterval(expiresIn),
            pid: 99, appVersion: "2.7.0"
        )
        try encoder.encode(claim).write(to: dir.appendingPathComponent(".workspace-claim.json"))
    }

    // MARK: - Claim IO

    /// The claim round-trip through real files. The arbitration itself is pure
    /// and covered in `SharedWorkspaceTests`; what is exercised here is the
    /// layer that actually reads and writes the shared folder — the part a
    /// future edit is most likely to break silently.
    func testClaimRoundTripsThroughDisk() {
        XCTAssertNil(SharedWorkspace.readClaim(profile: profile), "nothing claimed yet")

        let decision = SharedWorkspace.acquire(profile: profile, operation: "collect", ttl: 900)
        XCTAssertEqual(decision, .acquire)

        let stored = SharedWorkspace.readClaim(profile: profile)
        XCTAssertEqual(stored?.host, SharedWorkspace.currentHost)
        XCTAssertEqual(stored?.operation, "collect")

        SharedWorkspace.release(profile: profile)
        XCTAssertNil(SharedWorkspace.readClaim(profile: profile), "release must remove it")
    }

    /// A run that stood down because a peer held the claim must not then delete
    /// the very claim it respected.
    func testReleaseNeverRemovesAnotherHostsClaim() throws {
        let dir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let theirs = SharedWorkspace.Claim(
            host: SharedWorkspace.Host(id: "PEER-1", name: "their-mac"),
            operation: "collect", startedAt: Date(),
            expiresAt: Date().addingTimeInterval(600), pid: 99, appVersion: "2.7.0"
        )
        try encoder.encode(theirs).write(to: dir.appendingPathComponent(".workspace-claim.json"))

        // Compared by host rather than by whole claim: ISO-8601 encoding drops
        // sub-second precision, so the decoded Date never equals the in-memory
        // one. Irrelevant in production (claims last minutes), but it makes a
        // whole-value assertion here fail for the wrong reason.
        guard case .blocked(let held) = SharedWorkspace.acquire(
            profile: profile, operation: "collect", ttl: 900
        ) else { return XCTFail("a live peer claim must block") }
        XCTAssertEqual(held.host.id, "PEER-1")
        SharedWorkspace.release(profile: profile)
        XCTAssertEqual(
            SharedWorkspace.readClaim(profile: profile)?.host.id, "PEER-1",
            "a blocked run must leave the peer's claim intact"
        )
    }

    /// A blocked acquire must not overwrite the peer's claim with our own.
    func testBlockedAcquireWritesNothing() throws {
        let dir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let theirs = SharedWorkspace.Claim(
            host: SharedWorkspace.Host(id: "PEER-1", name: "their-mac"),
            operation: "backup", startedAt: Date(),
            expiresAt: Date().addingTimeInterval(600), pid: 99, appVersion: "2.7.0"
        )
        try encoder.encode(theirs).write(to: dir.appendingPathComponent(".workspace-claim.json"))

        _ = SharedWorkspace.acquire(profile: profile, operation: "collect", ttl: 900)
        XCTAssertEqual(SharedWorkspace.readClaim(profile: profile)?.operation, "backup")
    }

    func testExpiredPeerClaimIsTakenOverOnDisk() throws {
        let dir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stale = SharedWorkspace.Claim(
            host: SharedWorkspace.Host(id: "PEER-1", name: "crashed-mac"),
            operation: "collect", startedAt: Date().addingTimeInterval(-86_400),
            expiresAt: Date().addingTimeInterval(-80_000), pid: 99, appVersion: "2.7.0"
        )
        try encoder.encode(stale).write(to: dir.appendingPathComponent(".workspace-claim.json"))

        guard case .takeOverExpired = SharedWorkspace.acquire(
            profile: profile, operation: "collect", ttl: 900
        ) else { return XCTFail("an expired peer claim must be takeable") }
        XCTAssertEqual(
            SharedWorkspace.readClaim(profile: profile)?.host, SharedWorkspace.currentHost,
            "takeover must actually rewrite the file"
        )
    }

    /// An oversized file is refused before decoding — the folder is writable by
    /// other people by design, and this mirrors the caps already applied to
    /// plist and log reads elsewhere in the app.
    func testOversizedClaimIsIgnored() throws {
        let dir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let padding = String(repeating: "A", count: 200_000)
        try "{\"junk\":\"\(padding)\"}".write(
            to: dir.appendingPathComponent(".workspace-claim.json"),
            atomically: true, encoding: .utf8
        )
        XCTAssertNil(SharedWorkspace.readClaim(profile: profile))
    }

    func testRecordActivityWritesThisHostsFileOnly() {
        SharedWorkspace.recordActivity(profile: profile)
        XCTAssertTrue(
            SharedWorkspace.otherHosts(profile: profile).isEmpty,
            "our own file must never appear in the peer list"
        )
        let dir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation/hosts", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(files.count, 1, "one file per machine, never a shared one")
    }

    // MARK: - Degraded inputs

    /// An unparseable config must not stop this Mac collecting. The real config
    /// load further down reports the parse error properly; refusing to collect
    /// here would turn a coordination detail into a total outage.
    func testUnreadableConfigDoesNotSkip() throws {
        try writeConfig("shared_workspace:\n    enabled: [not, a, bool\n")
        try writePeerActivity(id: "PEER-1", name: "their-mac", collectedAt: Date())
        XCTAssertNil(standDownReason())
    }

    /// A corrupt peer file is skipped, not fatal — a half-synced JSON must not
    /// take a machine's reporting offline.
    func testCorruptPeerFileIsIgnored() throws {
        try writeConfig("shared_workspace:\n  enabled: true\n")
        let dir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation/hosts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ truncated".write(
            to: dir.appendingPathComponent("PEER-BAD.json"), atomically: true, encoding: .utf8
        )
        XCTAssertNil(standDownReason())
    }

    func testMissingConfigDoesNotSkip() throws {
        try writePeerActivity(id: "PEER-1", name: "their-mac", collectedAt: Date())
        XCTAssertNil(standDownReason())
    }
}
