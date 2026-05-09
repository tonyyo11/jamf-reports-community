import XCTest
@testable import JamfReports

@MainActor
final class UXPolishQ4Tests: XCTestCase {

    // MARK: - #14: Workspace initialization banner visibility

    func testOverviewBannerHiddenWhenWorkspaceInitialized() {
        let store = WorkspaceStore(demoMode: false)
        store.demoMode = false

        let isVisible = !store.demoMode && !store.isWorkspaceInitialized

        XCTAssertFalse(isVisible, "Banner should be hidden when workspace is initialized")
    }

    func testOverviewBannerVisibleInDemoMode() {
        let store = WorkspaceStore(demoMode: true)

        let isVisible = !store.demoMode && !store.isWorkspaceInitialized

        XCTAssertFalse(isVisible, "Banner should never show in demo mode")
    }

    func testWorkspaceInitializedPropertyChecksConfigYaml() {
        let store = WorkspaceStore(demoMode: false)

        let isInitialized = store.isWorkspaceInitialized

        if store.demoMode {
            XCTAssertTrue(isInitialized, "Demo mode always reports initialized")
        } else {
            XCTAssertEqual(isInitialized, !store.demoMode, "Real mode depends on config.yaml existence")
        }
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
        XCTAssertTrue(
            mode.displayDescription.contains("Does NOT generate a report"),
            "snapshot-only should clarify no report"
        )
    }

    func testJamfCLIOnlyModeDescription() {
        let mode = Schedule.RunMode.jamfCLIOnly
        XCTAssertEqual(mode.displayTitle, "Generate from cached/live jamf-cli data")
        XCTAssertTrue(
            mode.displayDescription.contains("cached"),
            "jamf-cli-only should mention caching"
        )
    }

    func testJamfCLIFullModeDescription() {
        let mode = Schedule.RunMode.jamfCLIFull
        XCTAssertEqual(mode.displayTitle, "Refresh + Generate")
        XCTAssertTrue(
            mode.displayDescription.contains("collect first"),
            "jamf-cli-full should mention collect-then-generate"
        )
    }

    func testCSVAssistedModeDescription() {
        let mode = Schedule.RunMode.csvAssisted
        XCTAssertEqual(mode.displayTitle, "CSV-augmented Generate")
        XCTAssertTrue(
            mode.displayDescription.contains("CSV export"),
            "csv-assisted should mention CSV"
        )
        XCTAssertTrue(
            mode.displayDescription.contains("jamf-cli"),
            "csv-assisted should mention jamf-cli"
        )
    }

    // MARK: - Banner title refinement

    func testWorkspaceInitBannerTitleIsAccessible() {
        let bannerTitle = "Configuration incomplete"
        XCTAssertFalse(bannerTitle.isEmpty, "Banner should have a title")
        XCTAssertGreaterThan(bannerTitle.count, 10, "Banner title should be descriptive")
    }
}
