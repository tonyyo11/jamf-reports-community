import XCTest
@testable import JamfReports

/// The Config Doctor's cloud-storage family. Pure rules — no synced volume
/// required — so the guidance itself is pinned.
final class ConfigDoctorCloudStorageTests: XCTestCase {

    private let home = NSString(string: "~").expandingTildeInPath
    private func local(_ path: String) -> URL { URL(fileURLWithPath: "\(home)/Jamf-Reports/\(path)") }
    private func cloud(_ path: String) -> URL {
        URL(fileURLWithPath: "\(home)/Library/CloudStorage/OneDrive-Contoso/\(path)")
    }

    private func inputs(
        workspace: URL? = nil, output: URL? = nil, archive: URL? = nil,
        backups: URL? = nil, conflicts: [String] = []
    ) -> CloudStorageInputs {
        CloudStorageInputs(
            workspace: workspace, outputDir: output, archiveDir: archive,
            backupsDir: backups, conflictCopies: conflicts
        )
    }

    func testFullyLocalWorkspaceEmitsNothing() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"), output: local("prod/Generated Reports"),
            archive: local("prod/Generated Reports/archive"), backups: local("prod/backups")
        ))
        XCTAssertTrue(rows.isEmpty, "the default layout should be silent")
    }

    func testWorkspaceOnCloudWarnsAndRecommendsPublishingInstead() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/Jamf Reports/prod"),
            output: cloud("Team/Jamf Reports/prod/Generated Reports")
        ))
        let row = rows.first { $0.id == "cloud.workspace" }
        XCTAssertEqual(row?.severity, .warn)
        XCTAssertTrue(row?.title.contains("OneDrive") == true)
        XCTAssertTrue(row?.hint?.contains("output.output_dir") == true)
        XCTAssertNil(
            rows.first { $0.id == "cloud.output" },
            "don't also congratulate a workspace that is itself on the share"
        )
    }

    func testPublishOnlyLayoutPasses() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"), output: cloud("Team/Jamf Reports"),
            backups: local("prod/backups")
        ))
        let row = rows.first { $0.id == "cloud.output" }
        XCTAssertEqual(row?.severity, .pass, "workspace local + reports shared is the target shape")
        XCTAssertNil(rows.first { $0.id == "cloud.workspace" })
    }

    func testArchiveOnCloudWithoutOutputIsFlagged() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"), output: local("prod/Generated Reports"),
            archive: cloud("Team/Archive")
        ))
        XCTAssertEqual(rows.first { $0.id == "cloud.archive" }?.severity, .warn)
    }

    func testBackupsOnCloudExplainsThatPruningIsDisabled() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"), backups: cloud("Team/backups")
        ))
        let row = rows.first { $0.id == "cloud.backups" }
        XCTAssertEqual(row?.severity, .warn)
        XCTAssertTrue(row?.detail.contains("pruning") == true)
    }

    func testConflictCopiesAreReportedWithASample() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"),
            conflicts: ["summary_2026-08-20 2.json", "computers (1).json",
                        "config copy.yaml", "extra 4.json"]
        ))
        let row = rows.first { $0.id == "cloud.conflicts" }
        XCTAssertEqual(row?.severity, .warn)
        XCTAssertTrue(row?.title.contains("4 sync-conflict") == true)
        XCTAssertTrue(row?.detail.contains("+1 more") == true)
    }
}
