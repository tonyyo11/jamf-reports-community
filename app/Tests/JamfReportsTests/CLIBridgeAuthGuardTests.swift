import Foundation
import XCTest
@testable import JamfReports

/// The exit-code constants the auth guard and its callers branch on, and the apikey bypass
/// (`JamfCLIAuthMethod.apiKey`). The guard calls `pro auth token`; the timeout test injects a
/// sleeping stub, and no test runs a real jamf-cli.
@MainActor
final class CLIBridgeAuthGuardTests: XCTestCase {

    // MARK: - Constants

    func test_exitCodeUnauthorized_isThree() {
        // jamf-cli maps HTTP 401 → exit 3. The constant must not drift.
        XCTAssertEqual(CLIBridge.exitCodeUnauthorized, 3)
    }

    func test_exitCodePermissionDenied_isFive() {
        // jamf-cli maps HTTP 403 → exit 5.
        XCTAssertEqual(CLIBridge.exitCodePermissionDenied, 5)
    }

    func test_exitCodeRateLimited_isSix() {
        // jamf-cli maps HTTP 429 → exit 6.
        XCTAssertEqual(CLIBridge.exitCodeRateLimited, 6)
    }

    func test_exitCodeUsage_isTwo() {
        // jamf-cli maps bad flags / missing args → exit 2. The constant must not drift.
        XCTAssertEqual(CLIBridge.exitCodeUsage, 2)
    }

    func test_exitCodeNotFound_isFour() {
        // jamf-cli maps HTTP 404 → exit 4. The constant must not drift.
        XCTAssertEqual(CLIBridge.exitCodeNotFound, 4)
    }

    // MARK: - apikey auth method

    func test_apiKeyAuthMethodIsReadExactly() {
        XCTAssertEqual(JamfCLIAuthMethod(raw: "apikey"), .apiKey)
        XCTAssertNotEqual(JamfCLIAuthMethod(raw: "bearer"), .apiKey)
        XCTAssertNotEqual(JamfCLIAuthMethod(raw: ""), .apiKey)
        XCTAssertNotEqual(JamfCLIAuthMethod(raw: "APIKEY"), .apiKey) // case-sensitive
    }

    // MARK: - Probe timeout

    /// A probe that gets no answer is not a rejection: one warn line, no re-authenticate error,
    /// and the guard lets the command run.
    func test_authGuard_probeTimeoutWarnsOnceAndProceeds() async throws {
        let dir = try SleepingCLIStub.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = try SleepingCLIStub.make(in: dir)
        let collector = GuardLineCollector()
        let started = Date()

        let proceed = await CLIBridge().authGuard(
            profile: "timeout-probe", probeTimeout: 0.5, _testExecutable: stub
        ) { collector.append($0) }

        XCTAssertTrue(proceed, "a probe that timed out must not block the command")
        let texts = collector.texts()
        XCTAssertEqual(texts.filter { $0.hasPrefix("[warn] auth check timed out") }.count, 1,
                       "expected exactly one timeout warn line; got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains("[error]") || $0.contains("re-authenticate") },
                       "a timeout must not read as rejected credentials; got: \(texts)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }
}

extension CLIBridgeAuthGuardTests {
    /// `pro auth token` is meaningless on a profile of another product: the guard passes it
    /// without running the probe (a sleeping stub would time out and warn if it ran), while a
    /// Jamf Pro profile is still probed.
    func test_authGuard_skipsTheProbeForAnotherProductOnly() async throws {
        let dir = try SleepingCLIStub.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir); ProfileAuthMethod.invalidateCache() }
        let stub = try SleepingCLIStub.make(in: dir)
        ProfileAuthMethod.invalidateCache()
        try ProductGuardSeed.seed(profile: "guard-protect", product: "protect", in: dir)
        try ProductGuardSeed.seed(profile: "guard-pro", product: "pro", in: dir)

        let skipped = ProductGuardLines()
        let passed = await CLIBridge().authGuard(
            profile: "guard-protect", probeTimeout: 0.5, _testExecutable: stub, onLine: skipped.add)
        XCTAssertTrue(passed)
        XCTAssertTrue(skipped.all.isEmpty, "\(skipped.all)")
        let status = await CLIBridge().tokenStatus(for: "guard-protect")
        XCTAssertNil(status)

        let probed = ProductGuardLines()
        _ = await CLIBridge().authGuard(
            profile: "guard-pro", probeTimeout: 0.5, _testExecutable: stub, onLine: probed.add)
        XCTAssertEqual(probed.all.filter { $0.hasPrefix("[warn] auth check timed out") }.count, 1)
    }
}

// Fixtures are UNCAPTURED: the stderr line is go-keyring's error shape from jamf-cli's source,
// not text recorded from a locked keychain.
extension CLIBridgeAuthGuardTests {
    private static let keychainLine =
        "Error: reading keychain item jamf-cli/profile/client-secret: exit status 36"

    private func failingStub(in dir: URL, stdout: String = "", stderr: String) throws -> URL {
        let url = dir.appendingPathComponent("stub-cli-\(UUID().uuidString)")
        let script = "#!/bin/sh\nprintf '%s' '\(stdout)'\nprintf '%s\\n' '\(stderr)' >&2\nexit 1\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The error on stderr only (no JSON envelope): the guard says the keychain is locked, not
    /// "re-authenticate".
    func test_authGuard_lockedKeychainOnStderrBlocksWithTheUnlockHint() async throws {
        let dir = try SleepingCLIStub.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = try failingStub(in: dir, stderr: Self.keychainLine)
        let collector = GuardLineCollector()

        let proceed = await CLIBridge().authGuard(
            profile: "locked-probe", probeTimeout: 5, _testExecutable: stub
        ) { collector.append($0) }

        XCTAssertFalse(proceed)
        let texts = collector.texts()
        XCTAssertTrue(texts.contains { $0.contains(FailureCause.keychainLockedHint) }, "\(texts)")
        XCTAssertFalse(texts.contains { $0.contains("re-authenticate") }, "\(texts)")
    }

    func test_probeToken_lockedKeychainOnStdoutEnvelopeIsKeychainLocked() async throws {
        let dir = try SleepingCLIStub.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let envelope = #"{"error":"request failed","message":"reading keychain item a/b: "#
            + #"exit status 36","exitCode":1}"#
        let stub = try failingStub(in: dir, stdout: envelope, stderr: "")
        let probe = await CLIBridge().probeToken(for: "locked-probe", executable: stub, timeout: 5)
        guard case .keychainLocked = probe else { return XCTFail("got \(probe)") }
    }

    func test_probeToken_otherFailureStaysAnInvalidToken() async throws {
        let dir = try SleepingCLIStub.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = try failingStub(in: dir, stderr: "Error: boom")
        let probe = await CLIBridge().probeToken(for: "plain-probe", executable: stub, timeout: 5)
        guard case .status(let status) = probe else { return XCTFail("got \(probe)") }
        XCTAssertEqual(status?.isValid, false)
        XCTAssertEqual(status?.keychainLocked, false)
    }
}

private final class GuardLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: CLIBridge.LogLine) { lock.lock(); lines.append(line.text); lock.unlock() }
    func texts() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
