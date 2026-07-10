import XCTest
@testable import JamfReports

@MainActor
final class MobileFleetServiceTests: XCTestCase {

    func testViewInstantiatesInDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.demoMode = true

        _ = MobileFleetView()
            .environment(workspace)
    }

    func testViewInstantiatesInNonDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.demoMode = false

        _ = MobileFleetView()
            .environment(workspace)
    }

    func testLoadWithAllNilURLsReturnsEmpty() throws {
        let snapshot = MobileFleetService.load(listURL: nil, inventoryURL: nil, profilesURL: nil)

        XCTAssertEqual(snapshot, MobileFleetService.Snapshot.empty)
        XCTAssertFalse(snapshot.isDetected)
        XCTAssertEqual(snapshot.totalDevices, 0)
    }

    func testDecodeParityListOnly() throws {
        let listJSON = """
        [
            {
                "id": "1001",
                "name": "iPad-Lab-001",
                "model": "iPad",
                "serialNumber": "DMPH12345678",
                "username": "student001",
                "type": "iPad"
            },
            {
                "id": "1002",
                "name": "iPhone-Executive-002",
                "model": "iPhone 15",
                "serialNumber": "F2LW87654321",
                "username": "jexecutive",
                "type": "iPhone"
            },
            {
                "id": "1003",
                "name": "iPad-Marketing-003",
                "model": "iPad Pro",
                "serialNumber": "DMPH87654321",
                "username": "muser",
                "type": "iPad"
            }
        ]
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-mobile-list.json")
        try listJSON.write(to: tempURL, atomically: true, encoding: .utf8)

        let snapshot = MobileFleetService.load(listURL: tempURL, inventoryURL: nil, profilesURL: nil)

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.totalDevices, 3)
        XCTAssertEqual(snapshot.iPadCount, 2)
        XCTAssertEqual(snapshot.iPhoneCount, 1)
        XCTAssertEqual(snapshot.appleTVCount, 0)
        XCTAssertEqual(snapshot.lightDevices.count, 3)
        XCTAssertEqual(snapshot.richDevices.count, 0)

        // Clean up
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testDecodeParityInventoryDetails() throws {
        let inventoryJSON = """
        [
            {
                "mobileDeviceId": "1001",
                "deviceType": "iPad",
                "general": {
                    "displayName": "iPad-Lab-001",
                    "serialNumber": "DMPH12345678",
                    "osVersion": "18.2.1",
                    "managed": true,
                    "supervised": true,
                    "lastInventoryUpdateDate": "2025-01-10T14:30:00Z",
                    "deviceOwnershipType": "Institutional",
                    "activationLockEnabled": true,
                    "passcodeCompliant": true,
                    "dataProtectionEnabled": true,
                    "jailbreakDetected": "None"
                },
                "userAndLocation": {
                    "username": "student001",
                    "emailAddress": "student001@example.com",
                    "department": "Education",
                    "building": "Main Campus"
                }
            },
            {
                "mobileDeviceId": "1002",
                "deviceType": "iPhone",
                "general": {
                    "displayName": "iPhone-Executive-002",
                    "serialNumber": "F2LW87654321",
                    "osVersion": "18.1.1",
                    "managed": true,
                    "supervised": false,
                    "lastInventoryUpdateDate": "2025-01-09T16:45:00Z",
                    "deviceOwnershipType": "Corporate",
                    "activationLockEnabled": false,
                    "passcodeCompliant": false,
                    "dataProtectionEnabled": true,
                    "jailbreakDetected": "Detected"
                },
                "userAndLocation": {
                    "username": "jexecutive",
                    "emailAddress": "j.executive@example.com",
                    "department": "Executive",
                    "building": "HQ"
                }
            }
        ]
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-mobile-inventory.json")
        try inventoryJSON.write(to: tempURL, atomically: true, encoding: .utf8)

        let snapshot = MobileFleetService.load(listURL: nil, inventoryURL: tempURL, profilesURL: nil)

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.totalDevices, 2)
        XCTAssertEqual(snapshot.iPadCount, 1)
        XCTAssertEqual(snapshot.iPhoneCount, 1)
        XCTAssertEqual(snapshot.managedCount, 2)
        XCTAssertEqual(snapshot.supervisedCount, 1)
        XCTAssertEqual(snapshot.passcodeCompliantCount, 1)
        XCTAssertEqual(snapshot.activationLockEnabledCount, 1)
        XCTAssertEqual(snapshot.jailbreakDetectedCount, 1)
        XCTAssertEqual(snapshot.richDevices.count, 2)
        XCTAssertEqual(snapshot.lightDevices.count, 0)

        // Clean up
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testOSDistributionSortedAndLimited() throws {
        let inventoryJSON = """
        [
            {"mobileDeviceId": "1", "deviceType": "iPad", "general": {"osVersion": "18.2.1"}},
            {"mobileDeviceId": "2", "deviceType": "iPad", "general": {"osVersion": "18.2.1"}},
            {"mobileDeviceId": "3", "deviceType": "iPad", "general": {"osVersion": "18.2.1"}},
            {"mobileDeviceId": "4", "deviceType": "iPad", "general": {"osVersion": "18.1.1"}},
            {"mobileDeviceId": "5", "deviceType": "iPad", "general": {"osVersion": "18.1.1"}},
            {"mobileDeviceId": "6", "deviceType": "iPad", "general": {"osVersion": "17.6.1"}},
            {"mobileDeviceId": "7", "deviceType": "iPad", "general": {"osVersion": "17.5.1"}},
            {"mobileDeviceId": "8", "deviceType": "iPad", "general": {"osVersion": "17.4.1"}},
            {"mobileDeviceId": "9", "deviceType": "iPad", "general": {"osVersion": "17.3.1"}},
            {"mobileDeviceId": "10", "deviceType": "iPad", "general": {"osVersion": "17.2.1"}},
            {"mobileDeviceId": "11", "deviceType": "iPad", "general": {"osVersion": "17.1.1"}},
            {"mobileDeviceId": "12", "deviceType": "iPad", "general": {"osVersion": "16.7.1"}},
            {"mobileDeviceId": "13", "deviceType": "iPad", "general": {"osVersion": "16.6.1"}},
            {"mobileDeviceId": "14", "deviceType": "iPad", "general": {"osVersion": "16.5.1"}},
            {"mobileDeviceId": "15", "deviceType": "iPad", "general": {"osVersion": "16.4.1"}}
        ]
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-os-distribution.json")
        try inventoryJSON.write(to: tempURL, atomically: true, encoding: .utf8)

        let snapshot = MobileFleetService.load(listURL: nil, inventoryURL: tempURL, profilesURL: nil)

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.totalDevices, 15)

        // Check OS distribution is sorted by count (descending) and limited to 10
        let osDistribution = snapshot.osDistribution
        XCTAssertLessThanOrEqual(osDistribution.count, 10)

        // First should be most common (18.2.1 with 3 devices)
        XCTAssertEqual(osDistribution.first?.osVersion, "18.2.1")
        XCTAssertEqual(osDistribution.first?.count, 3)

        // Second should be second most common (18.1.1 with 2 devices)
        if osDistribution.count > 1 {
            XCTAssertEqual(osDistribution[1].osVersion, "18.1.1")
            XCTAssertEqual(osDistribution[1].count, 2)
        }

        // Clean up
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testEmptyArraysStillDetected() throws {
        let emptyListJSON = "[]"

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-empty-list.json")
        try emptyListJSON.write(to: tempURL, atomically: true, encoding: .utf8)

        let snapshot = MobileFleetService.load(listURL: tempURL, inventoryURL: nil, profilesURL: nil)

        XCTAssertTrue(snapshot.isDetected) // File exists, so detected = true
        XCTAssertEqual(snapshot.totalDevices, 0)
        XCTAssertEqual(snapshot.iPadCount, 0)
        XCTAssertEqual(snapshot.iPhoneCount, 0)

        // Clean up
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - CacheSource derivation

    func testCacheSourceWithNilSnapshotDate() {
        let snapshot = MobileFleetService.Snapshot(
            isDetected: false,
            lightDevices: [],
            richDevices: [],
            profiles: [],
            sourceFile: nil,
            snapshotDate: nil
        )
        XCTAssertEqual(snapshot.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceWithFreshSnapshotDate() {
        let recent = Date(timeIntervalSinceNow: -1800) // 30 minutes ago
        let snapshot = MobileFleetService.Snapshot(
            isDetected: true,
            lightDevices: [],
            richDevices: [],
            profiles: [],
            sourceFile: nil,
            snapshotDate: recent
        )
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceWithStaleSnapshotDate() {
        let stale = Date(timeIntervalSinceNow: -48 * 3600) // 48 hours ago
        let snapshot = MobileFleetService.Snapshot(
            isDetected: true,
            lightDevices: [],
            richDevices: [],
            profiles: [],
            sourceFile: nil,
            snapshotDate: stale
        )
        XCTAssertEqual(snapshot.cacheSource, .stale(at: stale))
    }

    // MARK: - Enrollment method + supervision (PR-3 surface)

    func testEnrollmentMethodLabelMapsKnownEnums() {
        XCTAssertEqual(
            MobileFleetService.Snapshot.enrollmentMethodLabel(for: "Institutional"),
            "ADE / Institutional"
        )
        XCTAssertEqual(
            MobileFleetService.Snapshot.enrollmentMethodLabel(for: "UserEnrollment"),
            "User Enrollment"
        )
        XCTAssertEqual(
            MobileFleetService.Snapshot.enrollmentMethodLabel(for: "AccountDrivenUserEnrollment"),
            "Account-Driven User Enrollment"
        )
        XCTAssertEqual(
            MobileFleetService.Snapshot.enrollmentMethodLabel(for: "AccountDrivenDeviceEnrollment"),
            "Account-Driven Device Enrollment"
        )
    }

    func testEnrollmentMethodLabelPassesUnknownValueThrough() {
        XCTAssertEqual(
            MobileFleetService.Snapshot.enrollmentMethodLabel(for: "SomeNewServerEnum"),
            "SomeNewServerEnum"
        )
    }

    func testEnrollmentMethodDistributionAndSupervisionCounts() throws {
        let inventoryJSON = """
        [
            {
                "mobileDeviceId": "1",
                "deviceType": "iPad",
                "general": {
                    "managed": true, "supervised": true,
                    "deviceOwnershipType": "Institutional"
                },
                "applications": [
                    {"identifier": "com.apple.x", "name": "X"},
                    {"identifier": "com.apple.y", "name": "Y"}
                ]
            },
            {
                "mobileDeviceId": "2",
                "deviceType": "iPad",
                "general": {
                    "managed": true, "supervised": false,
                    "deviceOwnershipType": "Institutional"
                }
            },
            {
                "mobileDeviceId": "3",
                "deviceType": "iPhone",
                "general": {
                    "managed": true, "supervised": true,
                    "deviceOwnershipType": "UserEnrollment"
                }
            },
            {
                "mobileDeviceId": "4",
                "deviceType": "iPhone",
                "general": {
                    "managed": false, "supervised": false,
                    "deviceOwnershipType": "AccountDrivenUserEnrollment"
                }
            }
        ]
        """
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-mobile-enrollment.json")
        try inventoryJSON.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let snapshot = MobileFleetService.load(
            listURL: nil,
            inventoryURL: tempURL,
            profilesURL: nil
        )

        XCTAssertEqual(snapshot.managedCount, 3)
        XCTAssertEqual(snapshot.unmanagedCount, 1)
        XCTAssertEqual(snapshot.supervisedCount, 2)

        let distribution = snapshot.enrollmentMethodDistribution
        // Sorted descending by count; Institutional has 2, the rest 1 each.
        XCTAssertEqual(distribution.first?.method, "ADE / Institutional")
        XCTAssertEqual(distribution.first?.count, 2)
        XCTAssertEqual(distribution.count, 3)

        let breakdown = snapshot.supervisionBreakdown
        let supervised = breakdown.first { $0.role == .supervised }?.count
        let unsupervised = breakdown.first { $0.role == .unsupervised }?.count
        let unmanaged = breakdown.first { $0.role == .unmanaged }?.count
        XCTAssertEqual(supervised, 2)
        XCTAssertEqual(unsupervised, 1)
        XCTAssertEqual(unmanaged, 1)

        let firstDevice = snapshot.richDevices[0]
        XCTAssertEqual(snapshot.managedAppCount(for: firstDevice), 2)
        let secondDevice = snapshot.richDevices[1]
        XCTAssertEqual(snapshot.managedAppCount(for: secondDevice), 0)
    }

    func testManagedAppCountReturnsZeroWhenApplicationsNull() throws {
        let inventoryJSON = """
        [
            {
                "mobileDeviceId": "1",
                "deviceType": "iPad",
                "general": {"managed": true, "supervised": true}
            }
        ]
        """
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-mobile-null-apps.json")
        try inventoryJSON.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let snapshot = MobileFleetService.load(
            listURL: nil,
            inventoryURL: tempURL,
            profilesURL: nil
        )
        let device = try XCTUnwrap(snapshot.richDevices.first)
        XCTAssertEqual(snapshot.managedAppCount(for: device), 0)
        XCTAssertNil(device.applications)
    }

    // MARK: - sourceDates (freshness chip row)

    func testSourceDatesPopulatedForPresentKinds() throws {
        let tmp = FileManager.default.temporaryDirectory
        let listURL = tmp.appendingPathComponent("sourcedates-mobile-list-\(UUID().uuidString).json")
        let inventoryURL = tmp.appendingPathComponent("sourcedates-mobile-inventory-\(UUID().uuidString).json")
        try "[]".write(to: listURL, atomically: true, encoding: .utf8)
        try "[]".write(to: inventoryURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: listURL)
            try? FileManager.default.removeItem(at: inventoryURL)
        }

        let snapshot = MobileFleetService.load(
            listURL: listURL, inventoryURL: inventoryURL, profilesURL: nil
        )

        XCTAssertNotNil(snapshot.sourceDates["mobile-devices-list"])
        XCTAssertNotNil(snapshot.sourceDates["mobile-device-inventory-details"])
        XCTAssertNil(snapshot.sourceDates["classic-ios-profiles"])
    }

    func testSourceDatesEmptyWhenAllURLsNil() {
        let snapshot = MobileFleetService.load(listURL: nil, inventoryURL: nil, profilesURL: nil)
        XCTAssertTrue(snapshot.sourceDates.isEmpty)
    }

    // MARK: - Form factor classification (iPad/iPhone bug)

    func testClassifyFormFactorPrefersModelIdentifier() {
        XCTAssertEqual(
            MobileFleetService.classifyFormFactor(
                model: "iPhone 5 (CDMA)", modelIdentifier: "iPhone5,2", deviceType: "iOS"),
            .iPhone)
        XCTAssertEqual(
            MobileFleetService.classifyFormFactor(
                model: "iPad Air", modelIdentifier: "iPad13,1", deviceType: "iOS"),
            .iPad)
        XCTAssertEqual(
            MobileFleetService.classifyFormFactor(
                model: "Apple TV 4K", modelIdentifier: "AppleTV5,3", deviceType: "tvOS"),
            .appleTV)
    }

    func testClassifyFormFactorDeviceTypeIsOnlyOSFamily() {
        // deviceType "iOS" alone carries no form factor → other.
        XCTAssertEqual(
            MobileFleetService.classifyFormFactor(
                model: nil, modelIdentifier: nil, deviceType: "iOS"),
            .other)
        // Legacy/list shapes that put the form factor in deviceType still classify.
        XCTAssertEqual(
            MobileFleetService.classifyFormFactor(
                model: nil, modelIdentifier: nil, deviceType: "iPad"),
            .iPad)
        XCTAssertEqual(
            MobileFleetService.classifyFormFactor(
                model: nil, modelIdentifier: nil, deviceType: "tvOS"),
            .appleTV)
    }

    /// The production/dummy shape: rich `mobile-device-inventory-details` arrives
    /// with `hardware: null` and `deviceType: "iOS"`, while the lighter
    /// `mobile-devices-list` carries `hardware.model`. Counts must classify from
    /// the populated source, not collapse to 0.
    func testCountsClassifyFromListWhenInventoryHardwareNull() throws {
        let inventoryJSON = """
        [
          {"mobileDeviceId":"1","deviceType":"iOS","hardware":null},
          {"mobileDeviceId":"2","deviceType":"iOS","hardware":null},
          {"mobileDeviceId":"3","deviceType":"iOS","hardware":null}
        ]
        """
        let listJSON = """
        [
          {"mobileDeviceId":"1","deviceType":"iOS",
           "hardware":{"model":"iPhone 5 (CDMA)","modelIdentifier":"iPhone5,2"}},
          {"mobileDeviceId":"2","deviceType":"iOS",
           "hardware":{"model":"iPad Air","modelIdentifier":"iPad13,1"}},
          {"mobileDeviceId":"3","deviceType":"tvOS",
           "hardware":{"model":"Apple TV 4K","modelIdentifier":"AppleTV5,3"}}
        ]
        """
        let tmp = FileManager.default.temporaryDirectory
        let listURL = tmp.appendingPathComponent("ff-list-\(UUID().uuidString).json")
        let inventoryURL = tmp.appendingPathComponent("ff-inv-\(UUID().uuidString).json")
        try listJSON.write(to: listURL, atomically: true, encoding: .utf8)
        try inventoryJSON.write(to: inventoryURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: listURL)
            try? FileManager.default.removeItem(at: inventoryURL)
        }

        let snapshot = MobileFleetService.load(
            listURL: listURL, inventoryURL: inventoryURL, profilesURL: nil)

        // total stays richDevices.count (inventory-details wins), but form factor
        // is read from the list, which carries the model data.
        XCTAssertEqual(snapshot.totalDevices, 3)
        XCTAssertEqual(snapshot.iPhoneCount, 1)
        XCTAssertEqual(snapshot.iPadCount, 1)
        XCTAssertEqual(snapshot.appleTVCount, 1)
    }

    /// When rich inventory-details DOES carry hardware, counts classify from it.
    func testCountsClassifyFromInventoryHardwareWhenPresent() throws {
        let inventoryJSON = """
        [
          {"mobileDeviceId":"1","deviceType":"iOS",
           "hardware":{"model":"iPhone 15","modelIdentifier":"iPhone16,1"}},
          {"mobileDeviceId":"2","deviceType":"iOS",
           "hardware":{"model":"iPad Pro","modelIdentifier":"iPad14,3"}}
        ]
        """
        let tmp = FileManager.default.temporaryDirectory
        let inventoryURL = tmp.appendingPathComponent("ff-inv2-\(UUID().uuidString).json")
        try inventoryJSON.write(to: inventoryURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: inventoryURL) }

        let snapshot = MobileFleetService.load(
            listURL: nil, inventoryURL: inventoryURL, profilesURL: nil)

        XCTAssertEqual(snapshot.totalDevices, 2)
        XCTAssertEqual(snapshot.iPhoneCount, 1)
        XCTAssertEqual(snapshot.iPadCount, 1)
        XCTAssertEqual(snapshot.appleTVCount, 0)
    }
}