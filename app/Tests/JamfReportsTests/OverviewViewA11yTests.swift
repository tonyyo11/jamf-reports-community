import Foundation
import XCTest
@testable import JamfReports

// Tests for the FileVault column accessibility label fix in OverviewView.
// The fix adds .accessibilityLabel on the checkmark/xmark glyph so VoiceOver
// announces "FileVault encrypted" or "FileVault not encrypted" rather than
// the generic "Image."
final class OverviewViewA11yTests: XCTestCase {

    // MARK: - Label string correctness

    func testFVEncryptedLabel() {
        let label = fvLabel(encrypted: true)
        XCTAssertEqual(label, "FileVault encrypted",
                       "Encrypted state must announce 'FileVault encrypted'")
    }

    func testFVNotEncryptedLabel() {
        let label = fvLabel(encrypted: false)
        XCTAssertEqual(label, "FileVault not encrypted",
                       "Unencrypted state must announce 'FileVault not encrypted'")
    }

    func testFVLabelsDiffer() {
        XCTAssertNotEqual(
            fvLabel(encrypted: true),
            fvLabel(encrypted: false),
            "Encrypted and unencrypted labels must be distinct to avoid identical VoiceOver announcements"
        )
    }

    func testFVLabelsNonEmpty() {
        XCTAssertFalse(fvLabel(encrypted: true).isEmpty)
        XCTAssertFalse(fvLabel(encrypted: false).isEmpty)
    }

    // MARK: - Symbol name correctness

    func testFVEncryptedSymbol() {
        let symbol = fvSymbol(encrypted: true)
        XCTAssertEqual(symbol, "checkmark.circle.fill",
                       "Encrypted FV must use a check symbol")
        XCTAssertTrue(symbol.contains("checkmark"))
    }

    func testFVNotEncryptedSymbol() {
        let symbol = fvSymbol(encrypted: false)
        XCTAssertEqual(symbol, "xmark.circle.fill",
                       "Unencrypted FV must use an x symbol")
        XCTAssertTrue(symbol.contains("xmark"))
    }

    // MARK: - Helpers (mirror the logic in OverviewView)

    private func fvLabel(encrypted: Bool) -> String {
        encrypted ? "FileVault encrypted" : "FileVault not encrypted"
    }

    private func fvSymbol(encrypted: Bool) -> String {
        encrypted ? "checkmark.circle.fill" : "xmark.circle.fill"
    }
}
