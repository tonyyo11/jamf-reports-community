import Foundation
import XCTest
@testable import JamfReports

/// `manifest.json` is integrity metadata, and `ReportEngine` writes it after the
/// snapshot it describes — so in every kind directory it is the newest `.json`.
/// This service has its own file picker and never received the exclusion
/// `FileManager.newestJSONFile` has had since 2.6, which made enabling
/// `jamf_cli.require_manifest` silently empty the Devices screen.
final class DeviceInventoryManifestExclusionTests: XCTestCase {

    private var root: URL!
    private let profile = "manifestpick"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL, modified: Date) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// The regression: a manifest newer than the snapshot must not be picked as
    /// the device source. If it is, the kind reads as zero devices and the whole
    /// screen falls back to whatever CSV happens to be lying around.
    func testManifestNeverOutranksTheSnapshotItDescribes() throws {
        let kindDir = root
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
            .appendingPathComponent("computers", isDirectory: true)

        try write(
            """
            [{"general": {"name": "Fresh Mac", "id": "42"}, \
            "hardware": {"serialNumber": "FRESH001"}}]
            """,
            to: kindDir.appendingPathComponent("computers_20260825T090000.json"),
            modified: Date().addingTimeInterval(-600)
        )

        // Written last, exactly as ReportEngine does — so it is the newest .json
        // in the directory and wins any mtime ordering that does not exclude it.
        try write(
            #"{"algorithm": "SHA-256", "files": {"computers_20260825T090000.json": "abc123"}}"#,
            to: kindDir.appendingPathComponent("manifest.json"),
            modified: Date()
        )

        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)

        XCTAssertEqual(snapshot.devices.count, 1,
                       "the snapshot must still be read when a newer manifest sits beside it")
        XCTAssertEqual(snapshot.devices.first?.serial, "FRESH001")
        XCTAssertFalse(
            snapshot.sourceFiles.contains { $0.lowercased().contains("manifest.json") },
            "integrity metadata must never be reported as a device source"
        )
    }

    /// Guards the fix against being written as a blanket "*.json in a kind dir"
    /// rule: a snapshot whose own name merely contains the word must still load.
    func testOnlyTheManifestFilenameIsExcludedNotEveryNameContainingIt() throws {
        let kindDir = root
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
            .appendingPathComponent("computers", isDirectory: true)

        try write(
            """
            [{"general": {"name": "Odd Name", "id": "7"}, \
            "hardware": {"serialNumber": "ODD007"}}]
            """,
            to: kindDir.appendingPathComponent("computers_manifest_20260825T090000.json"),
            modified: Date()
        )

        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(snapshot.devices.first?.serial, "ODD007")
    }
}
