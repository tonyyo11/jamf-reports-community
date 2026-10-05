import Foundation
import XCTest
@testable import JamfReports

// Single-device detail fetch: jamf-cli's `--out-file` is staged in a private temp file, never at
// a predictable name in the (possibly shared) workspace, and the captured stdout is complete
// before it is used. The stubs are not named `jamf-cli`, since `CLIBridge.codesignGate` keys on
// that filename.
@MainActor
final class DeviceDetailStagingTests: XCTestCase {

    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceDetailStaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.appendingPathComponent("workspaces").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeWorkspace() throws -> (profile: String, devices: URL) {
        let profile = "devstage-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let devices = workspace.appendingPathComponent("jamf-cli-data/devices", isDirectory: true)
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        return (profile, devices)
    }

    private func makeStub(_ body: String) throws -> URL {
        let stub = root.appendingPathComponent("stub-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\n\(body)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    /// A jamf-cli stand-in that records its `--out-file` argument in `log` and writes `payload`
    /// there, as a fixed jamf-cli does.
    private func outFileStub(log: URL, payload: String) throws -> URL {
        try makeStub("""
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--out-file" ]; then out="$2"; fi
          shift
        done
        echo "$out" >> '\(log.path)'
        printf '%s' '\(payload)' > "$out"
        """)
    }

    private func fetch(
        _ bridge: CLIBridge, profile: String, stub: URL
    ) async -> CLIBridge.DeviceDetailResult? {
        await bridge.singleDeviceDetail(
            profile: profile, deviceID: "C02TEST", cacheSubdir: "devices",
            jamfCLIArgs: { ["pro", "device", $0] }, locateJamfCLI: { stub })
    }

    // MARK: - Staging

    func testOutFileIsStagedOutsideTheWorkspaceAndRemoved() async throws {
        let (profile, devices) = try makeWorkspace()
        let log = root.appendingPathComponent("out-files.log")
        let stub = try outFileStub(log: log, payload: #"{"id":"42"}"#)

        let result = await fetch(CLIBridge(), profile: profile, stub: stub)

        let live = try XCTUnwrap(result)
        XCTAssertFalse(live.fromCache)
        XCTAssertEqual(String(decoding: live.data, as: UTF8.self), #"{"id":"42"}"#)
        let cache = try XCTUnwrap(live.cacheURL)
        XCTAssertEqual(cache.deletingLastPathComponent().path, devices.path)
        XCTAssertEqual(try Data(contentsOf: cache), live.data)

        let staged = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(staged.count, 1)
        let stagedURL = URL(fileURLWithPath: try XCTUnwrap(staged.first))
        XCTAssertEqual(
            stagedURL.deletingLastPathComponent().standardizedFileURL.path,
            FileManager.default.temporaryDirectory.standardizedFileURL.path,
            "the out-file must be in the private temp directory, not the workspace")
        XCTAssertTrue(stagedURL.lastPathComponent.hasPrefix("jrc-device-"))
        XCTAssertEqual(stagedURL.pathExtension, "json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path), "staging removed")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: devices.path)
                .filter { $0.hasSuffix(".partial") },
            [], "nothing is staged in the workspace")
        let mode = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
    }

    /// jamf-cli through 1.26 prints the JSON to stdout and never creates the out-file.
    func testStdoutOnlyJamfCLIStillCachesTheDevice() async throws {
        let (profile, _) = try makeWorkspace()
        let stub = try makeStub(#"printf '%s' '{"id":"7"}'"#)

        let result = await fetch(CLIBridge(), profile: profile, stub: stub)

        let live = try XCTUnwrap(result)
        XCTAssertFalse(live.fromCache)
        XCTAssertEqual(String(decoding: live.data, as: UTF8.self), #"{"id":"7"}"#)
    }

    /// A symlink planted at the old predictable staging name must not redirect the write.
    func testPlantedSymlinkAtTheOldStagingNameIsNotFollowed() async throws {
        let (profile, devices) = try makeWorkspace()
        let log = root.appendingPathComponent("out-files.log")
        let stub = try outFileStub(log: log, payload: #"{"id":"42"}"#)
        let bridge = CLIBridge()

        let first = await fetch(bridge, profile: profile, stub: stub)
        let cacheName = try XCTUnwrap(first?.cacheURL?.lastPathComponent)

        let victim = root.appendingPathComponent("victim.txt")
        try "untouched".write(to: victim, atomically: true, encoding: .utf8)
        let planted = devices.appendingPathComponent(".\(cacheName).partial")
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: victim)

        let second = await fetch(bridge, profile: profile, stub: stub)

        XCTAssertNotNil(second)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "untouched")
    }

    /// A symlink at the cache name itself is replaced, not written through.
    func testPlantedSymlinkAtTheCacheNameIsReplaced() async throws {
        let (profile, devices) = try makeWorkspace()
        let log = root.appendingPathComponent("out-files.log")
        let stub = try outFileStub(log: log, payload: #"{"id":"42"}"#)
        let bridge = CLIBridge()
        let first = await fetch(bridge, profile: profile, stub: stub)
        let cache = try XCTUnwrap(first?.cacheURL)
        XCTAssertEqual(cache.deletingLastPathComponent().path, devices.path)

        let victim = root.appendingPathComponent("victim.txt")
        try "untouched".write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: victim)

        _ = await fetch(bridge, profile: profile, stub: stub)

        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "untouched")
        XCTAssertEqual(try Data(contentsOf: cache), Data(#"{"id":"42"}"#.utf8))
    }

    // MARK: - Environment

    /// The child gets `environmentForJamfCLI()`, not the parent's environment.
    func testChildDoesNotInheritTheParentEnvironment() async throws {
        setenv("JRC_ENV_LEAK_PROBE", "leaked", 1)
        defer { unsetenv("JRC_ENV_LEAK_PROBE") }
        let stub = try makeStub("env")
        let dest = root.appendingPathComponent("env.txt")

        let exit = await runDeviceDetailProcess(
            executable: stub, arguments: [], outputDirectory: root, stdoutFallbackFile: dest)

        XCTAssertEqual(exit, 0)
        let seen = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertFalse(seen.contains("JRC_ENV_LEAK_PROBE"), "the parent's variables must not leak")
        XCTAssertTrue(seen.contains("PATH="), "the pinned environment is still passed")
    }

    // MARK: - Complete stdout

    /// The child writes more than the pipe buffer and exits at once; the last chunk must not be
    /// dropped when the handlers are torn down after the exit.
    func testCapturedStdoutIsCompleteAfterAFastExit() async throws {
        let stub = try makeStub("head -c 200000 /dev/zero | tr '\\0' x")
        for round in 0..<40 {
            let dest = root.appendingPathComponent("captured-\(round).json")
            let exit = await runDeviceDetailProcess(
                executable: stub, arguments: ["pro", "device", "1"],
                outputDirectory: root, stdoutFallbackFile: dest)
            XCTAssertEqual(exit, 0)
            let size = (try? Data(contentsOf: dest).count) ?? -1
            XCTAssertEqual(size, 200_000, "round \(round) captured a truncated stdout")
            try? FileManager.default.removeItem(at: dest)
        }
    }
}
