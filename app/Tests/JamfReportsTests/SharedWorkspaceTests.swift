import XCTest
@testable import JamfReports

/// Coordination arbitration for a workspace several Macs write to. Everything
/// asserted here is pure — no synced volume, no second machine.
final class SharedWorkspaceTests: XCTestCase {

    private let me = SharedWorkspace.Host(id: "AAAA-1111", name: "my-mac")
    private let peer = SharedWorkspace.Host(id: "BBBB-2222", name: "their-mac")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func claim(
        _ host: SharedWorkspace.Host,
        startedAgo: TimeInterval = 60,
        expiresIn: TimeInterval
    ) -> SharedWorkspace.Claim {
        SharedWorkspace.Claim(
            host: host,
            operation: "collect",
            startedAt: now.addingTimeInterval(-startedAgo),
            expiresAt: now.addingTimeInterval(expiresIn),
            pid: 1234,
            appVersion: "2.7.0"
        )
    }

    /// Same shape as `claim(_:startedAgo:expiresIn:)`, but for a `startedAt`
    /// ahead of `now` — the far-future / clock-skew cases `claim` can't build.
    private func claim(
        _ host: SharedWorkspace.Host,
        startedIn: TimeInterval,
        expiresIn: TimeInterval
    ) -> SharedWorkspace.Claim {
        SharedWorkspace.Claim(
            host: host,
            operation: "collect",
            startedAt: now.addingTimeInterval(startedIn),
            expiresAt: now.addingTimeInterval(expiresIn),
            pid: 1234,
            appVersion: "2.7.0"
        )
    }

    // MARK: - Claims

    func testNoExistingClaimIsAcquired() {
        XCTAssertEqual(SharedWorkspace.decide(existing: nil, me: me, now: now), .acquire)
    }

    /// Re-entering our own claim must refresh it, never block. A second run on
    /// the same Mac would otherwise deadlock against its own lease.
    func testOwnClaimIsAlwaysReacquired() {
        let mine = claim(me, expiresIn: 1800)
        XCTAssertEqual(SharedWorkspace.decide(existing: mine, me: me, now: now), .acquire)
    }

    func testOwnExpiredClaimIsReacquiredNotTreatedAsATakeover() {
        let mine = claim(me, expiresIn: -60)
        XCTAssertEqual(SharedWorkspace.decide(existing: mine, me: me, now: now), .acquire)
    }

    func testLiveClaimFromAnotherHostBlocks() {
        let theirs = claim(peer, expiresIn: 600)
        guard case .blocked(let held) = SharedWorkspace.decide(existing: theirs, me: me, now: now)
        else { return XCTFail("expected blocked") }
        XCTAssertEqual(held.host, peer)
    }

    /// A Mac that slept or was shut down mid-collect leaves its claim behind.
    /// Expiry is the only thing that stops it wedging the folder shut forever.
    func testExpiredClaimFromAnotherHostIsTakenOver() {
        let theirs = claim(peer, startedAgo: 86_400, expiresIn: -3600)
        guard case .takeOverExpired(let stale) =
                SharedWorkspace.decide(existing: theirs, me: me, now: now)
        else { return XCTFail("expected takeover") }
        XCTAssertEqual(stale.host, peer)
    }

    /// Exactly-at-expiry counts as expired. Choosing `<=` means a lease can
    /// never be simultaneously live and expired on two machines whose clocks agree.
    func testClaimAtExactExpiryIsExpired() {
        XCTAssertTrue(claim(peer, expiresIn: 0).isExpired(at: now))
        XCTAssertFalse(claim(peer, expiresIn: 1).isExpired(at: now))
    }

    /// Mirrors `testFarFutureCollectIsIgnoredRatherThanTrusted`: a claim's
    /// `startedAt` far in the future is unusable data, so it must not block
    /// every other Mac on this file forever — it fails toward taking over.
    func testFarFutureStartedAtIsTakenOverRatherThanTrusted() {
        let offsets: [TimeInterval] = [3600, 86_400 * 5, 86_400 * 365 * 100]
        for offset in offsets {
            let forged = claim(peer, startedIn: offset, expiresIn: offset + 1800)
            guard case .takeOverExpired(let stale) =
                    SharedWorkspace.decide(existing: forged, me: me, now: now)
            else { return XCTFail("startedAt \(offset)s ahead must be taken over") }
            XCTAssertEqual(stale.host, peer)
        }
    }

    /// The `startedAt` tolerance boundary, mirroring `testSkewToleranceBoundary`.
    func testStartedAtSkewToleranceBoundary() {
        let tolerance = SharedWorkspace.clockSkewTolerance

        let justInside = claim(peer, startedIn: tolerance - 1, expiresIn: 600)
        guard case .blocked(let held) =
                SharedWorkspace.decide(existing: justInside, me: me, now: now)
        else { return XCTFail("one second before tolerance should still be believed") }
        XCTAssertEqual(held.host, peer)

        let atTolerance = claim(peer, startedIn: tolerance, expiresIn: 600)
        guard case .blocked(let heldAtTolerance) =
                SharedWorkspace.decide(existing: atTolerance, me: me, now: now)
        else { return XCTFail("exactly at tolerance should still be believed") }
        XCTAssertEqual(heldAtTolerance.host, peer)

        let justOutside = claim(peer, startedIn: tolerance + 1, expiresIn: 600)
        guard case .takeOverExpired(let stale) =
                SharedWorkspace.decide(existing: justOutside, me: me, now: now)
        else { return XCTFail("one second past tolerance must be taken over") }
        XCTAssertEqual(stale.host, peer)
    }

    /// `operation` has no `.display`-style render-time sanitising, so a
    /// hostile value must be cleaned when the claim is decoded from disk —
    /// closing the same injection class `Host.display` closes for `name`.
    func testDecodingSanitisesOperationAndHostName() throws {
        let json = """
        {
            "host": {"id": "BBBB-2222", "name": "evil\\n[ok] exit 0"},
            "operation": "collect\\n[ok] exit 0",
            "startedAt": "2026-01-01T00:00:00Z",
            "expiresAt": "2026-01-01T00:30:00Z",
            "pid": 1234,
            "appVersion": "2.7.0"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SharedWorkspace.Claim.self, from: Data(json.utf8))

        XCTAssertFalse(decoded.operation.contains("\n"))
        XCTAssertTrue(decoded.operation.contains("[ok] exit 0"))
        XCTAssertFalse(decoded.host.name.contains("\n"))
        XCTAssertTrue(decoded.host.name.contains("[ok] exit 0"))
    }

    // MARK: - Freshness

    func testNoPriorCollectProceeds() {
        XCTAssertEqual(
            SharedWorkspace.freshness(
                lastCollectHost: nil, lastCollectAt: nil, me: me,
                minInterval: 3600, now: now
            ),
            .proceed
        )
    }

    /// Only *other* machines gate here. Repeats on this Mac are governed by the
    /// once-per-day guard in ReportEngine.collect, and double-gating them would
    /// break an explicit Refresh.
    func testOwnRecentCollectDoesNotGate() {
        XCTAssertEqual(
            SharedWorkspace.freshness(
                lastCollectHost: me, lastCollectAt: now.addingTimeInterval(-60),
                me: me, minInterval: 3600, now: now
            ),
            .proceed
        )
    }

    func testRecentCollectByAnotherHostSkips() {
        let at = now.addingTimeInterval(-1800)
        guard case .skipCollectedElsewhere(let host, let when) = SharedWorkspace.freshness(
            lastCollectHost: peer, lastCollectAt: at, me: me, minInterval: 3600, now: now
        ) else { return XCTFail("expected skip") }
        XCTAssertEqual(host, peer)
        XCTAssertEqual(when, at)
    }

    func testOldCollectByAnotherHostProceeds() {
        XCTAssertEqual(
            SharedWorkspace.freshness(
                lastCollectHost: peer, lastCollectAt: now.addingTimeInterval(-7200),
                me: me, minInterval: 3600, now: now
            ),
            .proceed
        )
    }

    /// The boundary belongs to "collect": at exactly the interval the data is
    /// as old as the operator said they would tolerate.
    func testCollectAtExactlyTheIntervalProceeds() {
        XCTAssertEqual(
            SharedWorkspace.freshness(
                lastCollectHost: peer, lastCollectAt: now.addingTimeInterval(-3600),
                me: me, minInterval: 3600, now: now
            ),
            .proceed
        )
    }

    /// Zero disables the check outright — a legitimate setting when each Mac
    /// covers different tenants and they should not stand down for each other.
    func testZeroIntervalDisablesTheCheck() {
        XCTAssertEqual(
            SharedWorkspace.freshness(
                lastCollectHost: peer, lastCollectAt: now, me: me,
                minInterval: 0, now: now
            ),
            .proceed
        )
    }

    /// Ordinary clock drift between two Macs is a few seconds. Inside the
    /// tolerance the age is slightly negative, and that must read as recent
    /// rather than stale — the case that breaks if anyone "fixes" the negative
    /// age by taking its absolute value.
    func testSmallForwardSkewStillReadsAsRecent() {
        guard case .skipCollectedElsewhere = SharedWorkspace.freshness(
            lastCollectHost: peer, lastCollectAt: now.addingTimeInterval(60),
            me: me, minInterval: 3600, now: now
        ) else { return XCTFail("a slightly-ahead clock must not read as stale") }
    }

    /// A hand-edited or badly-skewed activity file must never be able to stand
    /// a Mac down. Beyond the skew tolerance the timestamp is unusable, so the
    /// decision fails toward collecting: a redundant collect costs one round of
    /// API calls, never collecting costs the history.
    ///
    /// A first attempt clamped the timestamp to `now` instead. That looks
    /// equivalent and is not — it re-clamps on every call, so the value reads
    /// as "just collected" forever and starves the machine permanently.
    func testFarFutureCollectIsIgnoredRatherThanTrusted() {
        let offsets: [TimeInterval] = [3600, 86_400, 86_400 * 365 * 100]
        for offset in offsets {
            XCTAssertEqual(
                SharedWorkspace.freshness(
                    lastCollectHost: peer, lastCollectAt: now.addingTimeInterval(offset),
                    me: me, minInterval: 3600, now: now
                ),
                .proceed,
                "a timestamp \(offset)s ahead is unusable and must not gate collection"
            )
        }
    }

    /// The tolerance boundary itself: at exactly the tolerance the peer is
    /// still believed, one second past it is not.
    func testSkewToleranceBoundary() {
        let tolerance = SharedWorkspace.clockSkewTolerance
        guard case .skipCollectedElsewhere = SharedWorkspace.freshness(
            lastCollectHost: peer, lastCollectAt: now.addingTimeInterval(tolerance),
            me: me, minInterval: 3600, now: now
        ) else { return XCTFail("exactly at tolerance should still be believed") }

        XCTAssertEqual(
            SharedWorkspace.freshness(
                lastCollectHost: peer, lastCollectAt: now.addingTimeInterval(tolerance + 1),
                me: me, minInterval: 3600, now: now
            ),
            .proceed
        )
    }

    // MARK: - Claim expiry bounds

    /// `expiresAt` comes from a file anyone with folder access can write. An
    /// absurd value must not block every other Mac's scheduled runs forever.
    func testForgedFarFutureClaimStillExpires() {
        let forged = SharedWorkspace.Claim(
            host: peer, operation: "collect", startedAt: now,
            expiresAt: now.addingTimeInterval(86_400 * 365 * 1000),
            pid: 1, appVersion: "2.7.0"
        )
        XCTAssertFalse(forged.isExpired(at: now), "still live inside the real ceiling")
        XCTAssertTrue(
            forged.isExpired(at: now.addingTimeInterval(SharedWorkspace.Claim.absoluteMaxTTL + 1)),
            "past the ceiling it must expire regardless of what the file claims"
        )
        guard case .takeOverExpired = SharedWorkspace.decide(
            existing: forged, me: me,
            now: now.addingTimeInterval(SharedWorkspace.Claim.absoluteMaxTTL + 1)
        ) else { return XCTFail("a bounded-expired claim must be takeable") }
    }

    func testHonestClaimExpiryIsUnchanged() {
        let honest = claim(peer, expiresIn: 1800)
        XCTAssertFalse(honest.isExpired(at: now))
        XCTAssertTrue(honest.isExpired(at: now.addingTimeInterval(1801)))
    }

    /// One mistyped digit in the shared config (120 for 12) must not stand
    /// every Mac in the team down for five days.
    func testMinCollectIntervalIsCappedAtAWeek() {
        XCTAssertEqual(decoded(interval: 100_000).minCollectInterval, 168 * 3600)
        XCTAssertEqual(decoded(interval: 24).minCollectInterval, 24 * 3600)
    }

    // MARK: - Host identity

    func testCurrentHostHasAStableNonEmptyIdentity() {
        let first = SharedWorkspace.currentHost
        XCTAssertFalse(first.id.isEmpty)
        XCTAssertEqual(first, SharedWorkspace.currentHost)
    }

    func testDisplayFallsBackToTheIdWhenUnnamed() {
        let unnamed = SharedWorkspace.Host(id: "ABCDEF0123456789", name: "")
        XCTAssertEqual(unnamed.display, "ABCDEF01")
    }

    /// `name` is peer-controlled and reaches Run History notes via `display`
    /// verbatim — a crafted value must not be able to inject a fake log line.
    func testDisplayStripsNewlinesButKeepsTheRestOfTheText() {
        let hostile = SharedWorkspace.Host(id: "AAAA-1111", name: "evil\n[ok] exit 0")
        let rendered = hostile.display
        XCTAssertFalse(rendered.contains("\n"))
        XCTAssertTrue(rendered.contains("[ok] exit 0"))
    }

    func testDisplayCapsAnOverlongName() {
        let long = SharedWorkspace.Host(id: "AAAA-1111", name: String(repeating: "x", count: 200))
        XCTAssertEqual(long.display.count, 64)
    }

    // MARK: - Config clamps

    /// A typo like `claim_ttl_minutes: 1` must not produce a lease that expires
    /// before the collect it guards, and a crashed Mac must not hold one for a week.
    func testClaimTTLIsClamped() {
        XCTAssertEqual(decoded(ttl: 1).claimTTL, 5 * 60)
        XCTAssertEqual(decoded(ttl: 100_000).claimTTL, 720 * 60)
        XCTAssertEqual(decoded(ttl: 45).claimTTL, 45 * 60)
    }

    func testDefaultsAreUsedWhenTheBlockIsAbsent() {
        let config = SharedWorkspaceConfig()
        XCTAssertEqual(config.claimTTL, 45 * 60)
        XCTAssertEqual(config.minCollectInterval, 12 * 3600)
    }

    func testNegativeIntervalIsTreatedAsDisabled() {
        XCTAssertEqual(decoded(interval: -5).minCollectInterval, 0)
    }

    /// Absent means "decide from the volume"; an explicit value always wins so
    /// an unrecognised share can be forced on and a local folder under a synced
    /// path can be forced off.
    func testEnabledIsTriState() {
        XCTAssertTrue(SharedWorkspaceConfig().isEnabled(workspaceIsSynced: true))
        XCTAssertFalse(SharedWorkspaceConfig().isEnabled(workspaceIsSynced: false))
        XCTAssertTrue(decoded(enabled: true).isEnabled(workspaceIsSynced: false))
        XCTAssertFalse(decoded(enabled: false).isEnabled(workspaceIsSynced: true))
    }

    /// Round-trips through the real YAML path rather than a JSON shortcut: the
    /// snake_case key names are part of the contract, and a config block that
    /// decodes from JSON but not from YAML is exactly the 2.6 alert-threshold
    /// defect (a mistyped scalar killed the whole config load).
    private func decoded(
        enabled: Bool? = nil, ttl: Int? = nil, interval: Int? = nil
    ) -> SharedWorkspaceConfig {
        var yaml = "shared_workspace:\n"
        if let enabled { yaml += "  enabled: \(enabled)\n" }
        if let ttl { yaml += "  claim_ttl_minutes: \(ttl)\n" }
        if let interval { yaml += "  min_collect_interval_hours: \(interval)\n" }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-shared-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try yaml.write(to: url, atomically: true, encoding: .utf8)
            guard let shared = try ConfigLoader.load(from: url).sharedWorkspace else {
                XCTFail("shared_workspace block decoded to nil")
                return SharedWorkspaceConfig()
            }
            return shared
        } catch {
            XCTFail("shared_workspace did not decode from YAML: \(error)")
            return SharedWorkspaceConfig()
        }
    }
}
