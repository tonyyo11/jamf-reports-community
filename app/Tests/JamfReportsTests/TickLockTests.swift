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
        let attributes = try FileManager.default.attributesOfItem(atPath: lock.url.path)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 5)
    }
}
