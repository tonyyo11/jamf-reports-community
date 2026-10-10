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
        // A second descriptor in this process conflicts with the claimer's, as a second
        // process would; the file names the spawned process, which the probe finds alive.
        let hold = try XCTUnwrap(lock.claimedHold(pid: tick.processIdentifier))
        try await body()
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8),
                       String(tick.processIdentifier), "another process's lock is left alone")
        hold.release()
    }
}

extension TickLock.Claim {
    /// `acquired`, `heldElsewhere` or `writeFailed`, for comparing in an assertion.
    var kind: String {
        switch self {
        case .acquired: "acquired"
        case .heldElsewhere: "heldElsewhere"
        case .writeFailed: "writeFailed"
        }
    }
}

extension TickLock {
    /// The hold from a `claim` for `pid`; nil unless it was acquired.
    func claimedHold(pid: Int32 = getpid()) -> TickLockHold? {
        if case .acquired(let hold) = claim(pid: pid) { return hold }
        return nil
    }

    /// No holder is named: a released lock leaves its file in place, empty.
    var namesNoHolder: Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
