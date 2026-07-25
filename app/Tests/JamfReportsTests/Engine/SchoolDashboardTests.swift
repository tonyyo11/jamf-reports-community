import Foundation
import XCTest
@testable import JamfReports

// MARK: - SchoolDashboardTests
// Tests for SchoolDashboard write* methods backed by committed fixtures.
// Tests that require specific fixtures skip when those fixtures are absent.

final class SchoolDashboardTests: XCTestCase {

    // MARK: - Helpers

    /// Tracks helper-created temp dirs for sweep in `tearDown`. Direct-callsite
    /// temp dirs still use local `defer` cleanup.
    private var createdTempDirs: [URL] = []

    override func tearDown() {
        for url in createdTempDirs {
            try? FileManager.default.removeItem(at: url)
        }
        createdTempDirs = []
        super.tearDown()
    }

    private var fixturesDir: URL { TestFixtures.root }

    private func tempDataDir(copying names: [String]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        createdTempDirs.append(tmp)
        let src = fixturesDir.appendingPathComponent("jamf-cli-data")
        for name in names {
            let from = src.appendingPathComponent(name, isDirectory: true)
            let to = tmp.appendingPathComponent(name, isDirectory: true)
            try? TestFixtures.copyDir(from, to: to)
        }
        return tmp
    }

    private func makeDashboard(dataDir: URL) -> SchoolDashboard {
        SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
    }

    // MARK: - iBeacons

    func testWriteSchoolIBeaconsHappyPath() throws {
        let dataDir = try tempDataDir(copying: ["school-ibeacons"])
        let fixtureDir = dataDir.appendingPathComponent("school-ibeacons")
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            throw XCTSkip("school-ibeacons fixture not available")
        }
        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeSchoolIBeacons())
    }

    func testWriteSchoolIBeaconsThrowsOnEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dash = makeDashboard(dataDir: tmp)
        XCTAssertThrowsError(try dash.writeSchoolIBeacons()) { error in
            guard case SchoolDashboardError.noCachedData = error else {
                XCTFail("Expected SchoolDashboardError.noCachedData, got \(error)")
                return
            }
        }
    }

    // MARK: - DEP Devices

    func testWriteSchoolDepDevicesHappyPath() throws {
        let dataDir = try tempDataDir(copying: ["school-dep-devices"])
        let fixtureDir = dataDir.appendingPathComponent("school-dep-devices")
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            throw XCTSkip("school-dep-devices fixture not available")
        }
        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeSchoolDepDevices())
    }

    func testWriteSchoolDepDevicesThrowsOnEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dash = makeDashboard(dataDir: tmp)
        XCTAssertThrowsError(try dash.writeSchoolDepDevices())
    }

    // MARK: - writeAll skips missing snapshots silently

    func testWriteAllReturnsEmptyOnNoData() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dash = makeDashboard(dataDir: tmp)
        let (written, failures) = dash.writeAll()
        XCTAssertTrue(written.isEmpty, "Expected no sheets written on empty dataDir")
        XCTAssertTrue(failures.isEmpty, "Expected no failures on empty dataDir — noCachedData is a skip")
    }

    func testWriteAllWritesIBeaconsAndDepDevicesWhenAvailable() throws {
        let dataDir = try tempDataDir(copying: ["school-ibeacons", "school-dep-devices"])
        let ibeaconsDir = dataDir.appendingPathComponent("school-ibeacons")
        let depDir = dataDir.appendingPathComponent("school-dep-devices")
        guard FileManager.default.fileExists(atPath: ibeaconsDir.path),
              FileManager.default.fileExists(atPath: depDir.path) else {
            throw XCTSkip("school fixture(s) not available")
        }
        let dash = makeDashboard(dataDir: dataDir)
        let (written, failures) = dash.writeAll()
        XCTAssertTrue(written.contains("iBeacons"), "Expected iBeacons sheet to be written")
        XCTAssertTrue(written.contains("DEP Devices"), "Expected DEP Devices sheet to be written")
        XCTAssertTrue(failures.isEmpty, "No unexpected failures expected for valid fixture data")
    }

    // MARK: - SchoolCSVDashboard nil-init on empty data

    func testSchoolCSVDashboardNilOnEmpty() {
        let result = SchoolCSVDashboard(
            config: ReportConfig(),
            csvData: Data(),
            workbook: Workbook()
        )
        XCTAssertNil(result)
    }

    func testSchoolCSVDashboardNonNilOnData() {
        let result = SchoolCSVDashboard(
            config: ReportConfig(),
            csvData: Data("name,serial\nfoo,bar".utf8),
            workbook: Workbook()
        )
        XCTAssertNotNil(result)
    }

    // MARK: - iBeacons fixture data validates expected columns

    func testIBeaconsFixtureDecodesExpectedFields() throws {
        let dataDir = try tempDataDir(copying: ["school-ibeacons"])
        let fixtureDir = dataDir.appendingPathComponent("school-ibeacons")
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            throw XCTSkip("school-ibeacons fixture not available")
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: fixtureDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" && $0.lastPathComponent.contains("happy") }
        guard let file = files.first else { throw XCTSkip("happy fixture not found") }
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let items = json as? [[String: Any]], !items.isEmpty else {
            throw XCTSkip("Empty iBeacons fixture")
        }
        let first = items[0]
        XCTAssertNotNil(first["name"], "iBeacon should have name field")
        XCTAssertNotNil(first["uuid"], "iBeacon should have uuid field")
    }

    // MARK: - DEP devices fixture validates expected columns

    func testDepDevicesFixtureDecodesExpectedFields() throws {
        let dataDir = try tempDataDir(copying: ["school-dep-devices"])
        let fixtureDir = dataDir.appendingPathComponent("school-dep-devices")
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            throw XCTSkip("school-dep-devices fixture not available")
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: fixtureDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" && $0.lastPathComponent.contains("happy") }
        guard let file = files.first else { throw XCTSkip("happy fixture not found") }
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let items = json as? [[String: Any]], !items.isEmpty else {
            throw XCTSkip("Empty DEP devices fixture")
        }
        let first = items[0]
        XCTAssertNotNil(first["serialNumber"] ?? first["serial"], "DEP device should have serial field")
        XCTAssertNotNil(first["model"], "DEP device should have model field")
    }
}
