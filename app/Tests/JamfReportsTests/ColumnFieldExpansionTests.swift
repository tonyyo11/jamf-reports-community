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

    // MARK: - model_identifier

    /// `model` is the marketing name ("MacBook Pro (16-inch, 2019)"), `model_identifier` the
    /// hardware identifier ("MacBookPro16,1"); each reads its own key.
    func testModelIdentifierDecodesApartFromModel() throws {
        let yaml = """
        columns:
          model: "Model"
          model_identifier: "Model Identifier"
        """
        let columns = try XCTUnwrap(ConfigLoader.loadFromString(yaml).columns)
        XCTAssertEqual(columns.model, "Model")
        XCTAssertEqual(columns.modelIdentifier, "Model Identifier")
        XCTAssertEqual(columns.columnName(for: .model), "Model")
        XCTAssertEqual(columns.columnName(for: .modelIdentifier), "Model Identifier")
    }

    func testModelIdentifierIsUnmappedWhenTheKeyIsAbsentOrBlank() throws {
        let absent = try XCTUnwrap(
            ConfigLoader.loadFromString("columns:\n  model: \"Model\"\n").columns)
        XCTAssertNil(absent.columnName(for: .modelIdentifier))
        let blank = try XCTUnwrap(
            ConfigLoader.loadFromString("columns:\n  model_identifier: \"  \"\n").columns)
        XCTAssertNil(blank.columnName(for: .modelIdentifier))
    }

    func testModelIdentifierConfigKey() {
        XCTAssertEqual(ColumnField.modelIdentifier.configKey, "model_identifier")
        XCTAssertEqual(ColumnField.model.configKey, "model")
    }
}
