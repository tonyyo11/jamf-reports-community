import Foundation
import XCTest
@testable import JamfReports

// jamf-cli probes (`config list`, `version -o json`, `--version`) must read their output while the
// child runs: a child that writes more than the pipe buffer (about 64 KB) blocks until someone
// reads, and a parent that waits for exit first never reads. The stubs are not named `jamf-cli`,
// since `CLIBridge.codesignGate` keys on that filename.
final class ProbeOutputDrainTests: XCTestCase {

    private static let deadline: TimeInterval = 30
    private static let flood = 300_000

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProbeOutputDrain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private final class Slot<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func makeStub(_ body: String) throws -> URL {
        let stub = tempDir.appendingPathComponent("probe-stub-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\n\(body)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    /// Runs `work` off the test thread and fails the test, rather than hanging it, when it has
    /// not returned by the deadline.
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
            XCTFail("\(label) did not return within \(Int(Self.deadline)) s: a child blocked on a full pipe")
            return nil
        }
        return slot.value
    }

    private func profileListJSON(count: Int) throws -> URL {
        let rows = (0..<count).map {
            "{\"name\":\"profile-\($0)\",\"url\":\"https://tenant-\($0).example.invalid\","
                + "\"auth-method\":\"oauth2\",\"default\":false}"
        }
        let url = tempDir.appendingPathComponent("profiles.json")
        try ("[" + rows.joined(separator: ",") + "]").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var stderrFlood: String { "head -c \(Self.flood) /dev/zero >&2" }

    // MARK: - ProfileService.discoverJamfCLIProfiles

    func testDiscoveryReadsMoreThanAPipeBufferOfStdout() throws {
        let fixture = try profileListJSON(count: 3_000)
        XCTAssertGreaterThan(
            try Data(contentsOf: fixture).count, 200_000, "fixture must exceed the pipe buffer")
        let stub = try makeStub("cat '\(fixture.path)'")
        let rows = completes("discoverJamfCLIProfiles") {
            ProfileService.discoverJamfCLIProfiles(scheduleCounts: [:], _testBinaryOverride: stub)
        }
        XCTAssertEqual(rows?.count, 3_000)
    }

    func testDiscoveryDoesNotBlockOnAStderrFlood() throws {
        let fixture = try profileListJSON(count: 3)
        let stub = try makeStub("cat '\(fixture.path)'\n\(stderrFlood)")
        let rows = completes("discoverJamfCLIProfiles") {
            ProfileService.discoverJamfCLIProfiles(scheduleCounts: [:], _testBinaryOverride: stub)
        }
        XCTAssertEqual(rows?.map(\.name), ["profile-0", "profile-1", "profile-2"])
    }

    // MARK: - JamfCLIInstaller.specProVersion

    func testSpecProVersionReadsMoreThanAPipeBufferOfStdout() throws {
        let stub = try makeStub(
            "printf '{\"version\":\"1.29.0\",\"specProVersion\":\"1.29.0\",\"pad\":\"'\n"
                + "head -c \(Self.flood) /dev/zero | tr '\\0' x\nprintf '\"}'"
        )
        let version = completes("specProVersion") { JamfCLIInstaller.specProVersion(at: stub) }
        XCTAssertEqual(version, .some("1.29.0"))
    }

    func testSpecProVersionDoesNotBlockOnAStderrFlood() throws {
        let stub = try makeStub(
            "printf '{\"version\":\"1.29.0\",\"specProVersion\":\"1.29.0\"}'\n\(stderrFlood)"
        )
        let version = completes("specProVersion") { JamfCLIInstaller.specProVersion(at: stub) }
        XCTAssertEqual(version, .some("1.29.0"))
    }

    // MARK: - Provenance.captureJamfCLIVersion

    private func provenanceVersion(of stub: URL) -> String?? {
        let slot = Slot<String?>()
        let done = DispatchGroup()
        done.enter()
        Task.detached {
            slot.value = .some(await Provenance.captureJamfCLIVersion(jamfCLIURL: stub))
            done.leave()
        }
        guard done.wait(timeout: .now() + Self.deadline) == .success else {
            XCTFail("captureJamfCLIVersion did not return within \(Int(Self.deadline)) s")
            return nil
        }
        return slot.value
    }

    func testProvenanceVersionReadsMoreThanAPipeBufferOfStdout() throws {
        let stub = try makeStub("echo 'jamf-cli version 1.29.0'\nhead -c \(Self.flood) /dev/zero | tr '\\0' x")
        XCTAssertEqual(provenanceVersion(of: stub), .some("jamf-cli version 1.29.0"))
    }

    func testProvenanceVersionDoesNotBlockOnAStderrFlood() throws {
        let stub = try makeStub("echo 'jamf-cli version 1.29.0'\n\(stderrFlood)")
        XCTAssertEqual(provenanceVersion(of: stub), .some("jamf-cli version 1.29.0"))
    }
}
