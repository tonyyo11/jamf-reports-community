import Darwin
import Foundation
import XCTest
@testable import JamfReports

// Short jamf-cli queries (`--version`, `version -o json`) stop at a deadline instead of waiting
// for ever, and no jamf-cli spawn inherits the caller's stdin. The stubs are not named
// `jamf-cli`, since `CLIBridge.codesignGate` keys on that filename.
@MainActor
final class JamfCLIProbeTests: XCTestCase {

    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JamfCLIProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeStub(_ body: String) throws -> URL {
        let stub = dir.appendingPathComponent("stub-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\n\(body)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    /// Seconds `work` took; the probe must give up well inside the stub's 30 s sleep.
    private func elapsed(_ work: () -> Void) -> TimeInterval {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    private static let slowBound: TimeInterval = 15

    // MARK: - Deadline

    func testInstalledVersionGivesUpOnAWedgedBinary() throws {
        let stub = try makeStub("exec sleep 30")
        var version: String?
        let took = elapsed { version = JamfCLIInstaller.installedVersion(at: stub, timeout: 1) }
        XCTAssertNil(version)
        XCTAssertLessThan(took, Self.slowBound)
    }

    func testSpecProVersionGivesUpOnAWedgedBinary() throws {
        let stub = try makeStub("exec sleep 30")
        var version: String?
        let took = elapsed { version = JamfCLIInstaller.specProVersion(at: stub, timeout: 1) }
        XCTAssertNil(version)
        XCTAssertLessThan(took, Self.slowBound)
    }

    func testProvenanceVersionGivesUpOnAWedgedBinary() async throws {
        let stub = try makeStub("exec sleep 30")
        let start = Date()
        let version = await Provenance.captureJamfCLIVersion(jamfCLIURL: stub, timeout: 1)
        XCTAssertNil(version)
        XCTAssertLessThan(Date().timeIntervalSince(start), Self.slowBound)
    }

    /// The stopped shell leaves a background child holding the pipes; the probe must not wait
    /// for their EOF.
    func testProbeDoesNotWaitForAGrandchildHoldingThePipes() throws {
        let stub = try makeStub("sleep 10 &\nwait")
        var output: JamfCLIProbe.Output?
        let took = elapsed {
            output = JamfCLIProbe.run(executable: stub, arguments: [], timeout: 1)
        }
        XCTAssertNil(output)
        XCTAssertLessThan(took, 8)
    }

    func testProbeReturnsTheOutputOfAChildThatAnswers() throws {
        let stub = try makeStub("echo 'jamf-cli version 1.31.1'\necho warn >&2\nexit 3")
        let output = try XCTUnwrap(JamfCLIProbe.run(executable: stub, arguments: []))
        XCTAssertEqual(output.exitCode, 3)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "jamf-cli version 1.31.1\n")
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "warn\n")
        XCTAssertEqual(JamfCLIInstaller.installedVersion(at: stub), "1.31.1")
    }

    // MARK: - stdin

    private var nullDeviceRdev: dev_t {
        var info = stat()
        XCTAssertEqual(stat("/dev/null", &info), 0)
        return info.st_rdev
    }

    /// A stub that says whether its stdin is /dev/null.
    private func stdinReporter() throws -> URL {
        try makeStub(
            "if [ \"$(stat -Lf %r /dev/fd/0)\" = \"\(nullDeviceRdev)\" ]; then echo null; "
                + "else echo inherited; fi")
    }

    /// Runs `body` with this process's fd 0 pointing at a pipe, so a child that inherits it is
    /// distinguishable from one given /dev/null whatever the harness started with.
    private func withStdinAPipe<T>(_ body: () async throws -> T) async rethrows -> T {
        let saved = dup(0)
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        dup2(fds[0], 0)
        defer {
            dup2(saved, 0)
            close(saved)
            close(fds[0])
            close(fds[1])
        }
        return try await body()
    }

    func testProbeChildReadsFromTheNullDevice() async throws {
        let stub = try stdinReporter()
        let output = await withStdinAPipe {
            JamfCLIProbe.run(executable: stub, arguments: [])
        }
        XCTAssertEqual(output.map { String(decoding: $0.stdout, as: UTF8.self) }, "null\n")
    }

    func testRunAndCaptureChildReadsFromTheNullDevice() async throws {
        let stub = try stdinReporter()
        let (_, data) = try await withStdinAPipe {
            try await CLIBridge().runAndCapture(
                executable: stub, arguments: [], onLine: { _ in })
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "null\n")
    }

    func testRunChildReadsFromTheNullDevice() async throws {
        let stub = try stdinReporter()
        let seen = LineBox()
        _ = try await withStdinAPipe {
            try await CLIBridge().run(
                executable: stub, arguments: [], onLine: { seen.append($0.text) })
        }
        XCTAssertEqual(seen.lines, ["null"])
    }

    func testDeviceDetailChildReadsFromTheNullDevice() async throws {
        let stub = try stdinReporter()
        let dest = dir.appendingPathComponent("stdin.txt")
        _ = await withStdinAPipe {
            await runDeviceDetailProcess(
                executable: stub, arguments: [], outputDirectory: dir, stdoutFallbackFile: dest)
        }
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "null\n")
    }

    func testProfileDiscoveryChildReadsFromTheNullDevice() async throws {
        let rdev = nullDeviceRdev
        let stub = try makeStub(
            "if [ \"$(stat -Lf %r /dev/fd/0)\" = \"\(rdev)\" ]; then "
                + "echo '[{\"name\":\"stdin-null\",\"default\":false}]'; else echo '[]'; fi")
        let rows = await withStdinAPipe {
            ProfileService.discoverJamfCLIProfiles(scheduleCounts: [:], _testBinaryOverride: stub)
        }
        XCTAssertEqual(rows.map(\.name), ["stdin-null"])
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
