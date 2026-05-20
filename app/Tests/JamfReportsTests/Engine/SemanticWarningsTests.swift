import XCTest
@testable import JamfReports

final class SemanticWarningsTests: XCTestCase {

    // MARK: - Check 1: manager column

    func testManagerColumnPointsToManagementState() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.manager = "Management Status"
        let warnings = SemanticWarnings.check(config: config, sampleRows: [])
        XCTAssertTrue(
            warnings.contains(where: { $0.contains("management-state column") }),
            "Expected management-state column warning, got: \(warnings)"
        )
    }

    func testManagerColumnSampleValuesLookLikeManagementStatus() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.manager = "Manager EA"
        let rows: [CSVRow] = [
            ["Manager EA": "Managed"],
            ["Manager EA": "Unmanaged"],
            ["Manager EA": "Managed"],
        ]
        let warnings = SemanticWarnings.check(config: config, sampleRows: rows)
        XCTAssertTrue(
            warnings.contains(where: { $0.contains("management status") }),
            "Expected management status warning, got: \(warnings)"
        )
    }

    func testManagerColumnWithRealManagerValues() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.manager = "Manager"
        let rows: [CSVRow] = [
            ["Manager": "CN=DOE JOHN,OU=Staff"],
            ["Manager": "CN=SMITH JANE,OU=Staff"],
        ]
        let warnings = SemanticWarnings.check(config: config, sampleRows: rows)
        XCTAssertFalse(
            warnings.contains(where: { $0.contains("management") }),
            "Should not warn for real manager values"
        )
    }

    func testManagerColumnNotConfigured() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        // manager is nil — should produce no warning
        let warnings = SemanticWarnings.check(config: config, sampleRows: [])
        XCTAssertFalse(warnings.contains(where: { $0.contains("manager") }))
    }

    // MARK: - Check 2: disk_percent_full

    func testDiskPercentFullPointsToAvailableMB() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.diskPercentFull = "Available MB"
        let warnings = SemanticWarnings.check(config: config, sampleRows: [])
        XCTAssertTrue(
            warnings.contains(where: { $0.contains("percentage-used column") }),
            "Expected percentage-used column warning"
        )
    }

    func testDiskPercentFullPointsToCapacityMB() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.diskPercentFull = "Drive Capacity MB"
        let warnings = SemanticWarnings.check(config: config, sampleRows: [])
        XCTAssertTrue(warnings.contains(where: { $0.contains("percentage-used column") }))
    }

    func testDiskPercentFullCorrectColumn() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.diskPercentFull = "Disk Used Percent"
        let warnings = SemanticWarnings.check(config: config, sampleRows: [])
        XCTAssertFalse(warnings.contains(where: { $0.contains("percentage-used column") }))
    }

    // MARK: - Check 3: secure_boot

    func testSecureBootPointsToExternalBoot() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.secureBoot = "External Boot Level"
        let warnings = SemanticWarnings.check(config: config, sampleRows: [])
        XCTAssertTrue(
            warnings.contains(where: { $0.contains("External Boot Level") }),
            "Expected External Boot Level warning"
        )
    }

    func testSecureBootCorrectColumn() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.secureBoot = "Secure Boot Level"
        let warnings = SemanticWarnings.check(config: config, sampleRows: [])
        XCTAssertFalse(warnings.contains(where: { $0.contains("External Boot Level") }))
    }

    // MARK: - Check 4: bootstrap_token

    func testBootstrapTokenPointsToAllowed() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.bootstrapToken = "Bootstrap Token Allowed"
        let warnings = SemanticWarnings.check(config: config, sampleRows: [])
        XCTAssertTrue(
            warnings.contains(where: { $0.contains("Bootstrap Token Allowed") }),
            "Expected Bootstrap Token Allowed warning"
        )
    }

    func testBootstrapTokenEscrowed() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.bootstrapToken = "Bootstrap Token Escrowed"
        let warnings = SemanticWarnings.check(config: config, sampleRows: [])
        XCTAssertFalse(warnings.contains(where: { $0.contains("Bootstrap Token Allowed") }))
    }

    // MARK: - Check 5: future dates

    func testLastCheckinFarFutureDate() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.lastCheckin = "Last Check-in"
        let rows: [CSVRow] = [["Last Check-in": "2099-01-01"]]
        let warnings = SemanticWarnings.check(config: config, sampleRows: rows)
        XCTAssertTrue(
            warnings.contains(where: { $0.contains("20 years in the future") }),
            "Expected future-date warning"
        )
    }

    func testLastCheckinNearFutureNoWarning() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.lastCheckin = "Last Check-in"
        // 10 years in the future — under 20-year limit, should not warn
        let futureDate = Calendar.current.date(byAdding: .year, value: 10, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let rows: [CSVRow] = [["Last Check-in": formatter.string(from: futureDate)]]
        let warnings = SemanticWarnings.check(config: config, sampleRows: rows)
        XCTAssertFalse(warnings.contains(where: { $0.contains("20 years in the future") }))
    }

    // MARK: - All columns correct

    func testAllColumnsCorrectProducesNoWarnings() {
        var config = ReportConfig()
        config.columns = ColumnConfig()
        config.columns?.manager = "Manager Name"
        config.columns?.diskPercentFull = "Disk Usage %"
        config.columns?.secureBoot = "Secure Boot Level"
        config.columns?.bootstrapToken = "Bootstrap Token Escrowed"
        config.columns?.lastCheckin = "Last Check-in"
        let rows: [CSVRow] = [["Last Check-in": "2024-01-01", "Manager Name": "CN=DOE JOHN,OU=Staff"]]
        let warnings = SemanticWarnings.check(config: config, sampleRows: rows)
        XCTAssertEqual(warnings, [], "Expected no warnings for correctly configured columns")
    }
}
