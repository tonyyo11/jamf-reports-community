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
        lock.release()
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

    func testGarbageLockFileIsTakenOver() throws {
        let lock = TickLock(url: lockURL())
        try Data("not a pid".utf8).write(to: lock.url)
        XCTAssertTrue(lock.acquire(pid: 7, isAlive: { _ in true }))
    }
}
