import XCTest
@testable import JamfReports

/// Phone numbers in shared text and JSON are masked (#283). Numbers are made up.
final class PhoneRedactionTests: XCTestCase {

    func testPhoneFormatsAreMasked() {
        let r = DiagnosticRedactor()
        for phone in ["+14155550123", "(415) 555-0123", "415.555.0123", "415-555-0123"] {
            let out = r.redactText("[warn] contact \(phone) failed")
            XCTAssertFalse(withoutPlaceholders(out).contains("555"), "\(phone) -> \(out)")
            XCTAssertTrue(out.contains("phone-"), "\(phone) -> \(out)")
        }
    }

    func testSpacedInternationalNumbersAreMasked() {
        let r = DiagnosticRedactor()
        let samples = [
            ("+44 20 7946 0958", "7946"), ("+1 (415) 555 0132", "555"),
            ("+49 30 123456", "123456"), ("+1-415-555-0132", "555"), ("+44.20.7946.0958", "7946"),
            ("+4930-123456", "123456"), ("+3531 234 5678", "5678"),
            ("+44 20 7946 0958x", "0958"),
        ]
        for (phone, digits) in samples {
            let out = r.redactText("[warn] contact \(phone) failed")
            XCTAssertFalse(withoutPlaceholders(out).contains(digits), "\(phone) -> \(out)")
            XCTAssertTrue(out.contains("phone-") && out.hasSuffix(" failed"), "\(phone) -> \(out)")
        }
    }

    func testNonPhoneTextIsUntouched() {
        let r = DiagnosticRedactor()
        let samples = [
            "2026-10-18", "2026-10-18 07:44:00", "10:30:00.123", "v1.31.1", "build 1.2.3.4.5", "A3F1C2D4-1B2C-4D5E-8F90-123456789ABC",
            "2020-2026", "released +2020-2026", "at 10:30 +0530",
            "Mac 25 06 2026", "1.29.0 and +1.29.0",
        ]
        for sample in samples {
            XCTAssertEqual(r.redactText(sample), sample, sample)
        }
    }

    /// The IPv4 and serial rules, not the phone rules, take these (as before).
    func testIPAndBareDigitIDsAreNotPhones() {
        let r = DiagnosticRedactor()
        XCTAssertTrue(r.redactText("10.0.0.1").hasPrefix("ip-"))
        let id = r.redactText("id 4155550123")
        XCTAssertTrue(id.contains("serial-") && !id.contains("phone-"), id)
    }

    func testSerialIsStillHandledBySerialRule() {
        let out = DiagnosticRedactor().redactText("serial C02XK1BJG5HP")
        XCTAssertTrue(out.contains("serial-"), out)
        XCTAssertFalse(out.contains("C02XK1BJG5HP"), out)
    }

    func testPhoneJSONKeysUsePhonePlaceholder() {
        let r = DiagnosticRedactor()
        for key in ["mobile_phone", "telephone", "phoneNumber", "phone"] {
            guard let out = r.redactJSON([key: "415-555-0123"]) as? [String: Any]
            else { return XCTFail("not a dict") }
            XCTAssertTrue((out[key] as? String ?? "").hasPrefix("phone-"), key)
        }
    }

    func testPhoneIsMaskedEvenWhenUsernamesAreKept() {
        let out = DiagnosticRedactor(redactUsernames: false).redactText("call 415-555-0123")
        XCTAssertFalse(withoutPlaceholders(out).contains("555"), out)
    }

    /// The placeholder's random hex can itself contain "555".
    private func withoutPlaceholders(_ text: String) -> String {
        text.replacingOccurrences(of: "phone-[0-9a-f]+", with: "", options: .regularExpression)
    }

    func testPolicyListsPhones() {
        XCTAssertEqual(DiagnosticRedactor().policy()["phones"] as? Bool, true)
    }

    func testSharedTextMasksPhoneButDisplayTierDoesNot() {
        let line = "[error] cannot reach +14155550123"
        let shared = LogRedactor.redactedForSharing(
            line, profile: nil, scopeIDs: { _ in [] }, serverHosts: { _ in [] })
        XCTAssertFalse(shared.contains("4155550123"), shared)
        XCTAssertEqual(LogRedactor.redact(line), line)
    }
}
