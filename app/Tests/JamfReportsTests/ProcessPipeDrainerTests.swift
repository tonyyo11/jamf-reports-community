import Foundation
import XCTest
@testable import JamfReports

// `finish()` must return what the child wrote without waiting for EOF: a grandchild that
// inherited the pipe holds it open for as long as it lives.
final class ProcessPipeDrainerTests: XCTestCase {

    private static let guardSeconds: TimeInterval = 30
    private static let flood = 300_000

    private final class Slot<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// Runs `work` off the test thread and fails, rather than hangs, when it outlives the guard.
    private func completes<T: Sendable>(
        _ label: String, _ work: @escaping @Sendable () -> T
    ) -> T? {
        let slot = Slot<T>()
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            slot.value = work()
            done.leave()
        }
        guard done.wait(timeout: .now() + Self.guardSeconds) == .success else {
            XCTFail("\(label) did not return in \(Int(Self.guardSeconds)) s")
            return nil
        }
        return slot.value
    }

    /// Starts `/bin/sh -c script` with stdout on a drainer and waits for the shell to exit.
    private func runShell(_ script: String) throws -> ProcessPipeDrainer {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        let drainer = ProcessPipeDrainer(pipe: pipe)
        try process.run()
        drainer.start()
        process.waitUntilExit()
        return drainer
    }

    func testFinishDoesNotWaitForAGrandchildHoldingThePipe() throws {
        let drainer = try runShell("echo hi; sleep 30 & echo $!")
        var pid: pid_t?
        defer { if let pid { kill(pid, SIGKILL) } }

        let start = Date()
        let data = try XCTUnwrap(completes("finish") { drainer.finish() })
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        pid = lines.last.flatMap { pid_t($0) }

        XCTAssertEqual(lines.first, "hi")
        XCTAssertEqual(lines.count, 2, "got \(text.debugDescription)")
        XCTAssertNotNil(pid)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testFinishReturnsEveryByteOfAFloodThatThenExits() throws {
        let drainer = try runShell("head -c \(Self.flood) /dev/zero")
        let data = completes("finish") { drainer.finish() }
        XCTAssertEqual(data?.count, Self.flood)
    }

    func testFinishReturnsBytesWrittenRightBeforeExit() throws {
        let drainer = try runShell("printf first; printf second; exit 3")
        let data = completes("finish") { drainer.finish() }
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "firstsecond")
    }
}
