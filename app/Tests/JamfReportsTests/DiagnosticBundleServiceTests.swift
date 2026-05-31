import Foundation
import XCTest
@testable import JamfReports

/// Parity tests for the native diagnostic-bundle port. These mirror the
/// Python `tests/test_diagnostic_bundle.py` assertions — credentials are always
/// redacted, PII is placeholdered by default, keep-flags scope correctly, and
/// the bundle structure/manifest are sound. The placeholder *digests* are not
/// asserted to equal Python's (the salt is per-instance random by design); the
/// *algorithm and behavior* are.
final class DiagnosticBundleServiceTests: XCTestCase {

    // A redactor with all PII off, to prove secrets are independent of PII flags.
    private func secretsOnlyRedactor() -> DiagnosticRedactor {
        DiagnosticRedactor(
            redactHostnames: false, redactSerials: false, redactEmails: false,
            redactDeviceNames: false, redactUsernames: false)
    }

    // MARK: - Secrets (always-on)

    func testCredentialsRedactedEvenWithAllPIIOff() {
        let r = secretsOnlyRedactor()
        // Config/YAML form is the `client_secret` regex's target; the JSON
        // quoted-key form is handled by `redactJSON`'s exact-key match instead.
        let text = r.redactText(#"client_secret: "mustnotleak1234567""#)
        XCTAssertFalse(text.contains("mustnotleak1234567"))
        XCTAssertTrue(text.contains("REDACTED_CLIENT_SECRET"))
        // JSON-shaped secret: caught by the key-based JSON redactor.
        guard let json = r.redactJSON(["client_secret": "mustnotleak1234567"]) as? [String: Any]
        else { return XCTFail("not a dict") }
        XCTAssertEqual(json["client_secret"] as? String, "REDACTED_CLIENT_SECRET")
    }

    func testEachSecretPatternHitsItsToken() {
        let r = secretsOnlyRedactor()
        let cases: [(String, String)] = [
            (#"client_secret = "abcdefgh12345""#, "REDACTED_CLIENT_SECRET"),
            (#"client_id: "ABCDEF0123456789ABCD""#, "REDACTED_CLIENT_ID"),
            ("Authorization: Bearer abcdefghij0123456789XY", "REDACTED_BEARER"),
            ("token eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4", "REDACTED_JWT"),
            (#"{"access_token": "longvalue"}"#, "REDACTED_ACCESS_TOKEN"),
            (#"{"refresh_token": "longvalue"}"#, "REDACTED_REFRESH_TOKEN"),
            (#"password: "hunter2x""#, "REDACTED_PASSWORD"),
            (#"api_key: "abcdefgh1234""#, "REDACTED_API_KEY"),
            ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "REDACTED_BASIC_CREDENTIAL"),
            (#"webhook_url: "https://example.webhook.office.com/abc""#, "REDACTED_WEBHOOK_URL"),
        ]
        for (input, expected) in cases {
            XCTAssertTrue(r.redactText(input).contains(expected), "expected \(expected) for \(input)")
        }
    }

    func testNoOverRedaction() {
        let r = DiagnosticRedactor()
        let prose = r.redactText("User must enter a password to continue.")
        XCTAssertFalse(prose.contains("REDACTED"), "prose 'password' should not match the pattern")
        let number = r.redactText(#"{"expires_in": 3600, "totalDevices": 42}"#)
        XCTAssertTrue(number.contains("3600"))
        XCTAssertTrue(number.contains("42"))
    }

    // MARK: - PII placeholders

    func testPlaceholderPrefixesByCategory() {
        let r = DiagnosticRedactor()
        XCTAssertTrue(r.redactText("serial C02CDFGHJK here").contains("serial-"))
        XCTAssertTrue(r.redactText("mail john.doe@example.com").contains("email-"))
        XCTAssertTrue(r.redactText("visit https://acme.jamfcloud.com/x").contains("host-"))
        XCTAssertTrue(r.redactText("path /Users/jdoe/Library").contains("user-"))
    }

    func testHostnameRedactionPreservesScheme() {
        let r = DiagnosticRedactor()
        let out = r.redactText("server at https://acme.jamfcloud.com/api")
        XCTAssertTrue(out.contains("https://"))
        XCTAssertTrue(out.contains("host-"))
        XCTAssertFalse(out.contains("acme.jamfcloud.com"))
    }

    func testHomePathRedactionPreservesRemainder() {
        let r = DiagnosticRedactor()
        let out = r.redactText("/Users/jdoe/Library/Logs")
        XCTAssertTrue(out.hasPrefix("/Users/user-"))
        XCTAssertTrue(out.hasSuffix("/Library/Logs"))
    }

    func testSameValueStablePlaceholderWithinInstance() {
        let r = DiagnosticRedactor()
        let out = r.redactText("a john.doe@example.com b john.doe@example.com")
        let tokens = out.split(separator: " ").filter { $0.hasPrefix("email-") }
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0], tokens[1])
    }

    func testDifferentInstancesDifferentPlaceholders() {
        // Per-instance random salt → digests must differ (matches Python).
        let a = DiagnosticRedactor().redactText("C02CDFGHJK")
        let b = DiagnosticRedactor().redactText("C02CDFGHJK")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Keep-flags

    func testKeepFlagsDisableCategoriesButNotSecrets() {
        let r = secretsOnlyRedactor()
        XCTAssertFalse(r.redactText("serial C02CDFGHJK").contains("serial-"))
        XCTAssertFalse(r.redactText("john.doe@example.com").contains("email-"))
        XCTAssertTrue(r.redactText(#"client_secret: "abcdefgh1234""#).contains("REDACTED_CLIENT_SECRET"))
    }

    func testKeepDeviceNamesIndependentOfUsernames() {
        let r = DiagnosticRedactor(redactDeviceNames: false, redactUsernames: true)
        let json: [String: Any] = ["computerName": "Mac-01", "username": "jdoe"]
        guard let out = r.redactJSON(json) as? [String: Any] else { return XCTFail("not a dict") }
        XCTAssertEqual(out["computerName"] as? String, "Mac-01")
        XCTAssertTrue((out["username"] as? String ?? "").hasPrefix("user-"))
    }

    func testUdidIpOrgAlwaysRedactedRegardlessOfKeepFlags() {
        let r = secretsOnlyRedactor() // every category keep-flag is off
        let json: [String: Any] = [
            "udid": "ABCDEF-12345", "ipAddress": "10.0.0.5", "department": "Engineering",
        ]
        guard let out = r.redactJSON(json) as? [String: Any] else { return XCTFail("not a dict") }
        XCTAssertTrue((out["udid"] as? String ?? "").hasPrefix("udid-"))
        XCTAssertTrue((out["ipAddress"] as? String ?? "").hasPrefix("ip-"))
        XCTAssertTrue((out["department"] as? String ?? "").hasPrefix("org-"))
    }

    // MARK: - JSON redaction

    func testJSONSensitiveKeyBecomesUppercasedToken() {
        let r = DiagnosticRedactor()
        let json: [String: Any] = ["access_token": "secret", "totalDevices": 42]
        guard let out = r.redactJSON(json) as? [String: Any] else { return XCTFail("not a dict") }
        XCTAssertEqual(out["access_token"] as? String, "REDACTED_ACCESS_TOKEN")
        XCTAssertEqual(out["totalDevices"] as? Int, 42)
    }

    func testJSONPIIKeyBecomesPlaceholder() {
        let r = DiagnosticRedactor()
        let json: [String: Any] = ["serialNumber": "C02CDFGHJK"]
        guard let out = r.redactJSON(json) as? [String: Any] else { return XCTFail("not a dict") }
        XCTAssertTrue((out["serialNumber"] as? String ?? "").hasPrefix("serial-"))
    }

    // MARK: - Seeding

    func testSeedingRedactsDeviceNamesInFreeText() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"computerName": "Johns-MacBook-Pro"}"#
            .write(to: dir.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)

        let unseeded = DiagnosticRedactor()
        XCTAssertTrue(unseeded.redactText("log: Johns-MacBook-Pro crashed").contains("Johns-MacBook-Pro"))

        let seeded = DiagnosticRedactor()
        let count = seeded.seedFromWorkspace(dir)
        XCTAssertEqual(count, 1)
        let out = seeded.redactText("log: Johns-MacBook-Pro crashed")
        XCTAssertFalse(out.contains("Johns-MacBook-Pro"))
        XCTAssertTrue(out.contains("device-"))
    }

    func testSeedingHonorsMinLengthFloor() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"computerName": "Mac", "deviceName": "BigMacBookPro"}"#
            .write(to: dir.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)

        let r = DiagnosticRedactor()
        XCTAssertEqual(r.seedFromWorkspace(dir), 2)
        let out = r.redactText("Mac and BigMacBookPro")
        XCTAssertFalse(out.contains("BigMacBookPro"), "len>=4 name should be seeded")
        XCTAssertTrue(out.contains("Mac "), "len<4 name should survive the floor")
    }

    // MARK: - Bundle structure

    func testStageFilesProducesRedactedTree() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let staging = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: staging) }

        let entries = try DiagnosticBundleService.stageFiles(
            sources: workspace.sources, into: staging,
            redactor: DiagnosticRedactor(), options: .init(), now: Date())

        let log = try String(contentsOf: staging.appendingPathComponent("logs/run.log"), encoding: .utf8)
        XCTAssertFalse(log.contains("leakvalue123"))
        XCTAssertTrue(log.contains("REDACTED_CLIENT_SECRET"))
        XCTAssertFalse(log.contains("acme.jamfcloud.com"))

        let summary = try Data(contentsOf:
            staging.appendingPathComponent("summaries/summary_2026-05-30.json"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: summary) as? [String: Any])
        XCTAssertEqual(obj["client_secret"] as? String, "REDACTED_CLIENT_SECRET")
        XCTAssertEqual(obj["totalDevices"] as? Int, 42)

        let config = try String(
            contentsOf: staging.appendingPathComponent("config.yaml"), encoding: .utf8)
        XCTAssertFalse(config.contains("topsecret123"))

        let tree = try String(
            contentsOf: staging.appendingPathComponent("workspace_tree.txt"), encoding: .utf8)
        XCTAssertEqual(tree.split(separator: "\n").first, "\(workspace.root.lastPathComponent)/")
        XCTAssertFalse(tree.contains(workspace.root.path), "tree must not leak the absolute path")

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("versions.json").path))
        let paths = Set(entries.map { $0.path })
        XCTAssertTrue(paths.contains("logs/run.log"))
        XCTAssertTrue(paths.contains("summaries/summary_2026-05-30.json"))
        XCTAssertTrue(paths.contains("config.yaml"))
        XCTAssertTrue(paths.contains("workspace_tree.txt"))
        XCTAssertTrue(paths.contains("versions.json"))
    }

    func testLogLookbackExcludesOldFiles() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let oldLog = workspace.sources.logsDir.appendingPathComponent("old.log")
        try "stale".write(to: oldLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: oldLog.path)
        let staging = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: staging) }

        let entries = try DiagnosticBundleService.stageFiles(
            sources: workspace.sources, into: staging,
            redactor: nil, options: .init(), now: Date())
        let paths = Set(entries.map { $0.path })
        XCTAssertTrue(paths.contains("logs/run.log"))
        XCTAssertFalse(paths.contains("logs/old.log"))
    }

    func testBuildBundleWritesZipWithManifestMirroringEntries() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let outputDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let zip = try DiagnosticBundleService.buildBundle(
            sources: workspace.sources, outputDir: outputDir,
            profileSlug: "test", options: .init(), now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertTrue(zip.lastPathComponent.hasPrefix("jamf-reports-diagnostic-test-"))

        let extracted = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: extracted) }
        try unzip(zip, into: extracted)
        let names = try fileSet(under: extracted)
        XCTAssertTrue(names.contains("manifest.json"))

        let manifestData = try Data(contentsOf: extracted.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        let manifestPaths = Set(files.compactMap { $0["path"] as? String })
        XCTAssertEqual(manifestPaths, names.subtracting(["manifest.json"]))

        let policy = try XCTUnwrap(manifest["redaction_policy"] as? [String: Any])
        XCTAssertEqual(policy["enabled"] as? Bool, true)
    }

    func testGenerateRejectsInvalidProfile() {
        XCTAssertThrowsError(try DiagnosticBundleService.generate(profile: "Bad Name!"))
    }

    func testSymlinkedConfigAndSummaryAreSkipped() throws {
        let fm = FileManager.default
        let workspace = try makeWorkspace()
        defer { try? fm.removeItem(at: workspace.root) }
        // External file holding a secret under a key the redactor does NOT know,
        // so if it leaked through a symlink it would be visible verbatim.
        let external = try makeTempDir()
        defer { try? fm.removeItem(at: external) }
        let secretFile = external.appendingPathComponent("leak.txt")
        try "weird_key: SUPERSECRETVALUE".write(to: secretFile, atomically: true, encoding: .utf8)

        try fm.removeItem(at: workspace.sources.configURL)
        try fm.createSymbolicLink(at: workspace.sources.configURL, withDestinationURL: secretFile)
        try fm.createSymbolicLink(
            at: workspace.sources.summariesDir.appendingPathComponent("summary_2026-06-01.json"),
            withDestinationURL: secretFile)

        let staging = try makeTempDir()
        defer { try? fm.removeItem(at: staging) }
        let entries = try DiagnosticBundleService.stageFiles(
            sources: workspace.sources, into: staging,
            redactor: DiagnosticRedactor(), options: .init(), now: Date())

        XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathComponent("config.yaml").path))
        for name in try fileSet(under: staging) {
            let content =
                (try? String(contentsOf: staging.appendingPathComponent(name), encoding: .utf8)) ?? ""
            XCTAssertFalse(content.contains("SUPERSECRETVALUE"), "leaked via \(name)")
        }
        XCTAssertTrue(entries.contains { $0.path == "config.yaml" && $0.skipped == true })
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagbundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Workspace {
        let root: URL
        let sources: DiagnosticBundleService.Sources
    }

    /// Build a minimal workspace tree with a log, a summary, a config, and a
    /// (empty) data dir, returning resolved `Sources`.
    private func makeWorkspace() throws -> Workspace {
        let fm = FileManager.default
        let root = try makeTempDir()
        let logs = root.appendingPathComponent("automation/logs", isDirectory: true)
        let summaries = root.appendingPathComponent(
            "snapshots/computers/summaries", isDirectory: true)
        let data = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        for dir in [logs, summaries, data] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "event client_secret: leakvalue123456 at acme.jamfcloud.com"
            .write(to: logs.appendingPathComponent("run.log"), atomically: true, encoding: .utf8)
        try #"{"client_secret": "x12345678", "totalDevices": 42}"#
            .write(to: summaries.appendingPathComponent("summary_2026-05-30.json"),
                   atomically: true, encoding: .utf8)
        try "client_secret: topsecret123\nfoo: bar\n"
            .write(to: root.appendingPathComponent("config.yaml"),
                   atomically: true, encoding: .utf8)
        let sources = DiagnosticBundleService.Sources(
            workspaceName: root.lastPathComponent, workspaceRoot: root,
            logsDir: logs, summariesDir: summaries,
            configURL: root.appendingPathComponent("config.yaml"), dataDir: data)
        return Workspace(root: root, sources: sources)
    }

    private func unzip(_ zip: URL, into dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, dir.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip failed")
    }

    private func fileSet(under root: URL) throws -> Set<String> {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var names: Set<String> = []
        let base = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base + "/") { names.insert(String(path.dropFirst(base.count + 1))) }
        }
        return names
    }
}
