import Foundation
import XCTest
@testable import JamfReports

// Tests for M-01: the JamfCLIIdentity verified-fingerprint cache that
// allows CLIBridge.run / runAndCapture to short-circuit repeat
// verifications cheaply. A cache miss falls through to a full
// CodeSignVerifier check; a hit (same path + size + mtime) skips it.
// A binary swap changes either size or mtime, invalidating the cache.
final class JamfCLIIdentityVerificationCacheTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!
    nonisolated(unsafe) private var binary: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("JamfCLIIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        binary = tempDir.appendingPathComponent("jamf-cli")
        try Data("fake-jamf-cli-v1".utf8).write(to: binary)
        JamfCLIIdentity.clearVerificationCacheForTesting()
    }

    override func tearDownWithError() throws {
        JamfCLIIdentity.clearVerificationCacheForTesting()
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        binary = nil
        try super.tearDownWithError()
    }

    // MARK: - Verifier is invoked on cache miss

    func testFullVerifyOnCacheMiss() {
        let counter = SendableCounter()
        let verify: @Sendable (URL, String) -> Bool = { _, _ in
            counter.increment()
            return true
        }
        let result = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: binary, verify: verify)
        XCTAssertNoThrow(try result.get(), "Successful verify must succeed")
        XCTAssertEqual(counter.value, 1, "Verifier must be invoked once on a fresh cache")
    }

    // MARK: - Verifier is skipped on cache hit

    func testCacheHitSkipsRepeatVerify() {
        let counter = SendableCounter()
        let verify: @Sendable (URL, String) -> Bool = { _, _ in
            counter.increment()
            return true
        }
        _ = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: binary, verify: verify)
        _ = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: binary, verify: verify)
        _ = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: binary, verify: verify)
        XCTAssertEqual(counter.value, 1,
                       "Verifier must be invoked exactly once across repeat calls with unchanged (path,size,mtime)")
    }

    // MARK: - Size change invalidates the cache

    func testCacheInvalidatedOnSizeChange() throws {
        let counter = SendableCounter()
        let verify: @Sendable (URL, String) -> Bool = { _, _ in
            counter.increment()
            return true
        }
        _ = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: binary, verify: verify)
        XCTAssertEqual(counter.value, 1)

        // Rewrite the binary with a different size.
        try Data("fake-jamf-cli-v2-longer-bytes".utf8).write(to: binary)

        _ = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: binary, verify: verify)
        XCTAssertEqual(counter.value, 2, "A binary swap (different size) must re-trigger verification")
    }

    // MARK: - mtime change invalidates the cache

    func testCacheInvalidatedOnMtimeChange() throws {
        let counter = SendableCounter()
        let verify: @Sendable (URL, String) -> Bool = { _, _ in
            counter.increment()
            return true
        }
        _ = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: binary, verify: verify)
        XCTAssertEqual(counter.value, 1)

        // Same content, but bump mtime forward — e.g. a homebrew upgrade
        // that happens to land identical bytes still touches mtime.
        let future = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: future],
                                              ofItemAtPath: binary.path)

        _ = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: binary, verify: verify)
        XCTAssertEqual(counter.value, 2, "An mtime bump (e.g. legitimate upgrade) must re-trigger verification")
    }

    // MARK: - Verifier failure returns an error and does not cache

    func testVerifierFailureReturnsUntrustedAndDoesNotCache() {
        let counter = SendableCounter()
        let verify: @Sendable (URL, String) -> Bool = { _, _ in
            counter.increment()
            return false
        }
        let result = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: binary, verify: verify)
        XCTAssertThrowsError(try result.get()) { error in
            guard case JamfCLIIdentity.VerifyError.untrusted = error else {
                XCTFail("Expected .untrusted, got \(error)")
                return
            }
        }
        // A second call must still invoke the verifier — a failed verify
        // must NOT be cached as success.
        let again = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: binary, verify: verify)
        XCTAssertThrowsError(try again.get())
        XCTAssertEqual(counter.value, 2, "Failed verifications must not be cached")
    }

    // MARK: - Missing executable

    func testMissingExecutableFailsClean() {
        let phantom = tempDir.appendingPathComponent("does-not-exist")
        let result = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: phantom, verify: { _, _ in true })
        XCTAssertThrowsError(try result.get()) { error in
            guard case JamfCLIIdentity.VerifyError.probeFailed = error else {
                XCTFail("Expected .probeFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Enforcement off

    func testGateIsNoOpWhenEnforcementOff() {
        let counter = SendableCounter()
        let verify: @Sendable (URL, String) -> Bool = { _, _ in
            counter.increment()
            return true
        }
        let result = JamfCLIIdentity.ensureVerifiedJamfCLI(
            executable: binary,
            expectedTeamID: nil,
            verify: verify
        )
        XCTAssertNoThrow(try result.get(), "expectedTeamID=nil disables the gate")
        XCTAssertEqual(counter.value, 0, "Verifier must not be invoked when enforcement is off")
    }
}

/// Thread-safe Sendable counter used so `@Sendable` verifier closures
/// can record call counts without tripping Swift 6 strict concurrency.
final class SendableCounter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
