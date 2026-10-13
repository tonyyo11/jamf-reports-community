import Foundation
import XCTest
@testable import JamfReports

/// `config list -o json` does not say which Jamf product a jamf-cli profile logs in to, so the
/// app derives it: the file's `product:` key, then the auth method, then the host. A Protect or
/// Security Cloud login is never a Jamf Pro workspace; a Jamf School login is a School one.
@MainActor
final class ProfileProductTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-product-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Derivation order

    private func product(
        _ key: String? = nil, auth: String? = nil, url: String? = nil, read: Bool = true
    ) -> JamfCLIProduct {
        ProfileService.derivedProduct(
            configProduct: key, authMethod: auth, url: url, configFileRead: read)
    }

    func testTheFilesProductKeyOutranksTheAuthMethodAndTheHost() {
        XCTAssertEqual(
            product("protect", auth: "oauth2", url: "https://a.jamfcloud.com"), .protect)
        XCTAssertEqual(product("school", auth: "oauth2"), .school)
        XCTAssertEqual(product("security", auth: "oauth2"), .securityCloud)
        XCTAssertEqual(product("pro", auth: "apikey", url: "https://x.jamfschool.com"), .pro)
        XCTAssertEqual(product(" Protect "), .protect, "trimmed and case-insensitive")
    }

    func testAKeyThisBuildDoesNotKnowIsUnknownNotPro() {
        XCTAssertEqual(product("radar", auth: "oauth2"), .unknown)
    }

    func testTheAuthMethodDecidesWhenThereIsNoKey() {
        XCTAssertEqual(product(auth: "apikey"), .school)
        XCTAssertEqual(product(auth: "security"), .securityCloud)
        XCTAssertEqual(product(auth: "platform", url: "https://x.protect.jamfcloud.com"), .pro,
                       "the auth method is consulted before the host")
    }

    /// jamf-cli matches auth methods exactly (`config validate`), so a mis-cased value says
    /// nothing about the product and the next rule decides (2.10, `JamfCLIAuthMethod`).
    func testAMiscasedAuthMethodSaysNothing() {
        XCTAssertNotEqual(product(auth: "APIKEY"), .school)
        XCTAssertEqual(product(auth: "APIKEY", url: "https://acme.jamfschool.com"), .school)
    }

    func testTheHostDecidesAnOAuth2ProfileWithNoKey() {
        XCTAssertEqual(
            product(auth: "oauth2", url: "https://acme.protect.jamfcloud.com"), .protect)
        XCTAssertEqual(product(auth: "oauth2", url: "https://acme.jamfschool.com"), .school)
        XCTAssertEqual(product(auth: "oauth2", url: "https://acme.jamfcloud.com"), .pro)
    }

    func testNothingSayingIsProOnlyWhenTheFileWasRead() {
        XCTAssertEqual(product(auth: "token", read: true), .pro)
        XCTAssertEqual(product(auth: "token", read: false), .unknown)
    }

    // MARK: - Config file

    func testParsesFourAndTwoSpaceFilesAndSkipsNestedKeysAndSecrets() {
        let four = """
        default-profile: prod
        profiles:
            prod:
                url: https://acme.jamfcloud.com
                auth-method: oauth2
                client-secret: literal-secret-value
            protect:
                product: protect
                url: https://acme.protect.jamfcloud.com
                auth-method: oauth2
                extra:
                    product: pro
        """
        let two = four.replacingOccurrences(of: "    ", with: "  ")
        for text in [four, two] {
            let parsed = ProfileService.parseConfigFile(text)
            XCTAssertEqual(parsed.map(\.name), ["prod", "protect"])
            XCTAssertEqual(parsed[0].isDefault, true)
            XCTAssertNil(parsed[0].product)
            XCTAssertEqual(
                parsed[1].product, "protect", "a nested product key is not the profile's")
            XCTAssertEqual(parsed[1].authMethod, "oauth2")
        }
    }

    func testPlatformScopeLevelFromTheFile() {
        let text = """
        profiles:
            env:
                auth-method: platform
                environment-id: abc
            ten:
                auth-method: platform
                tenant-id: def
            org:
                auth-method: platform
            pro:
                auth-method: oauth2
        """
        let levels = ProfileService.parseConfigFile(text).map(\.platformLevel)
        XCTAssertEqual(levels, [.environment, .tenant, .organization, nil])
    }

    func testReadingTheConfigFileIsBounded() throws {
        let big = root.appendingPathComponent("big.yaml")
        try Data(repeating: 0x20, count: ProfileService.maxConfigFileBytes + 1).write(to: big)
        XCTAssertNil(ProfileService.readConfigFile(at: big))
        XCTAssertNil(ProfileService.readConfigFile(at: root), "a directory is not read")
        XCTAssertNil(ProfileService.readConfigFile(at: nil))
    }

    // MARK: - Discovery

    private func stub(_ json: String) throws -> URL {
        let url = root.appendingPathComponent("list-stub-\(UUID().uuidString.prefix(6))")
        let script = "#!/bin/sh\ncat <<'EOF'\n\(json)\nEOF\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func configFile(_ text: String) throws -> URL {
        let url = root.appendingPathComponent("config-\(UUID().uuidString.prefix(6)).yaml")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testDiscoveryTakesTheProductKeyFromTheFileBecauseConfigListHasNone() throws {
        let list = try stub("""
        [{"name":"prod","url":"https://a.jamfcloud.com","auth-method":"oauth2","default":true},
         {"name":"prot","url":"https://a.jamfcloud.com","auth-method":"oauth2"},
         {"name":"sch","url":"https://a.jamfschool.com","auth-method":"apikey"},
         {"name":"sec","auth-method":"security"}]
        """)
        let file = try configFile("""
        profiles:
            prod:
                url: https://a.jamfcloud.com
            prot:
                product: protect
        """)
        let found = ProfileService.discoverJamfCLIProfiles(
            scheduleCounts: [:], _testBinaryOverride: list, _testConfigURL: file)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0.product) })
        XCTAssertEqual(byName, [
            "prod": .pro, "prot": .protect, "sch": .school, "sec": .securityCloud,
        ])
    }

    func testDiscoveryWithNoReadableFileLeavesAnOAuth2ProfileUnknown() throws {
        let list = try stub(
            #"[{"name":"p","url":"https://a.jamfcloud.com","auth-method":"oauth2"}]"#)
        let found = ProfileService.discoverJamfCLIProfiles(
            scheduleCounts: [:], _testBinaryOverride: list,
            _testConfigURL: root.appendingPathComponent("absent.yaml"))
        XCTAssertEqual(found.map(\.product), [.unknown])
    }

    func testDiscoveryReadsThePlatformLevelAndConfirmsOrganizationAgainstTheFile() throws {
        let list = try stub("""
        [{"name":"env","auth-method":"platform","environment-id":"e1"},
         {"name":"ten","auth-method":"platform","tenant-id":"t1"},
         {"name":"org","auth-method":"platform"},
         {"name":"quiet","auth-method":"platform"}]
        """)
        let file = try configFile("""
        profiles:
            org:
                auth-method: platform
            quiet:
                auth-method: platform
                environment-id: still-there
        """)
        let found = ProfileService.discoverJamfCLIProfiles(
            scheduleCounts: [:], _testBinaryOverride: list, _testConfigURL: file)
        let levels = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0.platformLevel) })
        XCTAssertEqual(levels["env"], .environment)
        XCTAssertEqual(levels["ten"], .tenant)
        XCTAssertEqual(levels["org"], .organization)
        XCTAssertEqual(levels["quiet"], .environment,
                       "a list row without an ID is not organization level when the file has one")
    }

    // MARK: - Filtering and run targets

    private func profile(
        _ name: String, _ product: JamfCLIProduct = .unknown,
        level: PlatformScopeLevel? = nil, status: JamfCLIProfile.Status = .idle
    ) -> JamfCLIProfile {
        JamfCLIProfile(
            name: name, url: "", schedules: 0, status: status, product: product,
            platformLevel: level)
    }

    private func workspace(_ name: String) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("jamf_cli: {}\n".utf8).write(to: dir.appendingPathComponent("config.yaml"))
    }

    func testAProtectOrSecurityLoginIsNotListedEvenWithAFolderOrWhenActive() throws {
        try workspace("prot")
        let all = [profile("prod", .pro), profile("prot", .protect), profile("sec", .securityCloud)]
        let listed = ProfileService.droppingPairedProductProfiles(
            all, under: root, keeping: ["prot", "sec"])
        XCTAssertEqual(listed.map(\.name), ["prod"])
        XCTAssertTrue(ProfileService.hasWorkspace("prot", under: root), "the folder is left alone")
    }

    func testProSchoolAndUnknownProfilesWithAFolderStayListed() throws {
        for name in ["a", "b", "c"] { try workspace(name) }
        let all = [profile("a", .pro), profile("b", .school), profile("c", .unknown)]
        XCTAssertEqual(
            ProfileService.droppingPairedProductProfiles(all, under: root).map(\.name),
            ["a", "b", "c"])
    }

    func testRunnableProfilesNeverRunAProtectLoginAndNeedAFolderForSchool() {
        let all = [
            profile("prod", .pro), profile("prot", .protect), profile("sec", .securityCloud),
            profile("sch", .school), profile("sch2", .school), profile("unk"),
        ]
        let withFolder: (String) -> Bool = { ["prot", "sch2"].contains($0) }
        XCTAssertEqual(
            ProfileService.runnableProfiles(
                all, excluding: [], hasWorkspace: withFolder).map(\.name),
            ["prod", "sch2", "unk"])
    }

    func testTheActiveProfileMovesToTheWorkspaceNamingItsProtectLogin() {
        let listed = [profile("first", .pro), profile("prod", .pro)]
        let owner: (String) -> String? = { $0 == "prod" ? "prot" : nil }
        XCTAssertEqual(
            WorkspaceStore.activeProfile(keeping: "prot", in: listed, protectProfile: owner),
            "prod")
        XCTAssertEqual(
            WorkspaceStore.activeProfile(keeping: "gone", in: listed, protectProfile: owner),
            "first", "an unknown name falls to the first usable profile")
        XCTAssertEqual(
            WorkspaceStore.activeProfile(keeping: "first", in: listed, protectProfile: owner),
            "first")
    }

    // MARK: - Adoption

    func testAdoptionRefusesAProtectLoginAndSetsUpSchoolAsSchool() async {
        let flow = ExistingCLISetupFlow(profiles: [
            profile("prod", .pro), profile("prot", .protect), profile("sch", .school),
        ])
        XCTAssertEqual(flow.selected, ["prod", "sch"])
        XCTAssertNotNil(flow.refusals["prot"])
        var initialized: [String] = []
        var schoolConfigured: [String] = []
        await flow.run(
            initialize: { initialized.append($0); return 0 },
            configureSchool: { schoolConfigured.append($0) },
            collect: { _, _ in 0 })
        XCTAssertEqual(initialized, ["prod", "sch"])
        XCTAssertEqual(schoolConfigured, ["sch"])
    }

    func testAProtectLoginTickedByHandIsStillNeverRun() async {
        let flow = ExistingCLISetupFlow(profiles: [profile("prot", .protect)])
        flow.selected.insert("prot")
        var initialized: [String] = []
        await flow.run(initialize: { initialized.append($0); return 0 }, collect: { _, _ in 0 })
        XCTAssertEqual(initialized, [])
    }

    func testAFailedSchoolConfigurationLeavesNoWorkspaceCounted() async {
        struct Boom: Error {}
        let flow = ExistingCLISetupFlow(profiles: [profile("sch", .school)])
        await flow.run(
            initialize: { _ in 0 }, configureSchool: { _ in throw Boom() },
            collect: { _, _ in 0 })
        XCTAssertFalse(flow.canContinue)
        XCTAssertEqual(flow.failureStages["sch"], .workspace)
    }

    // MARK: - Doctor

    func testDoctorSuggestsRemovingAProtectLoginsFolder() throws {
        let config = try decodeConfig("protect:\n  enabled: true\n  profile: prot\n")
        let rows = ConfigDoctorService.protectProfileFolderRows(
            profile: "prod", config: config,
            discovered: { [self.profile("prot", .protect)] }, folderExists: { $0 == "prot" })
        XCTAssertEqual(rows.map(\.id), ["protect.profile_folder"])
        XCTAssertEqual(rows.first?.severity, .suggest)
    }

    func testDoctorStaysQuietWithoutAFolderOrForAProLogin() throws {
        let config = try decodeConfig("protect:\n  enabled: true\n  profile: prot\n")
        XCTAssertTrue(ConfigDoctorService.protectProfileFolderRows(
            profile: "prod", config: config,
            discovered: { [self.profile("prot", .protect)] },
            folderExists: { _ in false }).isEmpty)
        XCTAssertTrue(ConfigDoctorService.protectProfileFolderRows(
            profile: "prod", config: config,
            discovered: { [self.profile("prot", .pro)] }, folderExists: { _ in true }).isEmpty)
    }

    private func decodeConfig(_ yaml: String) throws -> ReportConfig {
        let url = root.appendingPathComponent("c-\(UUID().uuidString.prefix(6)).yaml")
        try Data(yaml.utf8).write(to: url)
        return try ConfigLoader.load(from: url)
    }
}
