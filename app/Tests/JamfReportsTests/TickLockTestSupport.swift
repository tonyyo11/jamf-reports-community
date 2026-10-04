import Foundation
import XCTest
@testable import JamfReports

/// A live process that is not this one, for "held by another live process". The caller
/// terminates it and waits for it.
func spawnLiveForeignProcess() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    try process.run()
    return process
}

extension XCTestCase {
    /// Points `CLIBridge.tickLock` at a temporary file for this test and restores the
    /// previous seam at teardown, so no test reads or writes the background item's lock.
    @MainActor
    func useTemporaryTickLock() -> TickLock {
        let lock = TickLock(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-\(UUID().uuidString).lock"))
        let saved = CLIBridge.tickLock
        CLIBridge.tickLock = { lock }
        addTeardownBlock { @MainActor in
            CLIBridge.tickLock = saved
            try? FileManager.default.removeItem(at: lock.url)
        }
        return lock
    }

    /// Runs `body` while a spawned process — a tick, as far as this process can tell —
    /// holds `lock`, then frees the lock and kills the process.
    @MainActor
    func whileAnotherProcessHolds(
        _ lock: TickLock, _ body: () async throws -> Void
    ) async throws {
        let tick = try spawnLiveForeignProcess()
        defer {
            tick.terminate()
            tick.waitUntilExit()
        }
        XCTAssertTrue(lock.acquire(pid: tick.processIdentifier))
        try await body()
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8),
                       String(tick.processIdentifier), "another process's lock is left alone")
        lock.release(pid: tick.processIdentifier)
    }
}
