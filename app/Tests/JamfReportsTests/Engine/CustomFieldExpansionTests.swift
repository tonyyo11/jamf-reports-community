import Foundation
import XCTest
@testable import JamfReports

/// Tests for the 8 new optional logical fields: full_name, asset_tag, building,
/// position, last_logged_in_user, recovery_lock, battery_health, entra_sso_status.
///
/// Verifies YAML round-trip, Device Inventory / Stale Devices column presence when
/// mapped, omission when unmapped, and scaffold hint detection.
final class CustomFieldExpansionTests: XCTestCase {

    // MARK: - Helpers

    private func makeConfig(
        mapping: [ColumnField: String] = [:]
    ) -> ReportConfig {
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        cols.lastCheckin = "Last Check-in"
        cols.department = "Department"
        cols.model = "Model"
        cols.email = "Email"
        for (field, colName) in mapping {
            switch field {
            case .fullName:         cols.fullName = colName
            case .assetTag:         cols.assetTag = colName
            case .building:         cols.building = colName
            case .position:         cols.position = colName
            case .lastLoggedInUser: cols.lastLoggedInUser = colName
            case .recoveryLock:     cols.recoveryLock = colName
            case .batteryHealth:    cols.batteryHealth = colName
            case .entraSSOStatus:   cols.entraSSOStatus = colName
            default: break
            }
        }
        config.columns = cols
        return config
    }

    private func makeCSV(extraHeaders: [String] = [], extraValues: [String] = []) -> Data {
        let header = (["Computer Name", "Serial Number", "Last Check-in", "Department",
                       "Model", "Email"] + extraHeaders).joined(separator: ",")
        let row = (["Mac-001", "ABC123", "2020-01-01", "IT", "MacBook Pro", "user@example.com"]
                    + extraValues).joined(separator: ",")
        return Data("\(header)\n\(row)\n".utf8)
    }

    private func sheetContent(name: String, config: ReportConfig, csv: Data) throws -> String {
        let wb = Workbook()
        let dash = try XCTUnwrap(CSVDashboard(config: config, csvData: csv, workbook: wb))
        dash.writeAll()
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try wb.write(to: tmpURL)
        let data = try Data(contentsOf: tmpURL)
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - ColumnConfig YAML round-trip

    func testFullNameDecodesFromYAML() throws {
        let yaml = "columns:\n  full_name: \"Full Name\"\n"
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.columns?.fullName, "Full Name")
    }

    func testAssetTagDecodesFromYAML() throws {
        let yaml = "columns:\n  asset_tag: \"Asset Tag\"\n"
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.columns?.assetTag, "Asset Tag")
    }

    func testBuildingDecodesFromYAML() throws {
        let yaml = "columns:\n  building: \"Building\"\n"
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.columns?.building, "Building")
    }

    func testPositionDecodesFromYAML() throws {
        let yaml = "columns:\n  position: \"Job Title\"\n"
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.columns?.position, "Job Title")
    }

    func testLastLoggedInUserDecodesFromYAML() throws {
        let yaml = "columns:\n  last_logged_in_user: \"Last Logged In User\"\n"
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.columns?.lastLoggedInUser, "Last Logged In User")
    }

    func testRecoveryLockDecodesFromYAML() throws {
        let yaml = "columns:\n  recovery_lock: \"Recovery Lock\"\n"
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.columns?.recoveryLock, "Recovery Lock")
    }

    func testBatteryHealthDecodesFromYAML() throws {
        let yaml = "columns:\n  battery_health: \"Battery Health\"\n"
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.columns?.batteryHealth, "Battery Health")
    }

    func testEntraSSOStatusDecodesFromYAML() throws {
        let yaml = "columns:\n  entra_sso_status: \"Entra SSO\"\n"
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.columns?.entraSSOStatus, "Entra SSO")
    }

    // MARK: - ColumnField enum coverage

    func testColumnNameForNewFields() {
        var cols = ColumnConfig()
        cols.fullName = "Full Name"
        cols.assetTag = "Asset Tag"
        cols.building = "Building"
        cols.position = "Position"
        cols.lastLoggedInUser = "Last Logged In"
        cols.recoveryLock = "Recovery Lock"
        cols.batteryHealth = "Battery Health"
        cols.entraSSOStatus = "Entra SSO Status"

        XCTAssertEqual(cols.columnName(for: .fullName), "Full Name")
        XCTAssertEqual(cols.columnName(for: .assetTag), "Asset Tag")
        XCTAssertEqual(cols.columnName(for: .building), "Building")
        XCTAssertEqual(cols.columnName(for: .position), "Position")
        XCTAssertEqual(cols.columnName(for: .lastLoggedInUser), "Last Logged In")
        XCTAssertEqual(cols.columnName(for: .recoveryLock), "Recovery Lock")
        XCTAssertEqual(cols.columnName(for: .batteryHealth), "Battery Health")
        XCTAssertEqual(cols.columnName(for: .entraSSOStatus), "Entra SSO Status")
    }

    func testUnmappedNewFieldsReturnNil() {
        let cols = ColumnConfig()
        XCTAssertNil(cols.columnName(for: .fullName))
        XCTAssertNil(cols.columnName(for: .assetTag))
        XCTAssertNil(cols.columnName(for: .building))
        XCTAssertNil(cols.columnName(for: .position))
        XCTAssertNil(cols.columnName(for: .lastLoggedInUser))
        XCTAssertNil(cols.columnName(for: .recoveryLock))
        XCTAssertNil(cols.columnName(for: .batteryHealth))
        XCTAssertNil(cols.columnName(for: .entraSSOStatus))
    }

    // MARK: - Device Inventory sheet — mapped fields appear

    func testDeviceInventoryContainsMappedFullName() throws {
        let config = makeConfig(mapping: [.fullName: "Full Name"])
        let csv = makeCSV(extraHeaders: ["Full Name"], extraValues: ["John Smith"])
        let content = try sheetContent(name: "Device Inventory", config: config, csv: csv)
        XCTAssertTrue(content.contains("Full Name"),
                      "Full Name header must appear when field is mapped.")
        XCTAssertTrue(content.contains("John Smith"),
                      "Full Name cell value must appear when field is mapped.")
    }

    func testDeviceInventoryContainsMappedAssetTag() throws {
        let config = makeConfig(mapping: [.assetTag: "Asset Tag"])
        let csv = makeCSV(extraHeaders: ["Asset Tag"], extraValues: ["TAG-001"])
        let content = try sheetContent(name: "Device Inventory", config: config, csv: csv)
        XCTAssertTrue(content.contains("Asset Tag"))
        XCTAssertTrue(content.contains("TAG-001"))
    }

    func testDeviceInventoryContainsMappedBuilding() throws {
        let config = makeConfig(mapping: [.building: "Building"])
        let csv = makeCSV(extraHeaders: ["Building"], extraValues: ["HQ"])
        let content = try sheetContent(name: "Device Inventory", config: config, csv: csv)
        XCTAssertTrue(content.contains("Building"))
        XCTAssertTrue(content.contains("HQ"))
    }

    // MARK: - Device Inventory sheet — unmapped fields omitted

    func testDeviceInventoryOmitsUnmappedFullName() throws {
        let config = makeConfig()   // no new fields mapped
        let csv = makeCSV()
        let content = try sheetContent(name: "Device Inventory", config: config, csv: csv)
        XCTAssertFalse(content.contains("Full Name"),
                       "Full Name column must not appear when field is not mapped.")
    }

    func testDeviceInventoryOmitsUnmappedPosition() throws {
        let config = makeConfig()
        let csv = makeCSV()
        let content = try sheetContent(name: "Device Inventory", config: config, csv: csv)
        XCTAssertFalse(content.contains("Position"))
    }

    // MARK: - Stale Devices sheet — mapped fields appear

    func testStaleDevicesContainsMappedAssetTag() throws {
        let config = makeConfig(mapping: [.assetTag: "Asset Tag"])
        // Use a stale last check-in so the device lands in Stale Devices.
        let csv = Data("""
            Computer Name,Serial Number,Last Check-in,Department,Model,Email,Asset Tag
            Mac-001,ABC123,2020-01-01,IT,MacBook Pro,u@e.com,ASSET-XYZ
            """.utf8)
        let content = try sheetContent(name: "Stale Devices", config: config, csv: csv)
        XCTAssertTrue(content.contains("Asset Tag"))
        XCTAssertTrue(content.contains("ASSET-XYZ"))
    }

    func testStaleDevicesOmitsUnmappedBatteryHealth() throws {
        let config = makeConfig()
        let csv = makeCSV()
        let content = try sheetContent(name: "Stale Devices", config: config, csv: csv)
        XCTAssertFalse(content.contains("Battery Health"))
    }

    // MARK: - Scaffold hints

    func testScaffoldDetectsFullNameVariants() throws {
        for header in ["Full Name", "User Full Name", "FullName"] {
            let result = ReportEngine.testableScaffoldMappings(from: [header])
            XCTAssertEqual(result["full_name"], header,
                           "full_name hint must match header '\(header)'")
        }
    }

    func testScaffoldDetectsAssetTagVariants() throws {
        for header in ["Asset Tag", "AssetTag", "Asset ID"] {
            let result = ReportEngine.testableScaffoldMappings(from: [header])
            XCTAssertEqual(result["asset_tag"], header,
                           "asset_tag hint must match header '\(header)'")
        }
    }

    func testScaffoldDetectsBuildingVariants() throws {
        for header in ["Building", "Site Building"] {
            let result = ReportEngine.testableScaffoldMappings(from: [header])
            XCTAssertEqual(result["building"], header,
                           "building hint must match header '\(header)'")
        }
    }

    func testScaffoldDetectsPositionVariants() throws {
        for header in ["Position", "Job Title"] {
            let result = ReportEngine.testableScaffoldMappings(from: [header])
            XCTAssertEqual(result["position"], header,
                           "position hint must match header '\(header)'")
        }
    }

    func testScaffoldDetectsLastLoggedInUserVariants() throws {
        for header in ["Last Logged In", "Last User", "Logged In User"] {
            let result = ReportEngine.testableScaffoldMappings(from: [header])
            XCTAssertEqual(result["last_logged_in_user"], header,
                           "last_logged_in_user hint must match header '\(header)'")
        }
    }

    func testScaffoldDetectsRecoveryLockVariants() throws {
        for header in ["Recovery Lock", "RecoveryLock", "Recovery Lock Enabled"] {
            let result = ReportEngine.testableScaffoldMappings(from: [header])
            XCTAssertEqual(result["recovery_lock"], header,
                           "recovery_lock hint must match header '\(header)'")
        }
    }

    func testScaffoldDetectsBatteryHealthVariants() throws {
        for header in ["Battery Health", "Battery Condition", "Battery Cycle Count"] {
            let result = ReportEngine.testableScaffoldMappings(from: [header])
            XCTAssertEqual(result["battery_health"], header,
                           "battery_health hint must match header '\(header)'")
        }
    }

    func testScaffoldDetectsEntraSSOStatusVariants() throws {
        for header in ["Entra SSO", "Azure AD Status", "Entra ID SSO"] {
            let result = ReportEngine.testableScaffoldMappings(from: [header])
            XCTAssertEqual(result["entra_sso_status"], header,
                           "entra_sso_status hint must match header '\(header)'")
        }
    }
}
