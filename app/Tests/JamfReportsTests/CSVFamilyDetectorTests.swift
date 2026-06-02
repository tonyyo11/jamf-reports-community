import Foundation
import XCTest
@testable import JamfReports

/// Tests for CSVFamilyDetector — discriminator tables, normalize(), and detect().
final class CSVFamilyDetectorTests: XCTestCase {

    // MARK: - normalize()

    func test_normalize_lowercases() {
        XCTAssertEqual(CSVFamilyDetector.normalize("Computer Name"), "computer name")
    }

    func test_normalize_collapseWhitespace() {
        XCTAssertEqual(CSVFamilyDetector.normalize("Last  Check-in"), "last check-in")
    }

    func test_normalize_stripsLeadingTrailingWhitespace() {
        XCTAssertEqual(CSVFamilyDetector.normalize("  Gatekeeper  "), "gatekeeper")
    }

    func test_normalize_stripsUTF8BOM() {
        // Jamf exports include a UTF-8 BOM on the first header.
        XCTAssertEqual(CSVFamilyDetector.normalize("\u{FEFF}Computer Name"), "computer name")
    }

    func test_normalize_preservesHyphens() {
        // Hyphens are required for discriminators like "last check-in" and "wi-fi mac address".
        XCTAssertEqual(CSVFamilyDetector.normalize("Wi-Fi MAC Address"), "wi-fi mac address")
    }

    // MARK: - detect() — unambiguous cases

    func test_detect_computerHeaders_returnsComputers() {
        // Full 11.28 built-in computer header row (from tests/fixtures/csv/jamf1128_computers_builtin.csv).
        let headers = [
            "\u{FEFF}Computer Name", "Activation Lock Manageable", "Apple Silicon", "Asset Tag",
            "Bar Code", "Bluetooth Low Energy Capability", "Computer Azure Active Directory ID",
            "Conditional Access Inventory State", "Declarative Device Management Enabled",
            "Enrolled via Automated Device Enrollment", "Firewall Enabled", "IP Address",
            "iTunes Store Account", "JAMF Binary Version", "JSS Computer ID", "Last Check-in",
            "Last Enrollment", "Last iCloud Backup", "Last Inventory Update",
            "Managed", "Managed By", "MDM Capability", "Platform", "Supervised",
            "Processor Type", "Serial Number", "Operating System Version",
            "Gatekeeper", "System Integrity Protection", "Secure Boot Level",
            "FileVault 2 Status", "Boot Drive Percentage Full",
        ]
        XCTAssertEqual(CSVFamilyDetector.detect(headers: headers), .computers)
    }

    func test_detect_mobileHeaders_returnsMobile() {
        // Full mobile device header row (from tests/fixtures/csv/jamf1128_mobile_builtin.csv).
        let headers = [
            "Display Name", "AirPlay Password", "App Analytics Enabled", "Asset Tag",
            "Available Space MB", "Battery Health", "Battery Level",
            "Bluetooth Low Energy Capability", "Bluetooth MAC Address", "Capacity MB",
            "Device ID", "Device Locator Service Enabled", "Device Ownership Type",
            "JSS Mobile Device ID", "Jailbreak Detected", "Lost Mode Enabled",
            "Managed", "Model", "OS Version", "Passcode Status", "Serial Number",
            "Shared iPad", "Supervised", "UDID", "Wi-Fi MAC Address", "IMEI", "ICCID",
        ]
        XCTAssertEqual(CSVFamilyDetector.detect(headers: headers), .mobile)
    }

    // MARK: - THE BUG: computer headers with Managed + Supervised must not detect as mobile

    func test_detect_computerHeadersWithManagedAndSupervised_returnsComputers() {
        // Jamf Pro 11.28 computer exports now include Managed and Supervised columns.
        // These also appear in mobile exports but are NOT discriminators — only family-exclusive
        // headers are discriminators. This must resolve to .computers, not .mobile.
        let headers = [
            "Computer Name", "Apple Silicon", "Firewall Enabled", "JSS Computer ID",
            "Last Check-in", "Gatekeeper", "System Integrity Protection", "FileVault 2 Status",
            "Secure Boot Level", "Processor Type", "Boot Drive Percentage Full",
            "Operating System Version", "Managed", "Supervised",
        ]
        XCTAssertEqual(CSVFamilyDetector.detect(headers: headers), .computers)
    }

    // MARK: - detect() — edge cases

    func test_detect_noDiscriminatorHeaders_returnsNil() {
        let headers = ["Asset Tag", "Serial Number", "Model", "Email Address"]
        XCTAssertNil(CSVFamilyDetector.detect(headers: headers))
    }

    func test_detect_emptyHeaders_returnsNil() {
        XCTAssertNil(CSVFamilyDetector.detect(headers: []))
    }

    func test_detect_tieReturnsNil() {
        // One computer discriminator + one mobile discriminator = tie → nil.
        let headers = ["Computer Name", "Display Name"]
        XCTAssertNil(CSVFamilyDetector.detect(headers: headers))
    }

    func test_detect_caseInsensitive() {
        // Discriminator comparison must be case-insensitive.
        XCTAssertEqual(
            CSVFamilyDetector.detect(headers: ["COMPUTER NAME", "JSS COMPUTER ID",
                                               "GATEKEEPER", "FIREWALL ENABLED"]),
            .computers
        )
    }

    func test_detect_bomOnFirstHeader() {
        // Jamf exports have a BOM prefix on the very first column name.
        XCTAssertEqual(
            CSVFamilyDetector.detect(headers: ["\u{FEFF}Computer Name", "JSS Computer ID",
                                               "Gatekeeper", "Firewall Enabled"]),
            .computers
        )
    }

    // MARK: - Discriminator family exclusivity

    func test_computerDiscriminators_notInMobileFixtureHeaders() {
        // None of the computer discriminators should appear in real mobile export headers.
        let mobileHeaders = Set([
            "display name", "app analytics enabled", "asset tag", "available space mb",
            "battery health", "battery level", "bluetooth low energy capability",
            "bluetooth mac address", "capacity mb", "date lost mode enabled",
            "declarative device management enabled", "device id",
            "device locator service enabled", "device ownership type",
            "device phone number", "diagnostic and usage reporting enabled",
            "do not disturb enabled", "enrollment session token valid", "exchange device id",
            "icloud backup enabled", "ip address", "itunes store account",
            "jamf parent pairings", "jss mobile device id", "languages", "last backup",
            "last enrollment", "last icloud backup", "last inventory update",
            "user last logged in - self service", "locales",
            "location services for self service mobile", "lost mode enabled",
            "managed", "mdm profile expiration date", "model", "model identifier",
            "model number", "modem firmware version", "os build",
            "os rapid security response", "os supplemental build version", "os version",
            "paired devices", "preferred voice number", "quota size", "resident users",
            "serial number", "shared ipad", "supervised", "tethered", "time zone",
            "udid", "used space percentage", "wi-fi mac address",
            "building", "department", "email address", "full name", "position",
            "room", "user phone number", "username",
            "appleare id", "lease expiration", "life expectancy", "po date",
            "po number", "purchase price", "purchased or leased", "purchasing account",
            "purchasing contact", "vendor", "warranty expiration",
            "activation lock enabled", "attestation status", "block encryption capability",
            "bootstrap token escrowed", "data protection", "file encryption capability",
            "hardware encryption", "jailbreak detected", "last attestation attempt",
            "last successful attestation", "passcode compliance",
            "passcode compliance with profile(s)",
            "passcode lock grace period enforced (seconds)", "passcode status",
            "carrier settings version", "cellular technology", "current carrier network",
            "current mobile country code", "current mobile network code",
            "data roaming enabled", "eid", "home carrier network",
            "home mobile country code", "home mobile network code", "iccid",
            "imei", "imei2", "meid", "personal hotspot enabled", "roaming",
            "voice roaming enabled",
        ])
        for disc in CSVFamilyDetector.computerDiscriminators {
            XCTAssertFalse(mobileHeaders.contains(disc),
                           "Computer discriminator '\(disc)' must not appear in mobile headers")
        }
    }
}
