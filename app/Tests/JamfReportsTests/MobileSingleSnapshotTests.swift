import XCTest
@testable import JamfReports

/// The Mobile Fleet screen reads one snapshot, `mobile-devices-list`, which collect fills with the
/// GENERAL, HARDWARE, SECURITY and USER_AND_LOCATION sections (#226 1). A
/// `mobile-device-inventory-details` snapshot left by an older collect is still read when it is
/// the newer of the two.
///
/// Shapes: `jamf-cli-data-mobile-sections` holds six devices in the Jamf Pro API v2
/// `/mobile-devices/detail` layout. The section layout on jamf-cli 1.18 was not verified.
/// `jamf-cli-data/mobile-devices-list` is the flat list older jamf-cli wrote, and
/// `jamf-cli-data/mobile-device-inventory-details` is the GENERAL-only inventory.
final class MobileSingleSnapshotTests: XCTestCase {

    private static let sectionsFile =
        "jamf-cli-data-mobile-sections/mobile-devices-list/"
        + "mobile-devices-list_2026-10-02T120000000000.json"
    private static let flatListFile = "jamf-cli-data/mobile-devices-list/mobile-devices-list.json"
    private static let legacyInventoryFile =
        "jamf-cli-data/mobile-device-inventory-details/mobile-device-inventory-details.json"

    /// A data dir holding each fixture under its kind, named with the given stamp.
    private func dataDir(_ files: [(kind: String, stamp: String, fixture: String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-mobile-single-\(UUID().uuidString)")
        for file in files {
            let kindDir = dir.appendingPathComponent(file.kind, isDirectory: true)
            try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
            try TestFixtures.copyFile(
                TestFixtures.dir(file.fixture),
                to: kindDir.appendingPathComponent("\(file.kind)_\(file.stamp).json"))
        }
        return dir
    }

    private let older = "2026-10-01T120000000000"
    private let newer = "2026-10-03T120000000000"
    private let sections = "2026-10-02T120000000000"

    // MARK: - One snapshot carries everything

    func testListSnapshotAloneFeedsTheInventoryReaders() throws {
        let dir = try dataDir([("mobile-devices-list", sections, Self.sectionsFile)])
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = MobileFleetService.load(dataDir: dir)

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.richDevices.count, 6)
        XCTAssertEqual(snapshot.totalDevices, 6)
        XCTAssertEqual(snapshot.passcodeCompliantCount, 4)
        XCTAssertEqual(snapshot.activationLockEnabledCount, 3)
        XCTAssertEqual(snapshot.jailbreakDetectedCount, 1)
        XCTAssertEqual(snapshot.iPhoneCount, 3)
        XCTAssertEqual(snapshot.iPadCount, 3)
        XCTAssertFalse(snapshot.reportsApplications, "APPLICATIONS is not requested")
        XCTAssertNil(snapshot.managedAppCount(for: try XCTUnwrap(snapshot.richDevices.first)))
        XCTAssertEqual(Set(snapshot.sourceDates.keys), ["mobile-devices-list"])
    }

    func testPerDeviceFieldsComeFromHardwareSecurityAndUserAndLocation() throws {
        let dir = try dataDir([("mobile-devices-list", sections, Self.sectionsFile)])
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = MobileFleetService.load(dataDir: dir)
        let first = try XCTUnwrap(snapshot.richDevices.first { $0.mobileDeviceId == "1" })
        let third = try XCTUnwrap(snapshot.richDevices.first { $0.mobileDeviceId == "3" })

        XCTAssertEqual(MobileFleetService.serialNumber(of: first, listRow: nil), "CA44FE1260A3")
        XCTAssertEqual(MobileFleetService.model(of: first, listRow: nil), "iPhone 5 (CDMA)")
        XCTAssertEqual(MobileFleetService.passcodeCompliant(of: first), true)
        XCTAssertEqual(MobileFleetService.activationLockEnabled(of: first), false)
        XCTAssertEqual(MobileFleetService.dataProtected(of: third), false)
        XCTAssertEqual(MobileFleetService.jailbreakStatus(of: first), "None")
        XCTAssertEqual(first.userAndLocation?.username, "user57")
        XCTAssertEqual(first.userAndLocation?.emailAddress, "user57@example.com")
        XCTAssertEqual(first.userAndLocation?.department, "Sales")
        XCTAssertEqual(first.userAndLocation?.building, "HQ")
    }

    /// A tenant with no mobile devices collects `[]`. That is a readable snapshot with zero
    /// devices, not "no data".
    func testEmptyListSnapshotReadsAsDetectedWithZeroDevices() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-mobile-single-\(UUID().uuidString)")
        let kindDir = dir.appendingPathComponent("mobile-devices-list", isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "[]".write(
            to: kindDir.appendingPathComponent("mobile-devices-list_\(sections).json"),
            atomically: true, encoding: .utf8)

        let snapshot = MobileFleetService.load(dataDir: dir)

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.totalDevices, 0)
        XCTAssertTrue(snapshot.richDevices.isEmpty)
        XCTAssertTrue(snapshot.lightDevices.isEmpty)
        XCTAssertNotNil(snapshot.sourceDates["mobile-devices-list"])
    }

    // MARK: - An older collect's inventory-details snapshot

    func testLegacyInventoryAloneStaysReadable() throws {
        let dir = try dataDir([
            ("mobile-device-inventory-details", older, Self.legacyInventoryFile),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = MobileFleetService.load(dataDir: dir)

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.richDevices.count, 105)
        XCTAssertNil(snapshot.passcodeCompliantCount, "GENERAL only: posture was never measured")
    }

    func testNewestOfTheTwoKindsWinsByFilenameStamp() throws {
        let listNewer = try dataDir([
            ("mobile-device-inventory-details", older, Self.legacyInventoryFile),
            ("mobile-devices-list", sections, Self.sectionsFile),
        ])
        let inventoryNewer = try dataDir([
            ("mobile-devices-list", sections, Self.sectionsFile),
            ("mobile-device-inventory-details", newer, Self.legacyInventoryFile),
        ])
        defer {
            try? FileManager.default.removeItem(at: listNewer)
            try? FileManager.default.removeItem(at: inventoryNewer)
        }

        XCTAssertEqual(MobileFleetService.load(dataDir: listNewer).richDevices.count, 6)
        XCTAssertEqual(MobileFleetService.load(dataDir: inventoryNewer).richDevices.count, 105)
    }

    // MARK: - The flat list older jamf-cli wrote

    /// The flat list has no inventory sections; reading it as inventory would count every
    /// device as one that reports nothing, and hide the older snapshot that has real rows.
    func testFlatListNewerThanLegacyInventoryDoesNotHideIt() throws {
        let dir = try dataDir([
            ("mobile-device-inventory-details", older, Self.legacyInventoryFile),
            ("mobile-devices-list", newer, Self.flatListFile),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = MobileFleetService.load(dataDir: dir)

        XCTAssertEqual(snapshot.richDevices.count, 105)
        XCTAssertEqual(snapshot.lightDevices.count, 105)
        XCTAssertEqual(snapshot.managedCount, 103)
    }

    func testFlatListAloneIsNotInventory() throws {
        let dir = try dataDir([("mobile-devices-list", newer, Self.flatListFile)])
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = MobileFleetService.load(dataDir: dir)

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertTrue(snapshot.richDevices.isEmpty)
        XCTAssertEqual(snapshot.lightDevices.count, 105)
        XCTAssertEqual(snapshot.totalDevices, 105)
        XCTAssertNil(snapshot.passcodeCompliantCount)
    }
}
