import XCTest
@testable import JamfReports

final class BrandingAccentSwatchTests: XCTestCase {

    private func rgb(_ typed: String?) -> UInt32 {
        BrandingConfig(accentColor: typed).sanitizedAccentRGB
    }

    func testATypedSixDigitColourIsTheSwatch() {
        XCTAssertEqual(rgb("#C9970A"), 0xC9970A)
        XCTAssertEqual(rgb("#1a2b3c"), 0x1A2B3C)
        XCTAssertEqual(rgb("  #112233 "), 0x112233)
    }

    func testAThreeDigitColourIsSpreadToSix() {
        XCTAssertEqual(rgb("#abc"), 0xAABBCC)
        XCTAssertEqual(rgb("#F00"), 0xFF0000)
    }

    /// The reports fall back to #2D5EA2 for anything else, so the swatch shows that, not gold.
    func testAnythingElseIsTheReportsDefault() {
        for typed in [nil, "", "gold", "#12345", "#GGGGGG", "C9970A", "#12345678", "red; x"] {
            XCTAssertEqual(rgb(typed), 0x2D5EA2, "\(typed ?? "nil")")
            XCTAssertEqual(BrandingConfig(accentColor: typed).sanitizedAccentColor, "#2D5EA2")
        }
    }

    func testTheSwatchAgreesWithTheReportsColour() {
        for typed in ["#C9970A", "#abc", "nope", ""] {
            let config = BrandingConfig(accentColor: typed)
            let spread = String(config.sanitizedAccentColor.dropFirst())
            let expected = UInt32(spread.count == 3 ? spread.map { "\($0)\($0)" }.joined() : spread,
                                  radix: 16)
            XCTAssertEqual(config.sanitizedAccentRGB, expected, typed)
        }
    }
}
