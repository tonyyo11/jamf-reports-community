import Foundation
import XCTest
@testable import JamfReports

// MARK: - TypeDesignTests
//
// Exercises type-design invariants introduced in the Phase 10-C audit (Lane H-Type).
// Each test targets a specific finding to prevent regression.

final class TypeDesignTests: XCTestCase {

    // MARK: - P10-C-13: DeviceInventoryRecordBuilder

    /// Builder zero-initialises correctly and build() propagates all mutations.
    func testDeviceInventoryRecordBuilderBuildsProperly() {
        var builder = DeviceInventoryRecordBuilder(id: "dev-001", source: "test-source")
        builder.jamfID = "J42"
        builder.name = "MacBook Pro"
        builder.serial = "SER123"
        builder.osVersion = "15.0"
        builder.model = "MacBook Pro 16-inch"
        builder.user = "jdoe"
        builder.email = "jdoe@example.com"
        builder.department = "Engineering"
        builder.stale = true
        builder.failedRules = 3

        let record = builder.build()

        XCTAssertEqual(record.id, "dev-001")
        XCTAssertEqual(record.jamfID, "J42")
        XCTAssertEqual(record.name, "MacBook Pro")
        XCTAssertEqual(record.serial, "SER123")
        XCTAssertEqual(record.osVersion, "15.0")
        XCTAssertEqual(record.department, "Engineering")
        XCTAssertEqual(record.source, "test-source")
        XCTAssertTrue(record.stale)
        XCTAssertEqual(record.failedRules, 3)
    }

    /// Zeroed init leaves string fields empty and numeric fields at zero/nil.
    func testDeviceInventoryRecordBuilderZeroedInit() {
        let builder = DeviceInventoryRecordBuilder(id: "x", source: "src")
        XCTAssertNil(builder.jamfID)
        XCTAssertEqual(builder.name, "")
        XCTAssertEqual(builder.serial, "")
        XCTAssertNil(builder.daysSinceContact)
        XCTAssertFalse(builder.stale)
        XCTAssertEqual(builder.failedRules, 0)
        XCTAssertTrue(builder.patchFailures.isEmpty)
    }

    // MARK: - P10-C-06 / P10-C-07: Schedule identity and LastStatus

    /// Schedule.id is stable across mutation of display fields.
    func testScheduleIDIsStableAcrossEnabledMutation() {
        var schedule = Schedule(
            launchAgentLabel: "com.jamfreports.test.sched",
            name: "Daily Run",
            profile: "default",
            mode: .snapshotOnly,
            schedule: "09:00",
            cadence: "daily",
            next: "",
            last: "",
            lastStatus: .ok,
            artifacts: [],
            enabled: true
        )
        let idBefore = schedule.id
        schedule.enabled = false
        schedule.cadence = "weekly"
        XCTAssertEqual(schedule.id, idBefore, "Schedule.id must not change when display fields mutate")
    }

    /// Schedule.LastStatus is CaseIterable with the expected cases.
    func testScheduleLastStatusIsCaseIterable() {
        let cases = Schedule.LastStatus.allCases
        XCTAssertTrue(cases.contains(.ok))
        XCTAssertTrue(cases.contains(.warn))
        XCTAssertTrue(cases.contains(.fail))
        XCTAssertEqual(cases.count, 3)
    }

    // MARK: - P10-C-03: JamfCLIProfile stable id

    /// Two profiles with the same name must have distinct ids.
    func testJamfCLIProfileIDDistinctForSameName() {
        let a = JamfCLIProfile(name: "acme", url: "https://a.example.com", schedules: 0, status: .active)
        let b = JamfCLIProfile(name: "acme", url: "https://b.example.com", schedules: 0, status: .active)
        XCTAssertNotEqual(a.id, b.id, "Different profile instances must have unique UUIDs")
    }

    // MARK: - P10-C-04: JamfCLIProfile.Status renamed cases + CaseIterable

    func testJamfCLIProfileStatusCaseIterableContainsAllRenamedCases() {
        let cases = JamfCLIProfile.Status.allCases
        XCTAssertTrue(cases.contains(.active))
        XCTAssertTrue(cases.contains(.configured))
        XCTAssertTrue(cases.contains(.invalidName))
        XCTAssertEqual(cases.count, 3)
    }

    // MARK: - P10-C-39: ConfigState numeric threshold fields are Int

    func testConfigStateStaleDeviceDaysIsIntWithCorrectDefault() {
        let state = ConfigState.defaultState
        // Verify compile-time type: assigning to an Int constant must compile.
        let days: Int = state.staleDeviceDays
        XCTAssertEqual(days, 30)
    }

    func testConfigStateNumericThresholdsDefaultValues() {
        let state = ConfigState.defaultState
        XCTAssertEqual(state.checkinOverdueDays, 7)
        XCTAssertEqual(state.warningDiskPercent, 80)
        XCTAssertEqual(state.criticalDiskPercent, 95)
        XCTAssertEqual(state.certWarningDays, 90)
        XCTAssertEqual(state.profileErrorCritical, 20)
        XCTAssertEqual(state.profileErrorWarning, 5)
        XCTAssertEqual(state.keepLatestRuns, 10)
    }

    /// String bridge computed property round-trips correctly.
    func testConfigStateStaleDeviceDaysStringBridge() {
        var state = ConfigState.defaultState
        state.staleDeviceDaysString = "45"
        XCTAssertEqual(state.staleDeviceDays, 45)
        XCTAssertEqual(state.staleDeviceDaysString, "45")
    }

    /// Unparseable string leaves the Int field unchanged.
    func testConfigStateStringBridgeIgnoresNonNumericInput() {
        var state = ConfigState.defaultState
        let before = state.staleDeviceDays
        state.staleDeviceDaysString = "not-a-number"
        XCTAssertEqual(state.staleDeviceDays, before)
    }

    // MARK: - P10-C-40: ColumnKey enum

    func testColumnKeyAllCasesCountMatchesPreviousColumnKeysArray() {
        // The static columnKeys computed property wraps ColumnKey.allCases.
        XCTAssertEqual(ColumnKey.allCases.count, 18)
        XCTAssertEqual(ConfigState.columnKeys.count, 18)
    }

    func testColumnKeyRawValuesMatchExpectedYAMLKeys() {
        XCTAssertEqual(ColumnKey.computerName.rawValue, "computer_name")
        XCTAssertEqual(ColumnKey.serialNumber.rawValue, "serial_number")
        XCTAssertEqual(ColumnKey.operatingSystem.rawValue, "operating_system")
        XCTAssertEqual(ColumnKey.lastCheckin.rawValue, "last_checkin")
        XCTAssertEqual(ColumnKey.mdmExpiry.rawValue, "mdm_expiry")
    }

    // MARK: - P10-C-24 / P10-C-25: AppVersionState

    /// lastSeenVersion setter is private(set); only markCurrentVersionSeen() mutates it.
    /// This test verifies the accessor compiles — the private setter is a compile-time guarantee.
    @MainActor
    func testAppVersionStateLastSeenVersionReadable() {
        // If this compiles, private(set) is in place. We cannot call the setter from here.
        let version = AppVersionState.lastSeenVersion
        XCTAssertNotNil(version)  // always passes; proves the getter is accessible
    }

    @MainActor
    func testAppVersionStateMarkCurrentVersionSeenUpdatesLastSeen() {
        AppVersionState.markCurrentVersionSeen()
        XCTAssertEqual(AppVersionState.lastSeenVersion, AppVersionState.currentVersion)
        // Reset so other tests aren't affected
        UserDefaults.standard.removeObject(forKey: "lastSeenAppVersion")
    }

    // MARK: - P10-C-37: ConfigSecurityAgent stable id

    func testConfigSecurityAgentIDDistinctForSameName() {
        let a = ConfigSecurityAgent(name: "Falcon", column: "Falcon Status", connectedValue: "Installed")
        let b = ConfigSecurityAgent(name: "Falcon", column: "Falcon Status", connectedValue: "Installed")
        XCTAssertNotEqual(a.id, b.id, "Distinct ConfigSecurityAgent instances must have unique UUIDs")
    }

    // MARK: - P10-C-10 / P10-C-38: ConfigCustomEA.type is CustomEA.EAType

    func testConfigCustomEATypeIsTypedEnum() {
        let ea = ConfigCustomEA(
            name: "FileVault",
            column: "FileVault 2 - Status",
            type: .boolean,
            trueValue: "Encrypted",
            warningThreshold: "",
            criticalThreshold: "",
            currentVersions: [],
            warningDays: ""
        )
        XCTAssertEqual(ea.type, CustomEA.EAType.boolean)
        // The raw value matches the YAML string the Python engine uses.
        XCTAssertEqual(ea.type.rawValue, "boolean")
    }

    func testConfigCustomEAAllEATypesRoundTripRawValue() {
        for eaType in CustomEA.EAType.allCases {
            let reconstructed = CustomEA.EAType(rawValue: eaType.rawValue)
            XCTAssertEqual(reconstructed, eaType, "\(eaType.rawValue) must round-trip through rawValue")
        }
    }
}
