import Foundation
import XCTest
@testable import JamfReports

// MARK: - ColumnFieldExpansionTests
//
// Verifies the Phase 6 addition to ColumnField (purchaseDate):
//   - YAML decode round-trip through ConfigLoader

final class ColumnFieldExpansionTests: XCTestCase {

    // MARK: - YAML round-trip

    func testPurchaseDateDecodesFromYAML() throws {
        let yaml = """
        columns:
          purchase_date: "Purchase Date"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(
            config.columns?.purchaseDate, "Purchase Date",
            "purchase_date YAML key must decode to ColumnConfig.purchaseDate"
        )
    }

    func testColumnNameForPurchaseDate() throws {
        var columns = ColumnConfig()
        columns.purchaseDate = "Purchase Date"
        XCTAssertEqual(columns.columnName(for: .purchaseDate), "Purchase Date")
    }

    func testColumnNameForPurchaseDateNilWhenUnset() {
        let columns = ColumnConfig()
        XCTAssertNil(columns.columnName(for: .purchaseDate))
    }

    // MARK: - ColumnField enum membership

    func testPurchaseDateCaseExists() {
        XCTAssertTrue(
            ColumnField.allCases.contains(.purchaseDate),
            "ColumnField must include .purchaseDate"
        )
    }
}
