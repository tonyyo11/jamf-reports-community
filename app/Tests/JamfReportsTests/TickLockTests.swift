import XCTest
@testable import JamfReports

final class TickLockTests: XCTestCase {

    private func lockURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-\(UUID().uuidString).lock")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAcquireWritesPidAndReleaseRemovesIt() throws {
        let lock = TickLock(url: lockURL())
        XCTAssertTrue(lock.acquire(pid: 4242, isAlive: { _ in true }))
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "4242")
        lock.release(pid: 4242)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.url.path))
    }

    func testLivePidBlocksASecondAcquire() {
        let lock = TickLock(url: lockURL())
        XCTAssertTrue(lock.acquire(pid: 1, isAlive: { _ in true }))
        XCTAssertFalse(lock.acquire(pid: 2, isAlive: { _ in true }))
    }

    func testDeadPidIsTakenOver() throws {
        let lock = TickLock(url: lockURL())
        try Data("99999".utf8).write(to: lock.url)
        XCTAssertTrue(lock.acquire(pid: 7, isAlive: { $0 != 99999 }))
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "7")
    }

    /// Pids are recycled and a run can wedge on a hung network call, so an
    /// alive-looking holder is not enough to block forever.
    func testAnOldLockIsTakenOverEvenWhenItsPidLooksAlive() throws {
        let lock = TickLock(url: lockURL())
        try Data("4242".utf8).write(to: lock.url)
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        XCTAssertTrue(lock.acquire(pid: 7, isAlive: { _ in true }))
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "7")
    }

    func testGarbageLockFileIsTakenOver() throws {
        let lock = TickLock(url: lockURL())
        try Data("not a pid".utf8).write(to: lock.url)
        XCTAssertTrue(lock.acquire(pid: 7, isAlive: { _ in true }))
    }

    /// A takeover must not have its lock deleted by the process it displaced.
    func testReleaseLeavesAFileOwnedByAnotherPidInPlace() throws {
        let lock = TickLock(url: lockURL())
        try Data("7".utf8).write(to: lock.url)
        lock.release(pid: 4242)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.url.path))
    }

    func testTouchResetsTheLockFileModificationDate() throws {
        let lock = TickLock(url: lockURL())
        XCTAssertTrue(lock.acquire(pid: 1, isAlive: { _ in true }))
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        lock.touch()
        let modified = try modificationDate(of: lock.url)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 5)
    }

    // MARK: - claim

    func testClaimNamesALiveHolderElsewhereAndLeavesItsFile() throws {
        let lock = TickLock(url: lockURL())
        try Data("4242".utf8).write(to: lock.url)
        XCTAssertEqual(lock.claim(pid: 7, isAlive: { _ in true }), .heldElsewhere)
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "4242")
    }

    /// One read decides. The holder letting go right after that read still means it held
    /// the lock; a second look used to read the gap as a write failure, and the collect
    /// then ran with no lock at all.
    func testClaimDecidesFromOneReadWhenTheHolderReleasesRightAfter() throws {
        let lock = TickLock(url: lockURL())
        try Data("4242".utf8).write(to: lock.url)
        let claim = lock.claim(pid: 7, isAlive: { _ in
            lock.release(pid: 4242)
            return true
        })
        XCTAssertEqual(claim, .heldElsewhere)
    }

    func testClaimReportsALockFileItCouldNotWrite() {
        let lock = TickLock(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/tick.lock"))
        XCTAssertEqual(lock.claim(pid: 7, isAlive: { _ in true }), .writeFailed)
        XCTAssertFalse(lock.acquire(pid: 7, isAlive: { _ in true }))
    }

    /// The pid is on disk once the write lands, so a failed chmod must not report the lock
    /// as unwritten: the holder would never release a file that names it.
    func testAPermissionsFailureAfterTheWriteStillHoldsTheLock() throws {
        let lock = TickLock(url: lockURL())
        struct Refused: Error {}
        let claim = lock.claim(pid: 7, isAlive: { _ in true }, protect: { _ in throw Refused() })
        XCTAssertEqual(claim, .acquired)
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "7")
        lock.release(pid: 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.url.path))
    }

    /// A second collect in a process that already holds the lock keeps holding it when the
    /// rewrite fails, so the first to finish cannot remove the file under the second.
    func testAFailedRewriteKeepsAHoldThisProcessAlreadyHas() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = TickLock(url: dir.appendingPathComponent("tick.lock"))
        XCTAssertEqual(lock.claim(pid: 7, isAlive: { _ in true }), .acquired)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertEqual(lock.claim(pid: 7, isAlive: { _ in true }), .acquired)
        XCTAssertEqual(lock.claim(pid: 8, isAlive: { _ in false }), .writeFailed)
    }

    // MARK: - isHeldByAnotherLiveProcess

    func testHeldCheckIsFalseForOwnPid() {
        let lock = TickLock(url: lockURL())
        XCTAssertTrue(lock.acquire(pid: 4242, isAlive: { _ in true }))
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
        XCTAssertTrue(lock.acquire(pid: 1, isAlive: { _ in true }))
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        let value = await lock.keepingAlive(every: .milliseconds(20)) { () async -> Int in
            try? await Task.sleep(for: .milliseconds(400))
            return 42
        }
        XCTAssertEqual(value, 42)
        let modified = try modificationDate(of: lock.url)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 5)
    }

    func testKeepingAliveStopsWhenTheBodyReturns() async throws {
        let lock = TickLock(url: lockURL())
        XCTAssertTrue(lock.acquire(pid: 1, isAlive: { _ in true }))
        _ = await lock.keepingAlive(every: .milliseconds(20)) { () async -> Bool in
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
        XCTAssertTrue(lock.acquire(pid: 1, isAlive: { _ in true }))
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        let beats = lock.heartbeat(every: .milliseconds(20))
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
        XCTAssertTrue(lock.acquire(pid: 1, isAlive: { _ in true }))
        let old = Date().addingTimeInterval(-2 * 60 * 60)
        _ = await lock.keepingAlive(every: .milliseconds(20), limit: .milliseconds(100)) {
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
