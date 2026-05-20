import Foundation
import XCTest
@testable import JamfReports

// MARK: - ColumnFieldExpansionTests
//
// Verifies the Phase 6 additions to ColumnField (warrantyExpires, purchaseDate):
//   - YAML decode round-trip through ConfigLoader
//   - InventoryFieldMatcher scaffold semantic resolution
//   - Exclusion: "Purchase Order" must NOT resolve to purchase_date

final class ColumnFieldExpansionTests: XCTestCase {

    // MARK: - YAML round-trip

    func testWarrantyExpiresDecodesFromYAML() throws {
        let yaml = """
        columns:
          warranty_expires: "Hardware Warranty"
          purchase_date: "Purchase Date"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(
            config.columns?.warrantyExpires, "Hardware Warranty",
            "warranty_expires YAML key must decode to ColumnConfig.warrantyExpires"
        )
    }

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

    func testColumnNameForWarrantyExpires() throws {
        var columns = ColumnConfig()
        columns.warrantyExpires = "Hardware Warranty"
        XCTAssertEqual(columns.columnName(for: .warrantyExpires), "Hardware Warranty")
    }

    func testColumnNameForPurchaseDate() throws {
        var columns = ColumnConfig()
        columns.purchaseDate = "Purchase Date"
        XCTAssertEqual(columns.columnName(for: .purchaseDate), "Purchase Date")
    }

    func testColumnNameForWarrantyExpiresNilWhenUnset() {
        let columns = ColumnConfig()
        XCTAssertNil(columns.columnName(for: .warrantyExpires))
    }

    func testColumnNameForPurchaseDateNilWhenUnset() {
        let columns = ColumnConfig()
        XCTAssertNil(columns.columnName(for: .purchaseDate))
    }

    // MARK: - ColumnField enum membership

    func testWarrantyExpiresCaseExists() {
        XCTAssertTrue(
            ColumnField.allCases.contains(.warrantyExpires),
            "ColumnField must include .warrantyExpires"
        )
    }

    func testPurchaseDateCaseExists() {
        XCTAssertTrue(
            ColumnField.allCases.contains(.purchaseDate),
            "ColumnField must include .purchaseDate"
        )
    }

    // MARK: - InventoryFieldMatcher scaffold heuristic

    func testMatcherResolvesWarrantyExpires() {
        // "warrantyExpires" is a realistic camelCase key from jamf-cli device JSON.
        XCTAssertEqual(
            InventoryFieldMatcher.matchColumnKey("warrantyExpires"),
            "warranty_expires",
            "camelCase warrantyExpires should resolve to warranty_expires"
        )
    }

    func testMatcherResolvesWarrantyExpiresSnakeCase() {
        XCTAssertEqual(
            InventoryFieldMatcher.matchColumnKey("warranty_expires"),
            "warranty_expires"
        )
    }

    func testMatcherResolvesWarrantyEnd() {
        XCTAssertEqual(
            InventoryFieldMatcher.matchColumnKey("warrantyEnd"),
            "warranty_expires"
        )
    }

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
