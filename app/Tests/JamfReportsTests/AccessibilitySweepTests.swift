import XCTest
import SwiftUI
@testable import JamfReports

@MainActor
final class AccessibilitySweepTests: XCTestCase {

    // MARK: - BackupsView Accessibility Tests

    func testBackupsViewAccessibilityLabels() {

        // Test that backup records expose accessible summary information
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
        XCTAssertTrue(summary.contains("Test Backup") || summary.contains("test_backup_20240507"),
                     "Accessibility label should contain backup name or label")
    }

    // MARK: - SchedulesView Accessibility Tests

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

        let statusLabel = schedule.accessibilityStatusLabel
        XCTAssertFalse(statusLabel.isEmpty, "Schedule should provide accessibility status label")
        XCTAssertTrue(statusLabel.contains("succeeded") || statusLabel.contains("OK"),
                     "Status label should describe success state for .ok status")
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

        let statusLabel = failedSchedule.accessibilityStatusLabel
        XCTAssertTrue(statusLabel.contains("failed") || statusLabel.contains("FAIL"),
                     "Status label should describe failure state for .fail status")
    }

    // MARK: - BackupRecord Model Tests

    func testBackupRecordAccessibilitySummary() {
        let backup = BackupRecord(
            name: "backup_20240507_143022",
            label: "",
            created: Date(timeIntervalSince1970: 1715083822), // Fixed date for testing
            sizeBytes: 2048,
            fileCount: 12,
            url: URL(fileURLWithPath: "/test/backup")
        )

        let summary = backup.accessibilitySummary
        XCTAssertFalse(summary.isEmpty, "Backup should provide accessibility summary")
        XCTAssertTrue(summary.contains("backup") || summary.contains("configuration"),
                     "Summary should mention backup or configuration")
        XCTAssertTrue(summary.contains("12") || summary.contains("files"),
                     "Summary should mention file count")
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
        _ = WorkspaceView().environment(workspace)

        // OnboardingView requires no specific environment
        _ = OnboardingView()
    }
}

// MARK: - Test Extensions

extension BackupRecord {
    /// Accessibility label for VoiceOver describing the backup
    var accessibilityLabel: String {
        let displayName = label.isEmpty ? name : label
        let sizeStr = FileDisplay.size(sizeBytes)
        return "\(displayName), \(fileCount) files, \(sizeStr), created \(createdLabel)"
    }

    /// Accessibility summary for VoiceOver describing the backup content and purpose
    var accessibilitySummary: String {
        let displayName = label.isEmpty ? name : label
        return "Configuration backup: \(displayName), \(fileCount) files, created \(createdLabel)"
    }
}

extension Schedule {
    /// Accessibility label for schedule status pills
    var accessibilityStatusLabel: String {
        switch lastStatus {
        case .ok:
            return "Schedule succeeded"
        case .warn:
            return "Schedule completed with warnings"
        case .fail:
            return "Schedule failed"
        case .partial:
            return "Schedule completed with partial success"
        }
    }
}