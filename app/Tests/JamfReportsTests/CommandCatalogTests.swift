import XCTest
@testable import JamfReports

final class CommandCatalogTests: XCTestCase {

    private func fixture() throws -> CommandCatalog {
        let url = TestFixtures.dir("jamf-cli/commands-1.31.1.json")
        return try CommandCatalog(data: Data(contentsOf: url))
    }

    func testDecodesTheCapturedCatalog() throws {
        let catalog = try fixture()
        XCTAssertEqual(catalog.count, 1766)
        XCTAssertEqual(
            catalog.flags(for: ["pro", "backup"]),
            ["--concurrency", "--download-packages", "--format", "--include-ids", "--output",
             "--resources"])
        XCTAssertEqual(catalog.privileges(for: ["pro", "computer-inventory", "list"]),
                       ["Read Computers"])
        XCTAssertEqual(catalog.scopes(for: ["platform", "ai-policies", "list"]), ["environment"])
        XCTAssertEqual(catalog.product(for: ["protect", "overview"]), "protect")
        XCTAssertEqual(catalog.api(for: ["pro", "scripts", "list"]), "pro")
    }

    func testDestructiveAndPreviewRows() throws {
        let catalog = try fixture()
        XCTAssertTrue(catalog.isDestructive(path: ["pro", "accounts", "delete"]))
        XCTAssertFalse(catalog.isDestructive(path: ["pro", "backup"]))
        XCTAssertTrue(catalog.isPreview(path: ["platform", "ai-policies", "list"]))
        XCTAssertFalse(catalog.isPreview(path: ["pro", "backup"]))
    }

    func testMissingPathHasNoAnswer() throws {
        let catalog = try fixture()
        let missing = ["pro", "reprot", "security"]
        XCTAssertFalse(catalog.exists(path: missing))
        XCTAssertEqual(catalog.flags(for: missing), [])
        XCTAssertEqual(catalog.privileges(for: missing), [])
        XCTAssertNil(catalog.product(for: missing))
        XCTAssertFalse(catalog.isDestructive(path: missing))
    }

    func testAliasReachesTheCanonicalRowOnlyWhenUnambiguous() throws {
        let catalog = try fixture()
        let alias = ["pro", "computers", "list"]
        XCTAssertTrue(catalog.exists(path: alias))
        XCTAssertFalse(catalog.isCanonical(path: alias))
        XCTAssertEqual(catalog.flags(for: alias),
                       catalog.flags(for: ["pro", "computer-inventory", "list"]))
        XCTAssertTrue(catalog.isCanonical(path: ["pro", "computer-inventory", "list"]))
    }

    func testReadsLeniently() throws {
        let json = """
        [{"command": "pro thing", "flags": "--a, --b", "destructive": "yes", "extra": 1},
         {"command": "pro other", "flags": ["--c"], "privileges": ["Read Things"]},
         {"flags": "--orphan"}, 7]
        """
        let catalog = try CommandCatalog(data: Data(json.utf8))
        XCTAssertEqual(catalog.count, 2)
        XCTAssertEqual(catalog.flags(for: ["pro", "thing"]), ["--a", "--b"])
        XCTAssertFalse(catalog.isDestructive(path: ["pro", "thing"]))
        XCTAssertEqual(catalog.flags(for: ["pro", "other"]), ["--c"])
        XCTAssertEqual(catalog.privileges(for: ["pro", "other"]), ["Read Things"])
        XCTAssertThrowsError(try CommandCatalog(data: Data("{}".utf8))) {
            XCTAssertEqual($0 as? CommandCatalog.CatalogError, .notAnArray)
        }
    }

    func testCollectPrivilegesAreTheProRolePrivilegesTheMatrixNames() throws {
        let catalog = try fixture()
        let privileges = catalog.collectPrivileges()
        for expected in ["Read Computers", "Read Mobile Devices", "Read Scripts", "Read Sites"] {
            XCTAssertTrue(privileges.contains(expected), expected)
        }
        // The Platform API's permission is not an API role privilege.
        XCTAssertFalse(privileges.contains("compliance-benchmarks:read"))
        XCTAssertEqual(privileges, privileges.sorted())
    }

    func testBundledPrivilegesMatchTheCapturedCatalog() throws {
        XCTAssertEqual(CommandCatalog.bundledCollectPrivileges, try fixture().collectPrivileges())
    }

    func testNoCatalogIsReadWithoutAJamfCLI() {
        XCTAssertNil(CommandCatalog.installed())
        XCTAssertNil(CommandCatalog.installed(locate: { nil }))
    }
}
