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
        XCTAssertEqual(catalog.privilegesListed(for: ["pro", "computer-inventory", "list"]),
                       ["Read Computers"])
        XCTAssertEqual(catalog.scopes(for: ["platform", "ai-policies", "list"]), ["environment"])
        XCTAssertEqual(catalog.product(for: ["protect", "overview"]), "protect")
        XCTAssertEqual(catalog.api(for: ["pro", "scripts", "list"]), "pro")
    }

    func testDestructiveAndPreviewRows() throws {
        let catalog = try fixture()
        XCTAssertEqual(catalog.isDestructive(path: ["pro", "accounts", "delete"]), true)
        XCTAssertEqual(catalog.isDestructive(path: ["pro", "backup"]), false)
        XCTAssertTrue(catalog.isPreview(path: ["platform", "ai-policies", "list"]))
        XCTAssertFalse(catalog.isPreview(path: ["pro", "backup"]))
    }

    func testMissingPathHasNoAnswer() throws {
        let catalog = try fixture()
        let missing = ["pro", "reprot", "security"]
        XCTAssertFalse(catalog.exists(path: missing))
        XCTAssertEqual(catalog.flags(for: missing), [])
        XCTAssertNil(catalog.privilegesListed(for: missing))
        XCTAssertNil(catalog.scopes(for: missing))
        XCTAssertNil(catalog.product(for: missing))
        XCTAssertNil(catalog.isDestructive(path: missing))
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
        // A destructive flag that is not a boolean is unknown, never safe.
        XCTAssertNil(catalog.isDestructive(path: ["pro", "thing"]))
        XCTAssertNil(catalog.privilegesListed(for: ["pro", "thing"]))
        XCTAssertEqual(catalog.flags(for: ["pro", "other"]), ["--c"])
        XCTAssertEqual(catalog.privilegesListed(for: ["pro", "other"]), ["Read Things"])
        XCTAssertThrowsError(try CommandCatalog(data: Data("{}".utf8))) { error in
            guard case .notAnArray(let reason)? = error as? CommandCatalog.CatalogError else {
                return XCTFail("\(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testReportAndClassicRowsListNoPrivileges() throws {
        let catalog = try fixture()
        XCTAssertNil(catalog.privilegesListed(for: ["pro", "report", "patch-status"]))
        XCTAssertNil(catalog.privilegesListed(for: ["pro", "classic-policies", "list"]))
        XCTAssertNotNil(catalog.privilegesListed(for: ["pro", "scripts", "list"]))
    }

    func testProPrivilegesNameWhatTheCatalogListsAndWhatItDoesNot() throws {
        let catalog = try fixture()
        let union = catalog.proPrivileges(forArguments: CommandCatalog.collectArguments())
        for expected in ["Read Computers", "Read Mobile Devices", "Read Scripts", "Read Sites"] {
            XCTAssertTrue(union.listed.contains(expected), expected)
        }
        // The Platform API's permission is not an API role privilege.
        XCTAssertFalse(union.listed.contains("compliance-benchmarks:read"))
        XCTAssertTrue(union.unlisted.contains("pro report patch-status"))
        XCTAssertTrue(union.unlisted.contains("pro classic-policies list"))
        XCTAssertEqual(union.missing, [], "a command the app runs is not in the catalog")
        let renamed = catalog.proPrivileges(forArguments: [(["pro", "reprot", "security"], 0)])
        XCTAssertEqual(renamed.missing, ["pro reprot security"])
    }

    /// The commands the catalog lists no privileges for and `supplementalPrivileges` does not
    /// cover on purpose (see its doc comment).
    private static let unmappedUnlisted: Set<String> = [
        "pro overview", "pro report compliance-devices", "pro report compliance-rules",
        "pro report ddm-status", "pro report blueprint-status",
    ]

    func testEverySupplementedCommandIsStillUnlistedAndEveryOtherUnlistedOneIsKnown() throws {
        let catalog = try fixture()
        let union = catalog.proPrivileges(forArguments: CommandCatalog.collectArguments())
        for path in CommandCatalog.supplementalPrivileges.keys {
            XCTAssertTrue(union.unlisted.contains(path), "\(path) now lists its own privileges")
        }
        XCTAssertEqual(
            Set(union.unlisted).subtracting(CommandCatalog.supplementalPrivileges.keys),
            Self.unmappedUnlisted)
    }

    func testCollectPrivilegesLabelEachNameBySource() throws {
        let privileges = try fixture().collectPrivileges()
        let source = Dictionary(uniqueKeysWithValues: privileges.map { ($0.name, $0.source) })
        XCTAssertEqual(privileges.count, source.count, "a name appears twice")
        XCTAssertEqual(source["Read Computers"], .jamfCLI)
        XCTAssertEqual(source["Read Scripts"], .jamfCLI)
        XCTAssertEqual(source["Read Policies"], .jamfReports)
        XCTAssertEqual(source["Read Smart Computer Groups"], .jamfCLI)
        XCTAssertEqual(source["Read Static Computer Groups"], .jamfReports)
        XCTAssertEqual(source["Read Managed Software Updates"], .jamfReports)
        XCTAssertEqual(source["Read iOS Configuration Profiles"], .jamfReports)
        XCTAssertEqual(source["Read Mobile Device Applications"], .jamfReports)
        XCTAssertEqual(source["Read Patch Policies"], .jamfReports)
        XCTAssertNil(source["compliance-benchmarks:read"])
        XCTAssertEqual(privileges.map(\.name), privileges.map(\.name).sorted())
    }

    func testBundledPrivilegesMatchTheCapturedCatalog() throws {
        XCTAssertEqual(CommandCatalog.bundledCollectPrivileges, try fixture().collectPrivileges())
    }

    func testMergeKeepsJamfCLIAsTheSourceOfANameBothHave() {
        let merged = CommandCatalog.Privilege.merged(
            listed: ["Read A"], supplemental: ["Read A", "Read B"])
        XCTAssertEqual(merged, [.init(name: "Read A", source: .jamfCLI),
                                .init(name: "Read B", source: .jamfReports)])
    }

    func testNoCatalogIsReadWithoutAJamfCLI() {
        XCTAssertNil(CommandCatalog.installed())
        XCTAssertNil(CommandCatalog.installed(locate: { nil }))
    }
}
