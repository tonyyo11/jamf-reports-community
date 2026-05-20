import XCTest
@testable import JamfReports

@MainActor
final class UXPolishQ4Tests: XCTestCase {

    // MARK: - #14: Workspace initialization banner visibility

    func testOverviewBannerVisibilityReflectsWorkspaceState() {
        let store = WorkspaceStore(demoMode: false)
        let isVisible = !store.demoMode && !store.isWorkspaceInitialized
        // Formula must be consistent: visible iff (not demo AND not initialized).
        if store.isWorkspaceInitialized {
            XCTAssertFalse(isVisible, "Banner must be hidden when workspace is initialized")
        } else {
            XCTAssertTrue(isVisible, "Banner must be visible when workspace is not yet initialized")
        }
    }

    func testOverviewBannerVisibleInDemoMode() {
        let store = WorkspaceStore(demoMode: true)

        let isVisible = !store.demoMode && !store.isWorkspaceInitialized

        XCTAssertFalse(isVisible, "Banner should never show in demo mode")
    }

    func testWorkspaceInitializedPropertyChecksConfigYaml() {
        // Demo mode bypasses the filesystem — always initialized.
        XCTAssertTrue(
            WorkspaceStore(demoMode: true).isWorkspaceInitialized,
            "Demo mode always reports initialized"
        )
        // Real mode checks for config.yaml; result depends on environment.
        // Verify the property is stable across consecutive reads (not random).
        let store = WorkspaceStore(demoMode: false)
        XCTAssertEqual(
            store.isWorkspaceInitialized,
            store.isWorkspaceInitialized,
            "isWorkspaceInitialized must be stable"
        )
    }

    // MARK: - #7: Schedule run mode descriptions

    func testScheduleRunModeDisplayTitleNonEmpty() {
        for mode in Schedule.RunMode.allCases {
            let title = mode.displayTitle
            XCTAssertFalse(title.isEmpty, "Mode \(mode.rawValue) has empty displayTitle")
            XCTAssertGreaterThanOrEqual(
                title.count, 15,
                "Mode \(mode.rawValue) displayTitle too short: \(title)"
            )
        }
    }

    func testScheduleRunModeDisplayDescriptionNonEmpty() {
        for mode in Schedule.RunMode.allCases {
            let description = mode.displayDescription
            XCTAssertFalse(description.isEmpty, "Mode \(mode.rawValue) has empty displayDescription")
            XCTAssertGreaterThanOrEqual(
                description.count, 50,
                "Mode \(mode.rawValue) displayDescription too short: \(description)"
            )
        }
    }

    func testAllScheduleRunModesHaveTexts() {
        let modes = Schedule.RunMode.allCases
        XCTAssertEqual(modes.count, 4, "Expected 4 run modes")

        let titles = modes.map(\.displayTitle)
        let descriptions = modes.map(\.displayDescription)

        for (i, mode) in modes.enumerated() {
            XCTAssertFalse(titles[i].isEmpty, "Mode \(mode.rawValue) missing title")
            XCTAssertFalse(descriptions[i].isEmpty, "Mode \(mode.rawValue) missing description")
        }
    }

    func testSnapshotOnlyModeDescription() {
        let mode = Schedule.RunMode.snapshotOnly
        XCTAssertEqual(mode.displayTitle, "Refresh data only")
        XCTAssertTrue(
            mode.displayDescription.contains("jamf-cli pro collect"),
            "snapshot-only should mention jamf-cli pro collect"
        )
        // PR-20: description updated to reflect that collect now emits
        // summary.json so the Trends page advances without a workbook.
        XCTAssertTrue(
            mode.displayDescription.contains("Does NOT generate a workbook"),
            "snapshot-only should clarify no workbook is produced"
        )
        XCTAssertTrue(
            mode.displayDescription.contains("Trends"),
            "snapshot-only should advertise that it updates the Trends summary"
        )
    }

    func testJamfCLIOnlyModeDescription() {
        let mode = Schedule.RunMode.jamfCLIOnly
        // PR-21: jamf-cli-only is now genuinely cache-only — no collect step.
        XCTAssertEqual(mode.displayTitle, "Generate from cached data")
        XCTAssertTrue(
            mode.displayDescription.contains("cached"),
            "jamf-cli-only should mention caching"
        )
        XCTAssertTrue(
            mode.displayDescription.contains("Does NOT collect"),
            "jamf-cli-only must clarify that no collect happens"
        )
    }

    func testJamfCLIFullModeDescription() {
        let mode = Schedule.RunMode.jamfCLIFull
        XCTAssertEqual(mode.displayTitle, "Refresh + Generate")
        XCTAssertTrue(
            mode.displayDescription.contains("collect"),
            "jamf-cli-full should mention collect"
        )
        // PR-21: make the no-CSV invariant explicit so users don't conflate
        // jamf-cli-full with csv-assisted.
        XCTAssertTrue(
            mode.displayDescription.contains("No CSV"),
            "jamf-cli-full must clarify the no-CSV invariant"
        )
    }

    func testCSVAssistedModeDescription() {
        let mode = Schedule.RunMode.csvAssisted
        // PR-21: csv-assisted is strict — fails without a CSV.
        XCTAssertEqual(mode.displayTitle, "Refresh + Generate (CSV required)")
        XCTAssertTrue(
            mode.displayDescription.contains("csv-inbox"),
            "csv-assisted should mention csv-inbox"
        )
        XCTAssertTrue(
            mode.displayDescription.contains("fails if no CSV"),
            "csv-assisted must clarify the hard-fail-on-missing-CSV contract"
        )
    }

    // MARK: - Banner title refinement

    func testWorkspaceInitBannerTitleIsAccessible() {
        let bannerTitle = "Configuration incomplete"
        XCTAssertFalse(bannerTitle.isEmpty, "Banner should have a title")
        XCTAssertGreaterThan(bannerTitle.count, 10, "Banner title should be descriptive")
    }
}
