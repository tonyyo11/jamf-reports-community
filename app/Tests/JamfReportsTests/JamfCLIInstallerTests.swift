import XCTest
@testable import JamfReports

/// Tests for the W23 jamf-cli direct-download install path.
/// Covers the pure helpers (`extractChecksum`, `sha256Hex`); the network-bound
/// `installFromGitHub` is not exercised here.
@MainActor
final class JamfCLIInstallerTests: XCTestCase {

    // MARK: - compareVersions

    func test_compareVersions_preReleaseRanksBelowItsRelease() {
        let cmp = JamfCLIInstaller.compareVersions
        XCTAssertEqual(cmp("1.30.0-rc1", "1.30.0"), .orderedAscending)
        XCTAssertEqual(cmp("1.30.0", "1.30.0-rc1"), .orderedDescending)
        XCTAssertEqual(cmp("1.30.0-rc1", "1.30.0-rc2"), .orderedAscending)
        XCTAssertEqual(cmp("1.30.0-rc2", "1.30.0-rc10"), .orderedAscending)
        XCTAssertEqual(cmp("1.30.0-rc1", "1.30.0-rc1"), .orderedSame)
        XCTAssertEqual(cmp("1.29.0", "1.30.0-rc1"), .orderedAscending)
        XCTAssertEqual(cmp("1.31.0-rc1", "1.30.0"), .orderedDescending)
    }

    func test_compareVersions_plainVersionsAndBuildMetadataUnchanged() {
        let cmp = JamfCLIInstaller.compareVersions
        XCTAssertEqual(cmp("v1.29.0", "1.29.0"), .orderedSame)
        XCTAssertEqual(cmp("1.29", "1.29.0"), .orderedSame)
        XCTAssertEqual(cmp("1.9.0", "1.10.0"), .orderedAscending)
        XCTAssertEqual(cmp("1.30.0+build5", "1.30.0"), .orderedSame)
    }

    func test_featureGates_treatAPreReleaseOfTheFloorAsBelowIt() {
        XCTAssertTrue(JamfCLIInstaller.supportsDashboard("1.31.0"))
        XCTAssertFalse(JamfCLIInstaller.supportsDashboard("1.31.0-rc1"))
    }

    // MARK: - isTrustedFinalURL

    /// The download follows redirects, so the host that answered is checked after the fact.
    func test_isTrustedFinalURL_acceptsTheGitHubAssetHosts() {
        for host in JamfCLIInstaller.trustedAssetHosts {
            XCTAssertTrue(JamfCLIInstaller.isTrustedFinalURL(URL(string: "https://\(host)/a.zip")))
        }
        XCTAssertTrue(JamfCLIInstaller.isTrustedFinalURL(URL(string: "https://GitHub.com/a.zip")))
    }

    func test_isTrustedFinalURL_rejectsRedirectsOffTheAllowList() {
        XCTAssertFalse(JamfCLIInstaller.isTrustedFinalURL(URL(string: "https://evil.example/a.zip")))
        XCTAssertFalse(JamfCLIInstaller.isTrustedFinalURL(
            URL(string: "https://github.com.evil.example/a.zip")))
        XCTAssertFalse(JamfCLIInstaller.isTrustedFinalURL(URL(string: "http://github.com/a.zip")))
        XCTAssertFalse(JamfCLIInstaller.isTrustedFinalURL(nil))
    }

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

    // MARK: - Minimum supported version

    func test_isBelowMinimumSupported_flagsOlderVersions() {
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.14.0"))
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.15.0"))
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.16.0"))
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.16.1"))
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.18.0"))
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.28.9"),
                      "1.28.9 is below the floor 1.29.0")
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("1.29.0-rc1"),
                      "a pre-release of the floor counts as below it")
        XCTAssertTrue(JamfCLIInstaller.isBelowMinimumSupported("v1.14.0"))
    }

    func test_isBelowMinimumSupported_acceptsCurrentAndNewer() {
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("1.29.0"),
                       "1.29.0 is the floor — should not flag")
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("1.29.1"))
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("1.33.0"))
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("2.0.0"))
        XCTAssertFalse(JamfCLIInstaller.isBelowMinimumSupported("v1.29.0"))
    }

    func test_floorLine_stopsTheRun() {
        let stop = JamfCLIInstaller.floorLine(installed: "1.28.0", profile: "prod")
        XCTAssertTrue(stop.hasPrefix("[error] "), stop)
        XCTAssertTrue(stop.contains("below 1.29.0"), stop)
        XCTAssertTrue(stop.contains("aborting 'prod'"), stop)
    }

    func test_installedVersionBelowFloor_refusesOnlyAKnownVersionBelowOneTwentyNine() {
        let saved = JamfCLIInstaller.installedVersionProbe
        defer { JamfCLIInstaller.installedVersionProbe = saved }
        JamfCLIInstaller.installedVersionProbe = { "1.28.9" }
        XCTAssertEqual(JamfCLIInstaller.installedVersionBelowFloor(), "1.28.9")
        JamfCLIInstaller.installedVersionProbe = { "1.29.0" }
        XCTAssertNil(JamfCLIInstaller.installedVersionBelowFloor())
        JamfCLIInstaller.installedVersionProbe = { nil }
        XCTAssertNil(JamfCLIInstaller.installedVersionBelowFloor(), "unknown never refuses")
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

    // MARK: - replaceDirectBinary

    private func installScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func test_replaceDirectBinary_refusesALinkAtTheTarget() throws {
        let dir = try installScratch()
        let managed = dir.appendingPathComponent("managed")
        try Data("old".utf8).write(to: managed)
        let target = dir.appendingPathComponent("jamf-cli")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: managed)
        let source = dir.appendingPathComponent("new")
        try Data("new".utf8).write(to: source)

        XCTAssertThrowsError(try JamfCLIInstaller.replaceDirectBinary(at: target, with: source)) {
            XCTAssertTrue($0.localizedDescription.contains("is a link"), "\($0)")
        }
        XCTAssertEqual(try String(contentsOf: managed, encoding: .utf8), "old")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: target.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["jamf-cli", "managed", "new"])
    }

    func test_replaceDirectBinary_removesTheStagedCopyWhenTheReplaceFails() throws {
        let dir = try installScratch()
        let target = dir.appendingPathComponent("jamf-cli")
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: target.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: target.path)
        }
        let source = dir.appendingPathComponent("new")
        try Data("new".utf8).write(to: source)

        XCTAssertThrowsError(try JamfCLIInstaller.replaceDirectBinary(at: target, with: source))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["jamf-cli", "new"])
    }

    func test_replaceDirectBinary_replacesARegularFileAndKeepsItsMode() throws {
        let dir = try installScratch()
        let target = dir.appendingPathComponent("jamf-cli")
        try Data("old".utf8).write(to: target)
        chmod(target.path, 0o755)
        let source = dir.appendingPathComponent("new")
        try Data("new".utf8).write(to: source)

        try JamfCLIInstaller.replaceDirectBinary(at: target, with: source)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o755)
    }
}
