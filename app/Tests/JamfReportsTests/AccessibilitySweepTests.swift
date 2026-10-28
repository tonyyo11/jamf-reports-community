import XCTest
import SwiftUI
@testable import JamfReports

@MainActor
final class AccessibilitySweepTests: XCTestCase {

    // MARK: - BackupRecord accessibility (production: Models.swift)

    /// BackupsView wires `backup.accessibilityLabel` onto the Table's Backup column.
    func testBackupsViewAccessibilityLabels() {
        let backup = BackupRecord(
            name: "test_backup_20240507",
            label: "Test Backup",
            created: Date(),
            sizeBytes: 1024,
            fileCount: 5,
            url: URL(fileURLWithPath: "/tmp/test")
        )

        let summary = backup.accessibilityLabel
        XCTAssertFalse(summary.isEmpty, "Backup should provide non-empty accessibility label")
        XCTAssertTrue(summary.contains("Test Backup"),
                      "Accessibility label should prefer the backup label")
        XCTAssertTrue(summary.contains("5 files"),
                      "Accessibility label should announce the file count")
    }

    func testBackupRecordAccessibilitySummary() {
        let backup = BackupRecord(
            name: "backup_20240507_143022",
            label: "",
            created: Date(timeIntervalSince1970: 1715083822),
            sizeBytes: 2048,
            fileCount: 12,
            url: URL(fileURLWithPath: "/test/backup")
        )

        let summary = backup.accessibilitySummary
        XCTAssertFalse(summary.isEmpty, "Backup should provide accessibility summary")
        XCTAssertTrue(summary.contains("Configuration backup"),
                      "Summary should describe the record as a configuration backup")
        XCTAssertTrue(summary.contains("12 files"),
                      "Summary should mention the file count")
        XCTAssertTrue(summary.contains("backup_20240507_143022"),
                      "Summary should fall back to the name when no label is set")
    }

    func testBackupRecordWithLabelAccessibilitySummary() {
        let backup = BackupRecord(
            name: "backup_uuid_123",
            label: "Pre-migration Backup",
            created: Date(),
            sizeBytes: 1024000,
            fileCount: 8,
            url: URL(fileURLWithPath: "/test/backup")
        )

        let summary = backup.accessibilitySummary
        XCTAssertTrue(summary.contains("Pre-migration"),
                      "Summary should prefer label over name when available")
    }

    // MARK: - Schedule status accessibility (production: Models.swift)

    /// SchedulesView.statusPill applies `s.accessibilityLabel` from `Schedule.LastStatus`.
    func testScheduleStatusAccessibilityLabels() {
        let schedule = Schedule(
            name: "Daily Reports",
            profile: "production",
            schedule: "Daily 06:00",
            cadence: "daily",
            mode: .jamfCLIFull,
            next: "May 8, 06:00",
            last: "May 7, 06:00",
            lastStatus: .ok,
            artifacts: ["report.xlsx"],
            enabled: true,
            launchAgentLabel: nil,
            multiTarget: nil
        )

        XCTAssertEqual(schedule.accessibilityStatusLabel, "Last run status: OK",
                       "An OK schedule must announce its success state")
        XCTAssertEqual(Schedule.LastStatus.ok.accessibilityLabel, "Last run status: OK")
    }

    func testScheduleFailureStatusAccessibilityLabel() {
        let failedSchedule = Schedule(
            name: "Failed Schedule",
            profile: "test",
            schedule: "Daily 06:00",
            cadence: "daily",
            mode: .jamfCLIFull,
            next: "May 8, 06:00",
            last: "May 7, 06:00",
            lastStatus: .fail,
            artifacts: [],
            enabled: true,
            launchAgentLabel: nil,
            multiTarget: nil
        )

        XCTAssertEqual(failedSchedule.accessibilityStatusLabel, "Last run status: Failed",
                       "A failed schedule must announce its failure state")
        XCTAssertEqual(Schedule.LastStatus.warn.accessibilityLabel, "Last run status: Warning")
        XCTAssertEqual(Schedule.LastStatus.partial.accessibilityLabel, "Last run status: Partial")
    }

    // MARK: - Basic View Construction Tests

    func testViewsCanBeConstructedWithoutCrashing() {
        let workspace = WorkspaceStore(demoMode: true)
        workspace.profile = "test"

        // These should not crash when rendered with test data
        _ = BackupsView().environment(workspace)
        _ = SchedulesView().environment(workspace)
        _ = RunsView().environment(workspace)
        _ = ReportsView().environment(workspace)
        _ = SettingsView().environment(workspace)
        _ = SourcesView().environment(workspace)
        _ = CustomizeView().environment(workspace)

        // OnboardingView requires no specific environment
        _ = OnboardingView()
    }

    // MARK: - StatTile VoiceOver label contract (production: Components.swift)

    /// StatTile.body applies `.accessibilityLabel(fullAccessibilityLabel)`, which
    /// delegates to the `nonisolated static accessibilityLabel(...)` helper asserted here.
    func testStatTileAccessibilityLabel() {
        let label = StatTile.accessibilityLabel(
            label: "FileVault", value: "91%", delta: nil, deltaTrend: .flat, sub: "Encrypted"
        )
        XCTAssertTrue(label.contains("FileVault"), "StatTile label must contain the metric name")
        XCTAssertTrue(label.contains("91%"), "StatTile label must contain the value")
        XCTAssertTrue(label.contains("Encrypted"), "StatTile label must contain the subtitle")
    }

    /// StatTile with an upward delta must include the delta and trend direction.
    func testStatTileWithDeltaAccessibilityLabel() {
        let label = StatTile.accessibilityLabel(
            label: "Compliance", value: "78%", delta: "+3pp", deltaTrend: .up, sub: nil
        )
        XCTAssertTrue(label.contains("up"), "Upward delta must be announced as 'up' for VoiceOver")
        XCTAssertTrue(label.contains("+3pp"), "Delta value must appear in the label")
    }

    /// StatTile with a downward delta must include the 'down' direction.
    func testStatTileWithDownDeltaAccessibilityLabel() {
        let label = StatTile.accessibilityLabel(
            label: "Stale Devices", value: "42", delta: "−5", deltaTrend: .down, sub: nil
        )
        XCTAssertTrue(label.contains("down"), "Downward delta must be announced as 'down'")
    }

    /// The direction word follows the number and the verdict word follows the tile's tone:
    /// a stale count that fell is "down, better", one that rose is "up, worse".
    func testStatTileLabelSaysDirectionOfNumberAndVerdict() {
        let fell = StatTile.accessibilityLabel(
            label: "Stale Devices", value: "37", delta: "−5", deltaTrend: .up, sub: nil
        )
        XCTAssertEqual(fell, "Stale Devices: 37, down −5, better")
        let rose = StatTile.accessibilityLabel(
            label: "Stale Devices", value: "47", delta: "+5", deltaTrend: .down, sub: nil
        )
        XCTAssertEqual(rose, "Stale Devices: 47, up +5, worse")
        let share = StatTile.accessibilityLabel(
            label: "FileVault", value: "91.0%", delta: "−1.0pp", deltaTrend: .down, sub: nil
        )
        XCTAssertEqual(share, "FileVault: 91.0%, down −1.0pp, worse")
    }

    /// A tile with no verdict announces no direction.
    func testStatTileLabelOmitsFlatDelta() {
        let label = StatTile.accessibilityLabel(
            label: "Managed Computers", value: "500", delta: "+12", deltaTrend: .flat, sub: nil
        )
        XCTAssertEqual(label, "Managed Computers: 500")
    }

    /// The Overview tile takes its verdict from `Metric.polarity`, as the Trends hero does.
    func testOverviewTileTrendFollowsPolarity() {
        XCTAssertEqual(OverviewView.tileTrend(
            metric: .stale, previous: 10, current: 8, comparable: true), .up)
        XCTAssertEqual(OverviewView.tileTrend(
            metric: .stale, previous: 8, current: 10, comparable: true), .down)
        XCTAssertEqual(OverviewView.tileTrend(
            metric: .fileVault, previous: 90, current: 91, comparable: true), .up)
        XCTAssertEqual(OverviewView.tileTrend(
            metric: .fileVault, previous: 91, current: 90, comparable: true), .down)
        XCTAssertEqual(OverviewView.tileTrend(
            metric: .mobileJailbroken, previous: 1, current: 3, comparable: true), .down)
        XCTAssertEqual(OverviewView.tileTrend(
            metric: .managedDevices, previous: 400, current: 450, comparable: true), .flat)
        XCTAssertEqual(OverviewView.tileTrend(
            metric: .fileVault, previous: 90, current: 91, comparable: false), .flat)
    }

    // MARK: - Chart wiring VoiceOver contract

    /// TrendsView hero chart uses .accessibilityChartDescriptor(TrendLineChartDescriptor(...)).
    /// Assert the contract: the descriptor type must be AXChartDescriptorRepresentable-conforming.
    func testTrendLineChartDescriptorConformsToRepresentable() {
        let descriptor = TrendLineChartDescriptor(
            title: "Test Trend",
            seriesName: "Metric",
            dates: [Date()],
            values: [50.0],
            unit: "%"
        )
        // Conformance is a compile-time check. This runtime call validates the descriptor
        // produces a non-crashing AXChartDescriptor with the correct title.
        let ax = descriptor.makeChartDescriptor()
        XCTAssertEqual(ax.title, "Test Trend")
        XCTAssertFalse(ax.series.isEmpty, "Descriptor must have at least one series")
    }

    /// SectorChartDescriptor must be usable for OS distribution donuts on SecurityPostureView.
    func testSectorChartDescriptorForOSDistribution() {
        let descriptor = SectorChartDescriptor(
            title: "macOS Distribution",
            unit: "%",
            slices: [
                .init(label: "Tahoe", value: 61.0),
                .init(label: "Sonoma", value: 29.0),
                .init(label: "Other", value: 10.0),
            ]
        )
        let ax = descriptor.makeChartDescriptor()
        XCTAssertEqual(ax.series[0].dataPoints.count, 3)
        // Summary must list all slices so VoiceOver can read out the full distribution
        XCTAssertTrue(ax.summary?.contains("Tahoe") ?? false)
        XCTAssertTrue(ax.summary?.contains("Sonoma") ?? false)
    }

    // MARK: - v2.1.1 Accessibility Fixes

    /// EmptyStateView reads its commands as their own elements (#101, #318): the combined
    /// label holds the title and message only, so a command is not read twice.
    func testEmptyStateViewKeepsCommandsOutOfTheCombinedLabel() {
        let emptyState = EmptyStateView(
            title: "No compliance snapshot yet",
            message: "Run jamf-cli to populate this screen.",
            commands: ["jamf-reports collect --profile acme --tiers refresh"]
        )
        XCTAssertEqual(emptyState.accessibilityLabelText,
                       "No compliance snapshot yet. Run jamf-cli to populate this screen.")
        XCTAssertEqual(emptyState.commands, ["jamf-reports collect --profile acme --tiers refresh"])
    }

    /// EditableNumberStepper names its field from the label, else the prefix and suffix text.
    func testEditableNumberStepperAccessibilityName() {
        typealias Stepper = EditableNumberStepper
        XCTAssertEqual(Stepper.accessibilityName(label: "Stale after days", prefix: "Stale", suffix: "d"),
                       "Stale after days")
        XCTAssertEqual(Stepper.accessibilityName(label: nil, prefix: "Stale", suffix: "d"), "Stale d")
        XCTAssertEqual(Stepper.accessibilityName(label: nil, prefix: nil, suffix: "pts"), "pts")
        XCTAssertEqual(Stepper.accessibilityName(label: "", prefix: nil, suffix: nil), "Value")
    }

    /// The workspace chip names the error dot; the activation phrase is a hint, not label text.
    func testWorkspaceChipLabelNamesErrorState() {
        let ok = Sidebar.workspaceChipLabel(profile: "prod", subtitle: "2 workspaces", hasError: false)
        let bad = Sidebar.workspaceChipLabel(profile: "prod", subtitle: "2 workspaces", hasError: true)
        XCTAssertEqual(ok, "Workspace: prod. 2 workspaces.")
        XCTAssertTrue(bad.contains("Has an error"))
        XCTAssertFalse(bad.contains("Activate"))
    }

    /// A stale School device says so in words, not only in the warning color.
    func testSchoolDeviceStaleStateIsSpoken() {
        let now = Date()
        let device = SchoolFleetService.Device(
            id: "1", name: "iPad", serial: "S1", model: "iPad", os: "iPadOS 18",
            isManaged: true, isSupervised: true,
            lastCheckin: now.addingTimeInterval(-45 * 86_400), inTrash: false)
        XCTAssertEqual(
            SchoolDevicesTable.checkinAccessibilityValue(device, stale: true, now: now),
            "Stale, 45 days ago")
        XCTAssertEqual(
            SchoolDevicesTable.checkinAccessibilityValue(device, stale: false, now: now),
            "45 days ago")
    }

    /// Icon-only remove buttons say what they remove.
    func testRemoveButtonLabelNamesTarget() {
        XCTAssertEqual(removeButtonLabel(noun: "benchmark", name: "CIS Level 1"),
                       "Remove benchmark CIS Level 1")
        XCTAssertEqual(removeButtonLabel(noun: "benchmark", name: "  "), "Remove benchmark")
    }
}
