import XCTest
@testable import JamfReports

final class TickLockTests: XCTestCase {

    private func lockURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-\(UUID().uuidString).lock")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testClaimWritesPidAndReleaseLeavesTheFileEmpty() throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 4242))
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "4242")
        hold.release()
        XCTAssertTrue(lock.namesNoHolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.url.path),
                      "the file is never unlinked: two inodes would give two locks")
    }

    func testASecondClaimInTheSameProcessIsHeldElsewhere() throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 100))
        defer { hold.release() }
        XCTAssertEqual(lock.claim(pid: 2).kind, "heldElsewhere")
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "100",
                       "the turned-away claim leaves the holder's file alone")
    }

    func testReleaseThenClaimSucceeds() throws {
        let lock = TickLock(url: lockURL())
        try XCTUnwrap(lock.claimedHold(pid: 100)).release()
        let second = try XCTUnwrap(lock.claimedHold(pid: 7))
        defer { second.release() }
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "7")
    }

    func testReleaseIsIdempotentAndDoesNotFreeANewHolder() throws {
        let lock = TickLock(url: lockURL())
        let first = try XCTUnwrap(lock.claimedHold(pid: 100))
        first.release()
        let second = try XCTUnwrap(lock.claimedHold(pid: 7))
        defer { second.release() }
        first.release()
        XCTAssertEqual(lock.claim(pid: 8).kind, "heldElsewhere", "a spent hold frees nothing")
    }

    /// The kernel drops the lock with the descriptor, so a holder that is gone, whatever pid
    /// the file still names, never blocks a claim.
    func testALockWhoseHolderIsGoneIsClaimableEvenWithAPidInTheFile() throws {
        let lock = TickLock(url: lockURL())
        try Data("99999".utf8).write(to: lock.url)
        let hold = try XCTUnwrap(lock.claimedHold(pid: 7))
        defer { hold.release() }
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "7")
    }

    /// The sleep case: a Mac asleep mid-collect wakes with the holder's mtime hours old and its
    /// heartbeat not yet run. The kernel lock still stands, so no second run starts.
    func testAnOldMtimeWithALiveHolderIsStillHeldElsewhere() throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 100))
        defer { hold.release() }
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        XCTAssertEqual(lock.claim(pid: 7).kind, "heldElsewhere")
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "100")
        XCTAssertFalse(lock.isHeldByAnotherLiveProcess(pid: 7, isAlive: { _ in true }),
                       "the probe's mtime heuristic is separate from the kernel lock")
    }

    /// The heartbeat's give-up closes the descriptor, which is what lets a wedged live
    /// holder's lock be claimed.
    func testAHoldThatGaveUpIsClaimable() async throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 100))
        let beats = hold.heartbeat(every: .milliseconds(10), limit: .milliseconds(50))
        await beats.value
        XCTAssertTrue(lock.namesNoHolder, "a given-up lock names nobody, so the probe lets go")
        let next = try XCTUnwrap(lock.claimedHold(pid: 7))
        next.release()
    }

    func testALockFileThatIsASymlinkIsRefused() throws {
        let target = lockURL()
        try Data("untouched".utf8).write(to: target)
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-link-\(UUID().uuidString).lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        XCTAssertEqual(TickLock(url: link).claim(pid: 7).kind, "writeFailed")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "untouched")
    }

    func testTheLockFileIsPrivateToTheOwner() throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 7))
        defer { hold.release() }
        let attributes = try FileManager.default.attributesOfItem(atPath: lock.url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    /// The pid is on disk once the write lands, so a failed chmod must not report the lock
    /// as unwritten: the holder would never release a file that names it.
    func testAPermissionsFailureAfterTheWriteStillHoldsTheLock() throws {
        let lock = TickLock(url: lockURL())
        struct Refused: Error {}
        guard case .acquired(let hold) = lock.claim(pid: 7, protect: { _ in throw Refused() })
        else { return XCTFail("the claim must stand") }
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "7")
        hold.release()
        XCTAssertTrue(lock.namesNoHolder)
    }

    func testClaimReportsALockFileItCouldNotWrite() {
        let lock = TickLock(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/tick.lock"))
        XCTAssertEqual(lock.claim(pid: 7).kind, "writeFailed")
    }

    func testTouchResetsTheLockFileModificationDate() throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 100))
        defer { hold.release() }
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        hold.touch()
        let modified = try modificationDate(of: lock.url)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 5)
    }

    // MARK: - The probe reads a live holder

    func testTheProbeSeesALiveHolderWithoutAcquiringOrWriting() throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 4242))
        defer { hold.release() }
        XCTAssertTrue(lock.isHeldByAnotherLiveProcess(pid: 7, isAlive: { _ in true }))
        XCTAssertFalse(lock.isHeldByAnotherLiveProcess(pid: 4242, isAlive: { _ in true }),
                       "the holder itself is not another process")
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "4242")
        XCTAssertEqual(lock.claim(pid: 8).kind, "heldElsewhere", "probing left the lock held")
    }

    func testTheProbeLetsGoOfAReleasedLock() throws {
        let lock = TickLock(url: lockURL())
        try XCTUnwrap(lock.claimedHold(pid: 4242)).release()
        XCTAssertFalse(lock.isHeldByAnotherLiveProcess(pid: 7, isAlive: { _ in true }))
    }

    // MARK: - isHeldByAnotherLiveProcess

    func testHeldCheckIsFalseForOwnPid() throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 4242))
        defer { hold.release() }
        XCTAssertFalse(lock.isHeldByAnotherLiveProcess(pid: 4242, isAlive: { _ in true }))
    }

    func testHeldCheckIsFalseForDeadPid() throws {
        let lock = TickLock(url: lockURL())
        try Data("99999".utf8).write(to: lock.url)
        XCTAssertFalse(lock.isHeldByAnotherLiveProcess(pid: 7, isAlive: { _ in false }))
    }

    func testHeldCheckIsTrueForALiveOtherPidAndNeverWrites() throws {
        let lock = TickLock(url: lockURL())
        try Data("4242".utf8).write(to: lock.url)
        // Recent enough not to be stale; old enough that a stray touch shows.
        let recent = Date().addingTimeInterval(-10 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: recent], ofItemAtPath: lock.url.path)
        XCTAssertTrue(lock.isHeldByAnotherLiveProcess(pid: 7, isAlive: { _ in true }))
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "4242")
        let modified = try modificationDate(of: lock.url)
        XCTAssertLessThan(abs(modified.timeIntervalSince(recent)), 1)
    }

    func testHeldCheckIsFalseForAStaleLock() throws {
        let lock = TickLock(url: lockURL())
        try Data("4242".utf8).write(to: lock.url)
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        XCTAssertFalse(lock.isHeldByAnotherLiveProcess(pid: 7, isAlive: { _ in true }))
    }

    func testHeldCheckIsFalseWithNoLockFileOrAGarbageOne() throws {
        let lock = TickLock(url: lockURL())
        XCTAssertFalse(lock.isHeldByAnotherLiveProcess(pid: 7, isAlive: { _ in true }))
        try Data("not a pid".utf8).write(to: lock.url)
        XCTAssertFalse(lock.isHeldByAnotherLiveProcess(pid: 7, isAlive: { _ in true }))
    }

    // MARK: - Heartbeat

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    /// A run longer than `staleAfter` must keep the lock fresh, or the next
    /// wake takes it over mid-collect.
    func testKeepingAliveTouchesTheLockWhileTheBodyRuns() async throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 100))
        defer { hold.release() }
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        let value = await hold.keepingAlive(every: .milliseconds(20)) { () async -> Int in
            try? await Task.sleep(for: .milliseconds(400))
            return 42
        }
        XCTAssertEqual(value, 42)
        let modified = try modificationDate(of: lock.url)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 5)
    }

    func testKeepingAliveStopsWhenTheBodyReturns() async throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 100))
        defer { hold.release() }
        _ = await hold.keepingAlive(every: .milliseconds(20)) { () async -> Bool in
            try? await Task.sleep(for: .milliseconds(100))
            return true
        }
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        try await Task.sleep(for: .milliseconds(200))
        let modified = try modificationDate(of: lock.url)
        XCTAssertLessThan(abs(modified.timeIntervalSince(old)), 1)
    }

    /// A manual GUI collect cannot hand its body to `keepingAlive`, so it runs the beats
    /// itself and cancels them when the collect ends.
    func testHeartbeatTouchesTheLockUntilCancelled() async throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 100))
        defer { hold.release() }
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        let beats = hold.heartbeat(every: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(200))
        let touched = try modificationDate(of: lock.url)
        XCTAssertLessThan(abs(touched.timeIntervalSinceNow), 5)

        beats.cancel()
        await beats.value
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        try await Task.sleep(for: .milliseconds(200))
        let after = try modificationDate(of: lock.url)
        XCTAssertLessThan(abs(after.timeIntervalSince(old)), 1,
                          "a cancelled heartbeat must not touch the lock again")
    }

    func testKeepingAliveStopsBeatingAfterItsLimit() async throws {
        let lock = TickLock(url: lockURL())
        let hold = try XCTUnwrap(lock.claimedHold(pid: 100))
        defer { hold.release() }
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        _ = await hold.keepingAlive(every: .milliseconds(20), limit: .milliseconds(100)) {
            () async -> Bool in
            try? await Task.sleep(for: .milliseconds(200))
            try? FileManager.default.setAttributes(
                [.modificationDate: old], ofItemAtPath: lock.url.path)
            try? await Task.sleep(for: .milliseconds(200))
            return true
        }
        let modified = try modificationDate(of: lock.url)
        XCTAssertLessThan(abs(modified.timeIntervalSince(old)), 1,
                          "a wedged run must stop refreshing the lock once the limit passes")
    }
}
