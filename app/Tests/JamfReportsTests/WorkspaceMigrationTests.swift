import XCTest
@testable import JamfReports

/// MFS-2 — `WorkspaceMigration` tests.
///
/// Asserts the one-shot Spotlight + permissions backfill walks every valid
/// profile directory under `JRC_TEST_WORKSPACES_ROOT`, drops
/// `.metadata_never_index` where missing, tightens permissions to 0600/0700,
/// and is gated by a per-version `UserDefaults` sentinel.
@MainActor
final class WorkspaceMigrationTests: XCTestCase {

    private var tempRoot: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)

        defaults = UserDefaults(suiteName: "JRC.WorkspaceMigrationTests.\(UUID().uuidString)")
        XCTAssertNotNil(defaults)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let defaults { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().description) }
    }

    // MARK: - Mixed-mode workspace gets walked + marker dropped

    func test_run_walksMixedModeWorkspaceTo0600() throws {
        // Two profiles under the (test-only) workspaces root with mixed-mode
        // artifacts and no `.metadata_never_index` markers.
        try makeProfile(
            name: "alpha",
            files: [
                "Generated Reports/report1.xlsx": 0o644,
                "jamf-cli-data/security/2026-04-29.json": 0o644,
                "snapshots/computers_2026-04-30.csv": 0o600,
            ],
            includeMarker: false
        )
        try makeProfile(
            name: "beta",
            files: [
                "Generated Reports/report2.xlsx": 0o644,
            ],
            includeMarker: true   // already has the marker — must not be re-written
        )

        WorkspaceMigration.run(defaults: defaults)

        XCTAssertEqual(try mode(of: profilePath("alpha", "Generated Reports/report1.xlsx")), 0o600)
        XCTAssertEqual(try mode(of: profilePath("alpha", "jamf-cli-data/security/2026-04-29.json")), 0o600)
        XCTAssertEqual(try mode(of: profilePath("alpha", "snapshots/computers_2026-04-30.csv")), 0o600)
        XCTAssertEqual(try mode(of: profilePath("beta", "Generated Reports/report2.xlsx")), 0o600)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: profilePath("alpha", ".metadata_never_index").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: profilePath("beta", ".metadata_never_index").path
        ))
    }

    // MARK: - Sentinel gates re-runs

    func test_runIfNeeded_skipsWhenSentinelMatches() throws {
        try makeProfile(name: "gamma",
                        files: ["doc.json": 0o644],
                        includeMarker: false)

        let didRun1 = WorkspaceMigration.runIfNeeded(defaults: defaults, version: "test-v1")
        XCTAssertTrue(didRun1, "first run for a new version must execute")

        // Loosen permissions again — if `runIfNeeded` short-circuits, this stays loose.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: profilePath("gamma", "doc.json").path
        )

        let didRun2 = WorkspaceMigration.runIfNeeded(defaults: defaults, version: "test-v1")
        XCTAssertFalse(didRun2, "second run with same version must short-circuit")
        XCTAssertEqual(try mode(of: profilePath("gamma", "doc.json")), 0o644,
                       "short-circuit must leave the filesystem alone")

        // New version: must run again.
        let didRun3 = WorkspaceMigration.runIfNeeded(defaults: defaults, version: "test-v2")
        XCTAssertTrue(didRun3)
        XCTAssertEqual(try mode(of: profilePath("gamma", "doc.json")), 0o600)
    }

    // MARK: - Idempotent across consecutive runs

    func test_run_isIdempotentAcrossInvocations() throws {
        try makeProfile(name: "delta",
                        files: ["x.json": 0o644],
                        includeMarker: false)

        WorkspaceMigration.run(defaults: defaults)
        let firstMarkerData = try Data(contentsOf: profilePath("delta", ".metadata_never_index"))
        let firstMarkerMtime = try mtime(of: profilePath("delta", ".metadata_never_index"))

        WorkspaceMigration.run(defaults: defaults)
        let secondMarkerData = try Data(contentsOf: profilePath("delta", ".metadata_never_index"))
        let secondMarkerMtime = try mtime(of: profilePath("delta", ".metadata_never_index"))

        XCTAssertEqual(firstMarkerData, secondMarkerData)
        XCTAssertEqual(firstMarkerMtime, secondMarkerMtime,
                       "marker must not be re-written when already present")
        XCTAssertEqual(try mode(of: profilePath("delta", "x.json")), 0o600)
    }

    // MARK: - Helpers

    private func makeProfile(
        name: String,
        files: [String: Int],
        includeMarker: Bool
    ) throws {
        let profile = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
        for (relPath, mode) in files {
            let url = profile.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
            )
            try Data("seed".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(mode))],
                ofItemAtPath: url.path
            )
        }
        if includeMarker {
            let marker = profile.appendingPathComponent(".metadata_never_index")
            try Data().write(to: marker)
        }
    }

    private func profilePath(_ profile: String, _ rel: String) -> URL {
        tempRoot.appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent(rel)
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o7777
    }

    private func mtime(of url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attrs[.modificationDate] as? Date else {
            XCTFail("no mtime for \(url.path)")
            return .distantPast
        }
        return date
    }
}
