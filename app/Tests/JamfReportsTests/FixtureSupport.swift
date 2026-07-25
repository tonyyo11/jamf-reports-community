import Foundation
import XCTest

// MARK: - Fixture resolution

/// Shared fixture-resolution helper for the whole test target.
///
/// Fixtures live in `Tests/JamfReportsTests/Fixtures/` and ship as a `.copy`
/// resource (see `Package.swift`), which preserves their nested directory
/// layout verbatim (e.g. `jamf-cli-data/<kind>/...`). They are resolved at
/// runtime from `Bundle.module`, so lookup works from any checkout location —
/// including nested git worktrees where the old `#filePath` walk-up to a
/// repo-root `tests/fixtures/` directory would miss and yield `noCachedData`.
enum TestFixtures {

    /// Base URL of the copied `Fixtures/` directory inside the test bundle.
    ///
    /// With `.copy("Fixtures")` the directory lands under the resource bundle
    /// root as `Fixtures/`, so every fixture is addressed relative to this URL.
    static var root: URL {
        guard let resourceURL = Bundle.module.resourceURL else {
            fatalError("Bundle.module has no resourceURL — test resources missing")
        }
        return resourceURL.appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// Resolve a fixture by a path relative to the `Fixtures/` root, e.g.
    /// `dir("jamf-cli-data")`, `dir("sofa/macos_data_feed.json")`.
    static func dir(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    // MARK: - iCloud-safe copying
    //
    // On checkouts synced by iCloud Drive (e.g. under `~/Documents`), freshly
    // materialized files — including this bundle's `.copy`d fixtures, rebuilt
    // on every `swift build` — carry file-provider state (`isUbiquitousItem`)
    // until iCloud finishes syncing. While in that state, URL-based directory
    // enumeration (`contentsOfDirectory(at:...)`) and `FileManager.copyItem`
    // silently see/copy NOTHING (no error — an empty destination), while the
    // BSD path layer (`contentsOfDirectory(atPath:)`) and direct byte reads
    // (`Data(contentsOf:)`) see the real files. So every fixture-directory
    // copy must walk source paths via the path API and copy bytes directly —
    // never `copyItem` or URL enumeration — or it flakes on synced checkouts.
    // Do not "simplify" this back to `FileManager.copyItem`.

    /// Copy a single fixture FILE by reading bytes and writing them out,
    /// bypassing `copyItem`'s iCloud file-provider blind spot. Throws if the
    /// source doesn't exist, so callers can XCTSkip on a missing fixture.
    static func copyFile(_ source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
    }

    /// Recursively copy a fixture DIRECTORY by walking it via the BSD path
    /// API (`subpathsOfDirectory(atPath:)`), creating directories and
    /// byte-copying each file — never `copyItem` or URL-based enumeration.
    /// Throws if `source` doesn't exist as a directory, so callers can
    /// XCTSkip on a missing fixture corpus rather than silently producing
    /// an empty destination.
    static func copyDir(_ source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let subpaths = try FileManager.default.subpathsOfDirectory(atPath: source.path)
        for relative in subpaths {
            let srcPath = source.appendingPathComponent(relative)
            let dstPath = destination.appendingPathComponent(relative)
            var childIsDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: srcPath.path, isDirectory: &childIsDirectory)
            if childIsDirectory.boolValue {
                try FileManager.default.createDirectory(
                    at: dstPath, withIntermediateDirectories: true
                )
            } else {
                try FileManager.default.createDirectory(
                    at: dstPath.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let data = try Data(contentsOf: srcPath)
                try data.write(to: dstPath, options: .atomic)
            }
        }
    }

    /// Copy a fixture directory relative to `Fixtures/`, e.g.
    /// `copyDir("jamf-cli-data/protect-alerts", to: tmp)`. Throws if the
    /// fixture doesn't exist so callers can XCTSkip.
    static func copyDir(_ relativePath: String, to destination: URL) throws {
        try copyDir(dir(relativePath), to: destination)
    }

    /// List the direct children of a fixture directory via the BSD path API
    /// (`contentsOfDirectory(atPath:)`), never URL-based enumeration — same
    /// iCloud file-provider blind spot as `copyItem` (see above). Returns `[]`
    /// if `dirURL` doesn't exist so callers can XCTSkip rather than throw.
    static func listDir(_ dirURL: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path) else {
            return []
        }
        return names.map { dirURL.appendingPathComponent($0) }
    }
}
