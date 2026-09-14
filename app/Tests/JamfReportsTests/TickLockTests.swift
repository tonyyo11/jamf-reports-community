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
