import XCTest
@testable import JamfReports

/// Tests for the W23 jamf-cli direct-download install path.
/// Covers the pure helpers (`extractChecksum`, `sha256Hex`,
/// `defaultDirectInstallURL`); the network-bound `installFromGitHub` is not
/// exercised here.
@MainActor
final class JamfCLIInstallerTests: XCTestCase {

    // MARK: - extractChecksum

    func test_extractChecksum_simpleSpaceSeparated() {
        let body = """
        abc123def4567890abc123def4567890abc123def4567890abc123def4567890  jamf-cli_Darwin_arm64.tar.gz
        ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100  jamf-cli_Darwin_x86_64.tar.gz
        """
        let digest = JamfCLIInstaller.extractChecksum(
            forAsset: "jamf-cli_Darwin_arm64.tar.gz", in: body
        )
        XCTAssertEqual(digest, "abc123def4567890abc123def4567890abc123def4567890abc123def4567890")
    }

    func test_extractChecksum_supportsBinaryStarMarker() {
        // shasum -b emits "<digest> *<filename>"
        let body = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef *jamf-cli"
        let digest = JamfCLIInstaller.extractChecksum(forAsset: "jamf-cli", in: body)
        XCTAssertEqual(
            digest,
            "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        )
    }

    func test_extractChecksum_returnsNilForUnknownAsset() {
        let body = "abc123  someOtherFile.tar.gz"
        XCTAssertNil(
            JamfCLIInstaller.extractChecksum(forAsset: "jamf-cli_Darwin_arm64.tar.gz", in: body)
        )
    }

    func test_extractChecksum_returnsNilForEmptyBody() {
        XCTAssertNil(JamfCLIInstaller.extractChecksum(forAsset: "anything", in: ""))
    }

    func test_extractChecksum_skipsMalformedLines() {
        let body = """
        # comment line, not a checksum
        abc123  good.tar.gz
        no-filename-here
        """
        XCTAssertEqual(
            JamfCLIInstaller.extractChecksum(forAsset: "good.tar.gz", in: body),
            "abc123"
        )
    }

    // MARK: - sha256Hex

    func test_sha256Hex_emptyFileMatchesKnownDigest() throws {
        // SHA256 of an empty input is well-known.
        let tmp = try makeTempFile(contents: Data())
        defer { try? FileManager.default.removeItem(at: tmp) }
        let digest = try JamfCLIInstaller.sha256Hex(of: tmp)
        XCTAssertEqual(
            digest,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func test_sha256Hex_knownString() throws {
        // SHA256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let tmp = try makeTempFile(contents: Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let digest = try JamfCLIInstaller.sha256Hex(of: tmp)
        XCTAssertEqual(
            digest,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: - defaultDirectInstallURL

    func test_defaultDirectInstallURL_endsAtLocalBinJamfCli() {
        let url = JamfCLIInstaller.defaultDirectInstallURL
        XCTAssertTrue(url.path.hasSuffix("/.local/bin/jamf-cli"),
                      "Expected ~/.local/bin/jamf-cli, got \(url.path)")
    }

    func test_defaultDirectInstallDirIsOnPATH_returnsBool() {
        // No-op smoke check — the value depends on the test runner's PATH; we
        // only assert the function is callable and returns a bool.
        _ = JamfCLIInstaller.defaultDirectInstallDirIsOnPATH()
    }

    // MARK: - Minimum supported version

    func test_isBelowMinimumSupported_flagsOlderVersions() {
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.14.0"))
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.15.0"))
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.16.0"))
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.16.1"),
                      "1.16.1 is below the new floor 1.18.0")
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.17.9"))
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("v1.14.0"))
    }

    func test_isBelowMinimumSupported_acceptsCurrentAndNewer() {
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("1.18.0"),
                       "1.18.0 is the floor — should not flag")
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("1.18.1"))
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("1.18.10"),
                       "1.18.10 is above the floor 1.18.0")
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("1.19.0"))
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("2.0.0"),
                       "2.0.0 is above the floor 1.18.0")
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("v1.18.0"))
    }

    func test_isBelowMinimumSupported_returnsFalseOnUnknownInput() {
        // We don't nag users when version detection itself failed.
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported(nil))
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported(""))
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("garbage"))
    }

    // MARK: - specProVersion

    // The success path (valid JSON from a real signed binary) cannot be faked in unit tests
    // without a live jamf-cli binary that passes the codesign gate. The tests below cover
    // the reachable nil paths instead: codesign rejection, non-executable path, and
    // non-zero exit (old binary that doesn't recognise `version -o json`).

    func test_specProVersion_returnsNilForNonExecutablePath() throws {
        // A plain file fails `CLIBridge.codesignGate` -> specProVersion returns nil without
        // attempting to spawn a process.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-specpro-test-\(UUID().uuidString)")
        try Data("not a mach-o".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let result = JamfCLIInstaller.specProVersion(at: url)
        XCTAssertNil(result, "codesign gate must reject an unsigned file and return nil")
    }

    func test_specProVersion_returnsNilForMissingPath() {
        // A URL pointing to a non-existent file also fails the codesign gate.
        let url = URL(fileURLWithPath: "/tmp/jrc-does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(JamfCLIInstaller.specProVersion(at: url))
    }

    // MARK: - Download destination containment

    /// The asset name is server-supplied. `appendingPathComponent` keeps `/` and
    /// `..` as path components and `moveItem` resolves them, so a crafted release
    /// name could land the body outside the temp directory — before any checksum
    /// or signature check runs. `validateAsset` bars that for the binary asset;
    /// the checksums asset deliberately skips that scrub.
    func test_safeDestination_rejectsTraversingNames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-dest-\(UUID().uuidString)", isDirectory: true)
        for name in [
            "../escaped.txt",
            "../../../../Library/LaunchAgents/checksums.txt",
            "sub/checksums.txt",
            "..",
        ] {
            XCTAssertThrowsError(
                try JamfCLIInstaller.safeDestination(in: dir, name: name),
                "name must not resolve outside the destination: '\(name)'")
        }
    }

    func test_safeDestination_acceptsPlainFilename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-dest-\(UUID().uuidString)", isDirectory: true)
        let url = try JamfCLIInstaller.safeDestination(in: dir, name: "checksums.txt")
        XCTAssertEqual(url.lastPathComponent, "checksums.txt")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                       dir.standardizedFileURL.path)
    }

    // MARK: - Helpers

    private func makeTempFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-installer-test-\(UUID().uuidString)")
        try contents.write(to: url)
        return url
    }
}
