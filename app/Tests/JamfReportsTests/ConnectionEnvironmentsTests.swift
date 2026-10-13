import XCTest
@testable import JamfReports

final class ConnectionEnvironmentsTests: XCTestCase {

    private func connection(members: [(String, String)] = []) -> Connection {
        Connection(
            name: "Acme Platform", region: .us, level: .environment,
            members: members.map { .init(profile: $0.0, scopeID: $0.1, product: .pro) })
    }

    // MARK: Slugs and names

    func testSlugKeepsLowercaseLettersAndDigitsJoinedByHyphens() {
        XCTAssertEqual(ConnectionEnvironments.slug("Acme  Platform!"), "acme-platform")
        XCTAssertEqual(ConnectionEnvironments.slug("  --Prod / EU 2--"), "prod-eu-2")
        XCTAssertEqual(ConnectionEnvironments.slug("Zürich"), "z-rich")
        XCTAssertEqual(ConnectionEnvironments.slug("%%%"), "")
    }

    func testSlugIsCapped() {
        let slug = ConnectionEnvironments.slug(String(repeating: "a", count: 200))
        XCTAssertEqual(slug.count, ConnectionEnvironments.maxSlugLength)
    }

    func testProfileNameIsConnectionDashLabel() {
        XCTAssertEqual(
            ConnectionEnvironments.profileName(connection: "Acme Platform", label: "Production"),
            "acme-platform-production")
        XCTAssertEqual(
            ConnectionEnvironments.profileName(connection: "???", label: "???"),
            "connection-environment")
    }

    // MARK: Parsing

    func testParseReadsIDsWithOptionalLabels() {
        let text = "env-1 Production\n\n# a comment\nenv-2\n  env-3,Sandbox EU  \n"
        XCTAssertEqual(ConnectionEnvironments.parse(text, firstNumber: 3), [
            .init(scopeID: "env-1", label: "Production"),
            .init(scopeID: "env-2", label: "Environment 4"),
            .init(scopeID: "env-3", label: "Sandbox EU"),
        ])
    }

    func testParseOfNothingIsEmpty() {
        XCTAssertTrue(ConnectionEnvironments.parse("  \n\n# only a comment").isEmpty)
    }

    // MARK: Refusals

    func testAProfileThatExistsIsRefused() {
        let planned = ConnectionEnvironments.plan(
            entries: [.init(scopeID: "env-1", label: "Production")], connection: connection(),
            existingProfiles: ["acme-platform-production"])
        XCTAssertEqual(planned[0].refusal, .profileExists("acme-platform-production"))
    }

    func testALeftoverProfileMayBeRegisteredAgain() {
        let planned = ConnectionEnvironments.plan(
            entries: [.init(scopeID: "env-1", label: "Production")], connection: connection(),
            existingProfiles: ["acme-platform-production"],
            canReRegister: { $0 == "acme-platform-production" })
        XCTAssertNil(planned[0].refusal)
        XCTAssertTrue(planned[0].reRegisters)
        XCTAssertTrue(planned[0].previewText.contains("registered again"))
    }

    func testAReRegisteredNameStillRefusesADifferentCaseVariant() {
        let planned = ConnectionEnvironments.plan(
            entries: [.init(scopeID: "env-1", label: "Production")], connection: connection(),
            existingProfiles: ["acme-platform-production", "Acme-Platform-Production"],
            canReRegister: { _ in true })
        XCTAssertEqual(planned[0].refusal, .caseVariant(of: "Acme-Platform-Production"))
    }

    func testACaseVariantOfAProfileIsRefused() {
        let planned = ConnectionEnvironments.plan(
            entries: [.init(scopeID: "env-1", label: "Production")], connection: connection(),
            existingProfiles: ["Acme-Platform-Production"])
        XCTAssertEqual(planned[0].refusal, .caseVariant(of: "Acme-Platform-Production"))
    }

    func testACaseVariantOfAWorkspaceIsRefused() {
        let planned = ConnectionEnvironments.plan(
            entries: [.init(scopeID: "env-1", label: "Production")], connection: connection(),
            existingProfiles: [], workspaceConflict: { _ in "ACME-PLATFORM-PRODUCTION" })
        XCTAssertEqual(planned[0].refusal, .caseVariant(of: "ACME-PLATFORM-PRODUCTION"))
    }

    func testTwoLabelsThatMakeOneNameKeepOnlyTheFirst() {
        let planned = ConnectionEnvironments.plan(
            entries: [
                .init(scopeID: "env-1", label: "Prod"), .init(scopeID: "env-2", label: "PROD!"),
            ], connection: connection(), existingProfiles: [])
        XCTAssertNil(planned[0].refusal)
        XCTAssertEqual(planned[1].refusal, .duplicateName)
    }

    func testAnIDInTheConnectionOrListedTwiceIsRefused() {
        let planned = ConnectionEnvironments.plan(
            entries: [
                .init(scopeID: "env-1", label: "A"), .init(scopeID: "env-1", label: "B"),
                .init(scopeID: "env-9", label: "C"),
            ],
            connection: connection(members: [("acme-platform-c", "env-9")]), existingProfiles: [])
        XCTAssertNil(planned[0].refusal)
        XCTAssertEqual(planned[1].refusal, .duplicateID)
        XCTAssertEqual(planned[2].refusal, .alreadyInConnection(profile: "acme-platform-c"))
    }

    func testAnIDThatCouldReadAsAFlagIsRefused() {
        XCTAssertFalse(ConnectionEnvironments.isUsableID("--tenant-id"))
        XCTAssertFalse(ConnectionEnvironments.isUsableID("a b"))
        XCTAssertFalse(ConnectionEnvironments.isUsableID("é"))
        XCTAssertTrue(ConnectionEnvironments.isUsableID("7c1e5a90-3b2d_4f68.x"))
    }
}
