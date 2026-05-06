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

    // MARK: - Helpers

    private func makeTempFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-installer-test-\(UUID().uuidString)")
        try contents.write(to: url)
        return url
    }
}
