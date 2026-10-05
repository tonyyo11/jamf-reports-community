import XCTest
@testable import JamfReports

/// A new workspace's config.yaml is seeded from `config.example.yaml`. A release build
/// reads only the app bundle's copy: the working directory of a `jamf-reports` run is
/// whatever the caller chose, and a file planted there must not become a workspace's config.
@MainActor
final class CLIBridgeSeedConfigTests: XCTestCase {

    private func makeLayout() throws -> (cwd: URL, bundle: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-seed-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work/dir", isDirectory: true)
        let bundle = root.appendingPathComponent("Resources", isDirectory: true)
        for dir in [cwd, bundle] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (cwd, bundle)
    }

    private func plant(_ dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("config.example.yaml")
        try "planted: true\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAReleaseBuildIgnoresTheWorkingDirectoryAndItsParent() throws {
        let (cwd, bundle) = try makeLayout()
        _ = try plant(cwd)
        _ = try plant(cwd.deletingLastPathComponent())

        XCTAssertNil(CLIBridge.bundledSeedConfig(
            workingDirectory: cwd, resourceURL: bundle, searchesWorkingDirectory: false))

        let shipped = try plant(bundle)
        XCTAssertEqual(
            CLIBridge.bundledSeedConfig(
                workingDirectory: cwd, resourceURL: bundle, searchesWorkingDirectory: false),
            shipped)
    }

    func testADebugBuildFindsTheCheckoutCopyBeforeTheBundle() throws {
        let (cwd, bundle) = try makeLayout()
        let parentCopy = try plant(cwd.deletingLastPathComponent())
        _ = try plant(bundle)

        XCTAssertEqual(
            CLIBridge.bundledSeedConfig(
                workingDirectory: cwd, resourceURL: bundle, searchesWorkingDirectory: true),
            parentCopy)
    }
}
