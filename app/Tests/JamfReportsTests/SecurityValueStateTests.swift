import XCTest
@testable import JamfReports

/// The Devices table used to test positive words first, so a Mac with FileVault
/// off ("UNENCRYPTED", "Not Enabled") showed a green check.
final class SecurityValueStateTests: XCTestCase {

    func testNegativeFormsThatContainAPositiveWordAreBad() {
        let values = [
            "UNENCRYPTED", "NOT_ENCRYPTED", "Not Enabled", "NOT_ESCROWED", "Not Installed",
            "inactive", "DECRYPTING", "DISABLED", "false", "Off", "NONE",
        ]
        for value in values {
            XCTAssertEqual(SecurityValueState(value), .bad, value)
        }
    }

    func testPositiveFormsAreGood() {
        let values = [
            "ENCRYPTED", "ALL_ENCRYPTED", "Encrypted", "ENABLED", "true", "On", "ESCROWED",
            "APP_STORE_AND_IDENTIFIED_DEVELOPERS", "APP_STORE",
        ]
        for value in values {
            XCTAssertEqual(SecurityValueState(value), .good, value)
        }
    }

    /// A value Jamf did not collect is not a failed check.
    func testMissingOrUncollectedValuesAreUnknown() {
        let values = [
            "", "  ", "NOT_COLLECTED", "NOT_AVAILABLE", "NOT_SUPPORTED", "UNKNOWN", "ENCRYPTING",
        ]
        for value in values {
            XCTAssertEqual(SecurityValueState(value), .unknown, value)
        }
    }
}
