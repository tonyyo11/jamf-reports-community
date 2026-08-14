import Foundation
import XCTest
@testable import JamfReports

// MARK: - ColumnFieldExpansionTests
//
// Verifies the Phase 6 addition to ColumnField (purchaseDate):
//   - YAML decode round-trip through ConfigLoader
//   - InventoryFieldMatcher scaffold semantic resolution
//   - Exclusion: "Purchase Order" must NOT resolve to purchase_date

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

    // MARK: - InventoryFieldMatcher scaffold heuristic

    func testMatcherResolvesPurchaseDate() {
        XCTAssertEqual(
            InventoryFieldMatcher.matchColumnKey("Acquired Date"),
            "purchase_date",
            "Column name 'Acquired Date' should resolve to purchase_date"
        )
    }

    func testMatcherResolvesPODate() {
        XCTAssertEqual(
            InventoryFieldMatcher.matchColumnKey("poDate"),
            "purchase_date"
        )
    }

    func testMatcherDoesNotResolvePurchaseOrderToPurchaseDate() {
        // "purchase_order" is a common Jamf field that must NOT map to purchase_date.
        // The matcher normalises to lowercase with spaces/underscores stripped, so
        // "Purchase Order" → "purchaseorder" which is absent from the map.
        let result = InventoryFieldMatcher.matchColumnKey("Purchase Order")
        XCTAssertNotEqual(
            result, "purchase_date",
            "Purchase Order must not resolve to purchase_date"
        )
    }
}
