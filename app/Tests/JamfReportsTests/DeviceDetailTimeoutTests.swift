import Foundation
import XCTest
@testable import JamfReports

// A `pro device` lookup that never answers stops at its limit and falls back to the cached
// copy, instead of holding the Device Lookup screen for ever. The stubs are not named
// `jamf-cli`, since `CLIBridge.codesignGate` keys on that filename.
@MainActor
final class DeviceDetailTimeoutTests: XCTestCase {

    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceDetailTimeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.appendingPathComponent("workspaces").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [CLIBridge.LogLine] = []
        var all: [CLIBridge.LogLine] {
            lock.lock(); defer { lock.unlock() }; return stored
        }
        func add(_ line: CLIBridge.LogLine) {
            lock.lock(); stored.append(line); lock.unlock()
        }
    }

    private func makeStub(_ body: String) throws -> URL {
        let stub = root.appendingPathComponent("stub-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\n\(body)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    func testAWedgedLookupReturnsTimedOutAndOneFailLine() async throws {
        let stub = try makeStub("exec sleep 30")
        let lines = Lines()

        let start = Date()
        let exit = await runDeviceDetailProcess(
            executable: stub, arguments: ["pro", "device", "1"], outputDirectory: root,
            timeout: 1, onLine: { lines.add($0) })

        XCTAssertEqual(exit, CLIBridge.exitCodeTimedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        let fails = lines.all.filter { $0.level == .fail }
        XCTAssertEqual(fails.count, 1)
        XCTAssertTrue(fails.first?.text.contains("did not answer") == true)
    }

    func testATimedOutLookupFallsBackToTheCachedCopy() async throws {
        let profile = "devtimeout-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let devices = workspace.appendingPathComponent("jamf-cli-data/devices", isDirectory: true)
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        let stub = try makeStub("exec sleep 30")
        let args: @Sendable (String) -> [String] = { ["pro", "device", $0] }

        // Seed the cache by letting a stub answer once.
        let seeded = try makeStub(#"printf '%s' '{"id":"9"}'"#)
        let first = await CLIBridge().singleDeviceDetail(
            profile: profile, deviceID: "C02TEST", cacheSubdir: "devices",
            jamfCLIArgs: args, locateJamfCLI: { seeded })
        XCTAssertEqual(first?.fromCache, false)

        let lines = Lines()
        let result = await CLIBridge().singleDeviceDetail(
            profile: profile, deviceID: "C02TEST", cacheSubdir: "devices",
            jamfCLIArgs: args, locateJamfCLI: { stub }, timeout: 1, onLine: { lines.add($0) })

        XCTAssertEqual(result?.fromCache, true)
        XCTAssertEqual(result.map { String(decoding: $0.data, as: UTF8.self) }, #"{"id":"9"}"#)
        XCTAssertEqual(lines.all.filter { $0.level == .fail }.count, 1)
    }
}
