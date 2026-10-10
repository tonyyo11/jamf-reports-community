import Foundation
import XCTest
@testable import JamfReports

// `config list` is run by `ProfileAuthMethod.resolve` on every collect and by
// `ProfileService.discoverJamfCLIProfiles` on every sidebar load. Both must drain stderr, give
// the child no stdin and stop it at a deadline; a wedged child otherwise freezes a collect that
// holds the tick lock. The stubs are not named `jamf-cli`, since `CLIBridge.codesignGate` keys
// on that filename.
final class ProfileAuthMethodProbeTests: XCTestCase {

    private static let deadline: TimeInterval = 30
    private static let listJSON = #"[{"name":"prod","auth-method":"Platform","default":true}]"#

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileAuthMethodProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        ProfileAuthMethod.invalidateCache()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    private final class Slot<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func makeStub(_ body: String) throws -> URL {
        let stub = tempDir.appendingPathComponent("config-stub-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\n\(body)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    /// Runs `work` off the test thread and fails, rather than hangs, past the deadline.
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
        guard done.wait(timeout: .now() + Self.deadline) == .success else {
            XCTFail("\(label) did not return in \(Int(Self.deadline)) s: a child blocked or hung")
            return nil
        }
        return slot.value
    }

    // MARK: - ProfileAuthMethod.resolve

    func testResolveDoesNotBlockOnAStderrFlood() throws {
        let stub = try makeStub("head -c 300000 /dev/zero >&2\nprintf '%s' '\(Self.listJSON)'")
        let resolved = completes("resolve") {
            ProfileAuthMethod.resolve(profile: "prod", binary: stub)
        }
        XCTAssertEqual(resolved.flatMap { $0 }?.authMethod, "platform")
    }

    func testResolveGivesTheChildNoStdin() throws {
        // `cat` returns at once on /dev/null; on an inherited terminal or pipe it would wait.
        let stub = try makeStub("cat >/dev/null\nprintf '%s' '\(Self.listJSON)'")
        let resolved = completes("resolve") {
            ProfileAuthMethod.resolve(profile: "prod", binary: stub)
        }
        XCTAssertEqual(resolved.flatMap { $0 }?.authMethod, "platform")
    }

    func testResolveStopsAWedgedChildAndReturnsUnknownWithoutCaching() throws {
        let hung = try makeStub("sleep 60")
        let unknown = completes("resolve") {
            ProfileAuthMethod.resolve(profile: "prod", binary: hung, timeout: 1)
        }
        XCTAssertNotNil(unknown, "the call returned")
        XCTAssertNil(unknown.flatMap { $0 }, "a timed-out probe is unknown, never a method")

        // Unknowns are not cached: the next, healthy probe answers.
        let healthy = try makeStub("printf '%s' '\(Self.listJSON)'")
        let resolved = completes("resolve") {
            ProfileAuthMethod.resolve(profile: "prod", binary: healthy)
        }
        XCTAssertEqual(resolved.flatMap { $0 }?.authMethod, "platform")
    }

    // MARK: - ProfileService.discoverJamfCLIProfiles

    func testDiscoveryStopsAWedgedChildAndFallsBack() throws {
        let hung = try makeStub("sleep 60")
        let started = Date()
        let rows = completes("discoverJamfCLIProfiles") {
            ProfileService.discoverJamfCLIProfiles(
                scheduleCounts: [:], _testBinaryOverride: hung, _testTimeout: 1)
        }
        XCTAssertNotNil(rows, "the call returned")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertFalse((rows ?? []).contains { $0.name == "prod" })
    }
}
