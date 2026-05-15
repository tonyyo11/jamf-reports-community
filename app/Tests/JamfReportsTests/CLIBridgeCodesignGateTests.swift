import Foundation
import XCTest
@testable import JamfReports

// Tests for M-01: CLIBridge.run / runAndCapture invoke the
// codesign-verified-fingerprint gate before spawning jamf-cli.
// Routine paths (collect, audit, backup, …) were previously gated only
// at install time and onboarding — a Homebrew-path binary swap between
// onboarding and a later command would receive live API credentials.
//
// Also covers S-02: the `environment` parameter default is
// `environmentForJamfCLI()` so a future caller that omits the argument
// no longer inherits the parent process's `DYLD_INSERT_LIBRARIES`,
// `SSL_CERT_FILE`, etc.
final class CLIBridgeCodesignGateTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CLIBridgeCodesign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        JamfCLIIdentity.clearVerificationCacheForTesting()
    }

    override func tearDownWithError() throws {
        JamfCLIIdentity.clearVerificationCacheForTesting()
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Gate triggers when basename is jamf-cli

    func testRunRejectsUnverifiedJamfCLIWithoutSpawning() async throws {
        // Create a fake "jamf-cli" file that will fail codesign
        // verification (it's not signed at all). The gate must reject
        // it before any process is spawned.
        let fake = tempDir.appendingPathComponent("jamf-cli")
        try Data("not-a-real-binary".utf8).write(to: fake)
        // Mark executable so process.run() would otherwise attempt to
        // spawn it; the test asserts the gate blocks before that.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fake.path
        )

        let bridge = CLIBridge()
        let collector = LogLineCollector()
        let exit = await bridge.run(
            executable: fake,
            arguments: ["--version"],
            onLine: { line in collector.append(line) }
        )
        XCTAssertEqual(exit, -1, "Codesign gate must reject without spawning a process")
        let lines = collector.snapshot()
        let fatalLines = lines.filter { $0.level == CLIBridge.LogLevel.fail && $0.text.contains("signature") }
        XCTAssertFalse(fatalLines.isEmpty,
                       "User-visible diagnostic must mention signature verification: got \(lines.map { $0.text })")
    }

    // MARK: - Gate skipped for non-jamf-cli executables

    func testRunSkipsGateForNonJamfCLIExecutable() async {
        // /bin/echo is signed by Apple (Team ID won't match Jamf's), but
        // the gate is keyed on basename == "jamf-cli" so /bin/echo must
        // be allowed to run.
        let echoBin = URL(fileURLWithPath: "/bin/echo")
        guard FileManager.default.isExecutableFile(atPath: echoBin.path) else {
            return // platform doesn't have /bin/echo
        }

        let bridge = CLIBridge()
        let exit = await bridge.run(
            executable: echoBin,
            arguments: ["hello-from-test"],
            onLine: { _ in }
        )
        XCTAssertEqual(exit, 0, "Non-jamf-cli executable must bypass the gate and run normally")
    }

    // MARK: - S-02: environment default

    func testEnvironmentDefaultIsRestricted() async {
        // /bin/sh -c "echo $PATH" — with the S-02 fix in place and no
        // explicit environment: argument, the child sees exactly the
        // PATH defined in environmentForJamfCLI().
        let bridge = CLIBridge()
        let (exit, data) = await bridge.runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$PATH\""],
            onLine: { _ in }
        )
        XCTAssertEqual(exit, 0)
        let observed = String(data: data, encoding: .utf8) ?? ""
        let expected = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        XCTAssertEqual(observed, expected,
                       "Default environment must be environmentForJamfCLI(), not inherited")
    }

    // MARK: - Gate caches across calls

    func testRepeatRunsForSameJamfCLIBinaryShareVerification() async throws {
        // After a successful verification (via the stubbed verifier
        // through JamfCLIIdentity), subsequent runs against the same
        // (path, size, mtime) must not re-invoke the verifier. We can
        // observe this via the JamfCLIIdentity cache.
        let fake = tempDir.appendingPathComponent("jamf-cli")
        try Data("fake-cli-bytes".utf8).write(to: fake)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fake.path
        )

        // Pre-populate cache via the seam.
        let primed = JamfCLIIdentity.ensureVerifiedJamfCLI(
            executable: fake,
            verify: { _, _ in true }
        )
        XCTAssertNoThrow(try primed.get())

        // Now call again — must hit the cache, not call verify again.
        let counter = SendableCounter()
        let second = JamfCLIIdentity.ensureVerifiedJamfCLI(
            executable: fake,
            verify: { _, _ in
                counter.increment()
                return true
            }
        )
        XCTAssertNoThrow(try second.get())
        XCTAssertEqual(counter.value, 0, "Cache hit must short-circuit the verifier closure")
    }

    // MARK: - runDeviceDetailProcess (high-throughput per-device fetch)
    //
    // singleDeviceDetail builds its own Process for performance rather
    // than routing through CLIBridge.run/runAndCapture, so it needs an
    // independent codesign-gate check. silent-failure-hunter caught
    // this gap in the initial PR-2 diff; this test pins it.

    func testRunDeviceDetailProcessGatesUnverifiedJamfCLI() async throws {
        let fake = tempDir.appendingPathComponent("jamf-cli")
        try Data("fake-cli-bytes".utf8).write(to: fake)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fake.path
        )

        // Cache empty + real CodeSignVerifier will reject this unsigned
        // file. The path must short-circuit with -1 without spawning.
        let exit = await runDeviceDetailProcess(
            executable: fake,
            arguments: ["pro", "device", "1", "--output", "json"],
            outputDirectory: tempDir.appendingPathComponent("out", isDirectory: true)
        )
        XCTAssertEqual(exit, -1, "runDeviceDetailProcess must invoke the codesign gate before spawning jamf-cli")
    }

    func testRunDeviceDetailProcessAllowsCachedVerifiedJamfCLI() async throws {
        // Pre-populate the cache with a fingerprint matching a fake
        // "jamf-cli" file. The gate hits the cache and proceeds; the
        // actual process.run on the fake binary will fail (it's not a
        // valid executable), but the failure is a launch error (exit
        // != -1 from the gate; non-zero from process.run). The test
        // asserts the gate did NOT block: any exit code other than the
        // gate's -1 is acceptable.
        let fake = tempDir.appendingPathComponent("jamf-cli")
        // A minimal valid Mach-O isn't worth synthesizing — instead,
        // use /bin/sh as the executable but rename the URL's last path
        // component to "jamf-cli" via a symlink so the basename check
        // fires and the cache primer can register the fake's
        // fingerprint while process.run actually exec's /bin/sh.
        let realSh = URL(fileURLWithPath: "/bin/sh")
        try FileManager.default.createSymbolicLink(at: fake, withDestinationURL: realSh)

        // Prime the cache via the seam.
        let primed = JamfCLIIdentity.ensureVerifiedJamfCLI(
            executable: fake,
            verify: { _, _ in true }
        )
        XCTAssertNoThrow(try primed.get(), "Cache priming must succeed for the test setup")

        let exit = await runDeviceDetailProcess(
            executable: fake,
            arguments: ["-c", "exit 0"],
            outputDirectory: tempDir.appendingPathComponent("out", isDirectory: true)
        )
        XCTAssertNotEqual(exit, -1, "Cached-verified binary must pass the gate; got \(exit) which would indicate gate rejection")
    }
}

/// Thread-safe collector that satisfies `@Sendable` for the onLine
/// closure captured into `Process`'s readabilityHandler queue.
private final class LogLineCollector: @unchecked Sendable {
    private var lines: [CLIBridge.LogLine] = []
    private let lock = NSLock()

    func append(_ line: CLIBridge.LogLine) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    func snapshot() -> [CLIBridge.LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
