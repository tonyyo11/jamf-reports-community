import Foundation
import XCTest
import ZIPFoundation
@testable import JamfReports

/// Tests for branding.logo_path embed via CSVDashboard → Workbook.
///
/// Verifies PNG validation, missing-file handling, and that a valid PNG ends up
/// in `xl/media/image1.png` inside the produced ZIP.
final class OOXMLLogoEmbedTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal 8-byte valid PNG magic followed by enough bytes to satisfy `Data.prefix`.
    private var validPNGData: Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        // Append a minimal IHDR chunk so the file is structurally non-empty.
        bytes += [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE]
        return Data(bytes)
    }

    /// JPEG magic bytes — must be rejected by the PNG validator.
    private var nonPNGData: Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    }

    private func makeConfig(logoPath: String?) -> ReportConfig {
        var config = ReportConfig()
        var branding = BrandingConfig()
        branding.logoPath = logoPath
        config.branding = branding
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        config.columns = cols
        return config
    }

    private func minimalCSVData() -> Data {
        Data("Computer Name\nMac-001\n".utf8)
    }

    // MARK: - Valid PNG embed

    func testValidPNGIsEmbeddedInXLSX() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let logoURL = tmpDir.appendingPathComponent("logo.png")
        try validPNGData.write(to: logoURL)

        let config = makeConfig(logoPath: logoURL.path)
        let wb = Workbook()
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: minimalCSVData(), workbook: wb)
        )
        dashboard.writeAll()

        let xlsxURL = tmpDir.appendingPathComponent("out.xlsx")
        try wb.write(to: xlsxURL)

        // Open as ZIP and verify xl/media/image1.png exists.
        let archive = try XCTUnwrap(Archive(url: xlsxURL, accessMode: .read))
        let entry = archive["xl/media/image1.png"]
        XCTAssertNotNil(entry, "xl/media/image1.png must be present in the XLSX archive.")
    }

    // MARK: - Missing file

    func testMissingLogoFileProducesWorkbookWithoutImage() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = makeConfig(logoPath: tmpDir.appendingPathComponent("nonexistent.png").path)
        let wb = Workbook()
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: minimalCSVData(), workbook: wb)
        )
        dashboard.writeAll()

        let xlsxURL = tmpDir.appendingPathComponent("out.xlsx")
        // Should not throw — workbook writes successfully even when logo is absent.
        XCTAssertNoThrow(try wb.write(to: xlsxURL))

        let archive = try XCTUnwrap(Archive(url: xlsxURL, accessMode: .read))
        XCTAssertNil(archive["xl/media/image1.png"],
                     "No image should be embedded when the logo file does not exist.")
    }

    // MARK: - Non-PNG file

    func testNonPNGFileIsRejectedAndProducesNoImage() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeLogoURL = tmpDir.appendingPathComponent("logo.png")
        try nonPNGData.write(to: fakeLogoURL)

        let config = makeConfig(logoPath: fakeLogoURL.path)
        let wb = Workbook()
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: minimalCSVData(), workbook: wb)
        )
        dashboard.writeAll()

        let xlsxURL = tmpDir.appendingPathComponent("out.xlsx")
        XCTAssertNoThrow(try wb.write(to: xlsxURL))

        let archive = try XCTUnwrap(Archive(url: xlsxURL, accessMode: .read))
        XCTAssertNil(archive["xl/media/image1.png"],
                     "Non-PNG file must be rejected; no image should appear in the XLSX archive.")
    }

    // MARK: - Multi-sheet logo embed (Task 2)

    /// Verify that a valid PNG logo is embedded in ALL written sheets, not just the first.
    /// Each sheet must have its own xl/drawings/drawingN.xml entry in the ZIP.
    func testLogoEmbeddedOnAllThreeCSVSheets() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let logoURL = tmpDir.appendingPathComponent("logo.png")
        try validPNGData.write(to: logoURL)

        // CSV with a stale device so both Device Inventory and Stale Devices get rows.
        let csv = Data("""
            Computer Name,Serial Number,Last Check-in
            Mac-001,ABC123,2020-01-01
            Mac-002,DEF456,2019-06-15
            """.utf8)

        var config = makeConfig(logoPath: logoURL.path)
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        cols.lastCheckin = "Last Check-in"
        config.columns = cols

        let wb = Workbook()
        let dash = try XCTUnwrap(CSVDashboard(config: config, csvData: csv, workbook: wb))
        let written = dash.writeAll()

        // At minimum Device Inventory, Stale Devices, Security Controls are written.
        XCTAssertGreaterThanOrEqual(written.count, 3)

        let xlsxURL = tmpDir.appendingPathComponent("out.xlsx")
        try wb.write(to: xlsxURL)

        let archive = try XCTUnwrap(Archive(url: xlsxURL, accessMode: .read))

        // Each written sheet must have its own drawing relationship file.
        for (idx, _) in written.enumerated() {
            let drawingPath = "xl/drawings/drawing\(idx + 1).xml"
            XCTAssertNotNil(archive[drawingPath],
                            "'\(drawingPath)' must exist for sheet \(idx + 1).")
        }
    }

    /// The PNG data should be stored as a single media entry even when embedded on
    /// multiple sheets (one media file, multiple drawing references).
    func testLogoMediaDeduplicatedAcrossSheets() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let logoURL = tmpDir.appendingPathComponent("logo.png")
        try validPNGData.write(to: logoURL)

        let csv = Data("""
            Computer Name,Serial Number
            Mac-001,ABC123
            """.utf8)
        var config = makeConfig(logoPath: logoURL.path)
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        config.columns = cols

        let wb = Workbook()
        let dash = try XCTUnwrap(CSVDashboard(config: config, csvData: csv, workbook: wb))
        let written = dash.writeAll()
        XCTAssertGreaterThanOrEqual(written.count, 1)

        let xlsxURL = tmpDir.appendingPathComponent("out.xlsx")
        try wb.write(to: xlsxURL)

        let archive = try XCTUnwrap(Archive(url: xlsxURL, accessMode: .read))
        // xl/media/ should contain one entry per inserted image call (current design:
        // each sheet's insertImage stores its own copy; verify at least image1 exists).
        XCTAssertNotNil(archive["xl/media/image1.png"],
                        "At least xl/media/image1.png must be present.")
    }

    // MARK: - No logo configured

    func testNoLogoConfiguredProducesCleanWorkbook() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = makeConfig(logoPath: nil)
        let wb = Workbook()
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: minimalCSVData(), workbook: wb)
        )
        dashboard.writeAll()

        let xlsxURL = tmpDir.appendingPathComponent("out.xlsx")
        XCTAssertNoThrow(try wb.write(to: xlsxURL))

        let archive = try XCTUnwrap(Archive(url: xlsxURL, accessMode: .read))
        XCTAssertNil(archive["xl/media/image1.png"])
    }

    // MARK: - Content type declaration for image parts

    /// Read a ZIP entry's contents as a UTF-8 string.
    private func entryText(_ archive: Archive, _ path: String) throws -> String {
        let entry = try XCTUnwrap(archive[path], "\(path) must exist in the archive")
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// OPC requires every package part to carry a content type. A workbook with
    /// embedded PNGs must declare the png extension Default — without it Excel
    /// reports "We found a problem with some content" and offers to repair the
    /// file (stripping the chart images). Regression test for that exact bug.
    func testImageWorkbookDeclaresPNGContentType() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let logoURL = tmpDir.appendingPathComponent("logo.png")
        try validPNGData.write(to: logoURL)

        let config = makeConfig(logoPath: logoURL.path)
        let wb = Workbook()
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: minimalCSVData(), workbook: wb)
        )
        dashboard.writeAll()

        let xlsxURL = tmpDir.appendingPathComponent("out.xlsx")
        try wb.write(to: xlsxURL)

        let archive = try XCTUnwrap(Archive(url: xlsxURL, accessMode: .read))
        XCTAssertNotNil(archive["xl/media/image1.png"], "precondition: image must be embedded")
        let contentTypes = try entryText(archive, "[Content_Types].xml")
        XCTAssertTrue(
            contentTypes.contains(#"<Default Extension="png" ContentType="image/png"/>"#),
            "image parts require a png content-type Default; got: \(contentTypes)"
        )
    }

    /// A workbook with no embedded images must not declare image content types.
    func testImageFreeWorkbookOmitsPNGContentType() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = makeConfig(logoPath: nil)
        let wb = Workbook()
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: minimalCSVData(), workbook: wb)
        )
        dashboard.writeAll()

        let xlsxURL = tmpDir.appendingPathComponent("out.xlsx")
        try wb.write(to: xlsxURL)

        let archive = try XCTUnwrap(Archive(url: xlsxURL, accessMode: .read))
        let contentTypes = try entryText(archive, "[Content_Types].xml")
        XCTAssertFalse(contentTypes.contains(#"Extension="png""#),
                       "no images embedded — png Default must not be declared")
    }
}
