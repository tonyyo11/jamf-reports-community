import XCTest
@testable import JamfReports

final class ManagerParserTests: XCTestCase {

    func testNilInput() {
        XCTAssertEqual(ManagerParser.parse(nil), "")
    }

    func testEmptyString() {
        XCTAssertEqual(ManagerParser.parse(""), "")
    }

    func testWhitespaceOnly() {
        XCTAssertEqual(ManagerParser.parse("  "), "")
    }

    func testNaNString() {
        XCTAssertEqual(ManagerParser.parse("nan"), "")
        XCTAssertEqual(ManagerParser.parse("NaN"), "")
        XCTAssertEqual(ManagerParser.parse("NAN"), "")
    }

    func testEscapedCommaInCN() {
        // CN=SMITH\, JOHN,OU=Users,DC=example,DC=com → "Smith, John"
        let input = "CN=SMITH\\, JOHN,OU=Users,DC=example,DC=com"
        XCTAssertEqual(ManagerParser.parse(input), "Smith, John")
    }

    func testSimpleCN() {
        // CN=DOE JANE,OU=Staff,DC=corp,DC=com → "Doe Jane"
        let input = "CN=DOE JANE,OU=Staff,DC=corp,DC=com"
        XCTAssertEqual(ManagerParser.parse(input), "Doe Jane")
    }

    func testApostropheInCN() {
        // CN=O'BRIEN SEAN,OU=Ops — Swift .capitalized gives "O'brien Sean"
        let input = "CN=O'BRIEN SEAN,OU=Ops"
        XCTAssertEqual(ManagerParser.parse(input), "O'brien Sean")
    }

    func testPlainNamePassthrough() {
        XCTAssertEqual(ManagerParser.parse("Alice Johnson"), "Alice Johnson")
    }

    func testDNWithoutCNPassthrough() {
        let input = "OU=Users,DC=example,DC=com"
        XCTAssertEqual(ManagerParser.parse(input), "OU=Users,DC=example,DC=com")
    }

    func testCaseInsensitiveCNPrefix() {
        // Lowercase 'cn=' should also match
        let input = "cn=SMITH JOHN,OU=Users"
        XCTAssertEqual(ManagerParser.parse(input), "Smith John")
    }

    func testLeadingTrailingWhitespaceStripped() {
        let input = "  CN=DOE JOHN,OU=Staff  "
        XCTAssertEqual(ManagerParser.parse(input), "Doe John")
    }

    func testSingleWordCN() {
        let input = "CN=ADMIN,OU=Admins,DC=corp"
        XCTAssertEqual(ManagerParser.parse(input), "Admin")
    }
}
