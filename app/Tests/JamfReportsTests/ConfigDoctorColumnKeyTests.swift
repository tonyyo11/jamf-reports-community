import Foundation
import XCTest
@testable import JamfReports

/// The Config Doctor names each `columns:` mapping by its config.yaml key, the decoder's own
/// `CodingKeys` raw value, so its row titles and header suggestions use the key the user typed.
final class ConfigDoctorColumnKeyTests: XCTestCase {

    private func columnRows(_ yaml: String, headers: [String]) throws -> [DoctorRow] {
        ConfigDoctorService.evaluate(
            config: try ConfigLoader.loadFromString(yaml), parseError: nil,
            csvHeaders: headers, csvFamily: .computers, eaCoverageNames: []
        ).filter { $0.id.hasPrefix("columns.") && !$0.id.contains(".duplicate.") }
    }

    func testEveryColumnRowIsTitledWithTheKeyTheDecoderReads() throws {
        let keys = ColumnConfig.CodingKeys.allCases.map(\.rawValue)
        let yaml = "columns:\n" + keys.map { "  \($0): \"Header \($0)\"" }.joined(separator: "\n")
        let found = try columnRows(yaml, headers: keys.map { "Header \($0)" })
        XCTAssertEqual(found.map(\.title).sorted(), keys.sorted())
        XCTAssertEqual(Set(found.map(\.id)), Set(keys.map { "columns.\($0)" }))
    }

    func testEntraSSOStatusGetsTheHeaderSuggestionItsKeyHas() throws {
        let found = try columnRows(
            "columns:\n  entra_sso_status: \"Notes\"\n",
            headers: ["Computer Name", "Notes", "Entra SSO Status"])
        let row = try XCTUnwrap(found.first { $0.title == "entra_sso_status" })
        XCTAssertEqual(row.severity, .suggest)
        XCTAssertEqual(row.detail,
                       "Mapped to 'Notes', but 'Entra SSO Status' looks like a stronger match.")
    }
}
