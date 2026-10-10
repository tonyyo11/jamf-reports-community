import Darwin
import XCTest
@testable import JamfReports

/// The installer's child processes (brew, tar, unzip) run with a limit, because an update holds
/// the tick lock and a hung `brew update` would otherwise refuse every collect for hours.
final class JamfCLIInstallerTimeoutTests: XCTestCase {
    nonisolated(unsafe) private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func stub(_ name: String, body: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func test_runProcess_stopsAChildThatOutlivesItsLimit() async throws {
        let pidFile = scratch.appendingPathComponent("pid")
        let sleeper = try stub("sleep-stub", body: "echo $$ > '\(pidFile.path)'\nexec sleep 30")
        let started = Date()
        let result = await JamfCLIInstaller.runProcess(
            executable: sleeper, arguments: [], environment: nil, timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        let pid = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        // The pid is reaped by Foundation once it has exited; give the kernel a moment.
        var gone = false
        for _ in 0..<40 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(gone, "child \(pid) is still running after the timeout")
    }

    func test_runProcess_aFastChildStillSucceeds() async throws {
        let quick = try stub("quick-stub", body: "echo done")
        let result = await JamfCLIInstaller.runProcess(
            executable: quick, arguments: [], environment: nil, timeout: 10)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    func test_runProcessSync_stopsAChildThatOutlivesItsLimit() throws {
        let sleeper = try stub("sleep-stub", body: "exec sleep 30")
        let started = Date()
        let result = JamfCLIInstaller.runProcessSync(
            executable: sleeper, arguments: [], environment: nil, timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func test_failureText_namesTheCommandAndTheLimitOnATimeout() {
        let timedOut = JamfCLIInstaller.CommandResult(
            exitCode: 15, stdout: "", stderr: "", timedOut: true, timeout: 300)
        XCTAssertEqual(
            JamfCLIInstaller.failureText("brew update", timedOut),
            "brew update did not finish within 300 s")
        let failed = JamfCLIInstaller.CommandResult(
            exitCode: 1, stdout: "", stderr: "no network", timedOut: false, timeout: 300)
        XCTAssertEqual(
            JamfCLIInstaller.failureText("brew update", failed),
            "brew update failed: no network")
    }
}
