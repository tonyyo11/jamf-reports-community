import Foundation
import XCTest
@testable import JamfReports

/// jamf-cli's wiki recommends an oauth2 profile beside the gateway profile. When both reach the
/// same Jamf Pro, adoption keeps one workspace; Config Doctor names the pair for a user who
/// already has two. Any failure to learn the instance changes nothing.
@MainActor
final class PlatformTwinTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("platform-twin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        PlatformTwin.invalidateCache()
    }

    override func tearDownWithError() throws {
        PlatformTwin.invalidateCache()
        try? FileManager.default.removeItem(at: root)
    }

    private func profile(
        _ name: String, auth: String, url: String = "", product: JamfCLIProduct = .pro,
        level: PlatformScopeLevel? = nil
    ) -> JamfCLIProfile {
        JamfCLIProfile(
            name: name, url: url, schedules: 0, status: .idle, authMethod: auth,
            product: product, platformLevel: level)
    }

    private var platform: JamfCLIProfile {
        profile("gw", auth: "platform", url: "us.api.jamfcloud.com", level: .environment)
    }
    private var direct: JamfCLIProfile {
        profile("direct", auth: "oauth2", url: "acme.jamfcloud.com")
    }

    // MARK: - Matching

    func testHostComparisonIgnoresCaseSchemePortAndPath() {
        XCTAssertEqual(PlatformTwin.host(of: "https://Acme.JamfCloud.com:8443/path"),
                       "acme.jamfcloud.com")
        XCTAssertEqual(PlatformTwin.host(of: "acme.jamfcloud.com"), "acme.jamfcloud.com")
        XCTAssertNil(PlatformTwin.host(of: ""))
        XCTAssertNil(PlatformTwin.host(of: nil))
    }

    func testServerURLOutputIsParsedAndAnythingElseIsNot() {
        func parse(_ text: String) -> String? {
            PlatformTwin.jamfProURL(inServerURLOutput: Data(text.utf8))
        }
        XCTAssertEqual(
            parse(#"{"url":"https://acme.jamfcloud.com"}"#), "https://acme.jamfcloud.com")
        XCTAssertNil(parse(#"{"url":""}"#))
        XCTAssertNil(parse(#"{"other":"https://acme.jamfcloud.com"}"#))
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(#"[{"url":"https://acme.jamfcloud.com"}]"#))
    }

    func testOnlyAnOAuth2ProfileOnTheSameHostIsATwin() {
        let others = [
            direct,
            profile("other", auth: "oauth2", url: "elsewhere.jamfcloud.com"),
            profile("gw2", auth: "platform", url: "acme.jamfcloud.com"),
            profile("school", auth: "apikey", url: "acme.jamfcloud.com", product: .school),
            profile("prot", auth: "oauth2", url: "acme.jamfcloud.com", product: .protect),
        ]
        XCTAssertEqual(
            PlatformTwin.twins(reaching: "ACME.jamfcloud.com", among: others).map(\.name),
            ["direct"])
        XCTAssertTrue(PlatformTwin.twins(reaching: "nobody.jamfcloud.com", among: others).isEmpty)
    }

    func testJamfProIsNotAskedWithoutAnOAuth2ProfileToMatch() {
        var asked = 0
        let none = PlatformTwin.twins(
            ofPlatformProfile: platform, among: [platform],
            learn: { _ in asked += 1; return "https://acme.jamfcloud.com" })
        XCTAssertNil(none)
        XCTAssertEqual(asked, 0)
        let org = profile("org", auth: "platform", level: .organization)
        XCTAssertNil(PlatformTwin.twins(
            ofPlatformProfile: org, among: [org, direct],
            learn: { _ in "https://acme.jamfcloud.com" }))
    }

    // MARK: - The probe

    private func stub(_ body: String) throws -> (bin: URL, calls: URL) {
        let calls = root.appendingPathComponent("calls.log")
        let bin = root.appendingPathComponent("twin-stub")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(calls.path)\"\n\(body)\n"
            .write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (bin, calls)
    }

    func testLearnRunsOnlyTheReadOnlyServerURLGetOnTheNamedProfile() throws {
        let (bin, calls) = try stub(#"printf '{"url":"https://acme.jamfcloud.com"}'"#)
        XCTAssertEqual(
            PlatformTwin.learnJamfProURL(profile: "gw", binary: bin, timeout: 20),
            "https://acme.jamfcloud.com")
        let argv = try String(contentsOf: calls, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(argv, "-p gw pro jamf-pro-server-url get --output json --no-input")
    }

    func testLearnReturnsNilOnAFailedUnreadableOrTimedOutProbe() throws {
        let failing = try stub("exit 8").bin
        XCTAssertNil(PlatformTwin.learnJamfProURL(profile: "a", binary: failing, timeout: 20))
        let garbage = try stub("printf 'oops'").bin
        XCTAssertNil(PlatformTwin.learnJamfProURL(profile: "b", binary: garbage, timeout: 20))
        let hung = try stub("sleep 30").bin
        XCTAssertNil(PlatformTwin.learnJamfProURL(profile: "c", binary: hung, timeout: 1))
        XCTAssertNil(PlatformTwin.learnJamfProURL(profile: "d", binary: nil))
    }

    func testASuccessIsCachedAndAFailureIsNot() throws {
        let (bin, calls) = try stub(#"printf '{"url":"https://acme.jamfcloud.com"}'"#)
        _ = PlatformTwin.learnJamfProURL(profile: "gw", binary: bin, timeout: 20)
        _ = PlatformTwin.learnJamfProURL(profile: "gw", binary: bin, timeout: 20)
        let lines = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
    }

    // MARK: - Adoption

    func testAdoptionKeepsOnlyThePlatformProfileWhenBothReachTheSameJamfPro() async {
        let flow = ExistingCLISetupFlow(profiles: [platform, direct])
        XCTAssertEqual(flow.selected, ["gw", "direct"])
        await flow.resolveTwins(learn: { _ in "https://acme.jamfcloud.com" })
        XCTAssertEqual(flow.selected, ["gw"])
        XCTAssertEqual(flow.twinOf, ["direct": "gw"])
        XCTAssertEqual(flow.twinsLeftOut, ["direct"])
        let note = flow.twinNote(for: "direct") ?? ""
        XCTAssertTrue(note.contains("Same Jamf Pro as gw"), note)
        XCTAssertTrue(note.contains("not collected"), note)
        XCTAssertNil(flow.twinNote(for: "gw"))
    }

    func testAdoptionChangesNothingWhenTheInstancesDifferOrTheProbeFails() async {
        let differ = ExistingCLISetupFlow(profiles: [platform, direct])
        await differ.resolveTwins(learn: { _ in "https://another.jamfcloud.com" })
        XCTAssertEqual(differ.selected, ["gw", "direct"])
        XCTAssertTrue(differ.twinOf.isEmpty)

        let failed = ExistingCLISetupFlow(profiles: [platform, direct])
        await failed.resolveTwins(learn: { _ in nil })
        XCTAssertEqual(failed.selected, ["gw", "direct"])
        XCTAssertTrue(failed.twinsLeftOut.isEmpty)
    }

    func testAChoiceTheUserMadeIsNotOverridden() async {
        let ticked = ExistingCLISetupFlow(profiles: [platform, direct])
        ticked.setSelected("direct", true)
        await ticked.resolveTwins(learn: { _ in "https://acme.jamfcloud.com" })
        XCTAssertEqual(ticked.selected, ["gw", "direct"], "the user ticked it; it stays")
        XCTAssertTrue(ticked.twinsLeftOut.isEmpty)
        XCTAssertNotNil(ticked.twinNote(for: "direct"), "the note still names the twin")
    }

    func testAnUntickedTwinIsNotInitializedAndIsExcludedFromAllProfilesRuns() async {
        let flow = ExistingCLISetupFlow(profiles: [platform, direct])
        await flow.resolveTwins(learn: { _ in "https://acme.jamfcloud.com" })
        var initialized: [String] = []
        await flow.run(initialize: { initialized.append($0); return 0 }, collect: { _, _ in 0 })
        XCTAssertEqual(initialized, ["gw"])
        var base = AutomationPolicy()
        base.excludedProfiles = ["kept"]
        flow.enableAutomation = false
        XCTAssertEqual(flow.configuredPolicy(basedOn: base).excludedProfiles, ["kept", "direct"])
        XCTAssertFalse(flow.configuredPolicy(basedOn: base).isManaged)
    }

    func testNoPlatformProfileMeansNoQuestionAsked() async {
        let asked = Counter()
        let flow = ExistingCLISetupFlow(profiles: [direct, profile("o2", auth: "oauth2")])
        await flow.resolveTwins(learn: { _ in asked.bump(); return nil })
        XCTAssertEqual(asked.count, 0)
    }

    func testTheLearnedURLIsKeptOnAnExistingConnectionMemberOnly() throws {
        let store = ConnectionStore(url: root.appendingPathComponent("connections.json"))
        try store.upsert(Connection(
            name: "Acme", region: .us, level: .environment,
            members: [.init(profile: "gw", scopeID: "e1", product: .pro)]))
        let flow = ExistingCLISetupFlow(profiles: [platform, direct])
        let learned = expectation(description: "resolved")
        Task {
            await flow.resolveTwins(learn: { _ in "https://acme.jamfcloud.com" })
            learned.fulfill()
        }
        wait(for: [learned], timeout: 10)
        flow.recordLearnedURLs(in: store)
        XCTAssertEqual(store.jamfProURL(profile: "gw"), "https://acme.jamfcloud.com")
        XCTAssertNil(store.jamfProURL(profile: "direct"))
        XCTAssertFalse(try store.recordJamfProURL(profile: "unknown", url: "https://x.example"))
        XCTAssertEqual(store.load().count, 1, "no connection was invented")
    }

    func testAMemberWrittenBeforeTheFieldExistedStillDecodes() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","name":"A","region":"us","level":"environment",
          "createdAt":"2026-10-01T00:00:00Z",
          "members":[{"profile":"gw","scopeID":"e1","label":"gw","product":"pro"},
                     {"profile":"b","scopeID":"e2","jamfProURL":42}]}]
        """
        let url = root.appendingPathComponent("connections.json")
        try Data(json.utf8).write(to: url)
        let members = ConnectionStore(url: url).load().first?.members
        XCTAssertEqual(members?.map(\.jamfProURL), [nil, nil])
        XCTAssertEqual(members?.count, 2)
    }

    // MARK: - Console link

    func testAPlatformProfileLinksToItsLearnedJamfProButNeverTheGateway() {
        XCTAssertEqual(
            WorkspaceStore.consoleServer(
                forProfileURL: "us.api.jamfcloud.com", authMethod: "platform",
                learnedJamfProURL: "https://acme.jamfcloud.com"),
            "https://acme.jamfcloud.com")
        XCTAssertEqual(
            WorkspaceStore.consoleServer(
                forProfileURL: "us.api.jamfcloud.com", authMethod: "platform",
                learnedJamfProURL: "https://us.api.jamfcloud.com"), "")
        XCTAssertEqual(
            WorkspaceStore.consoleServer(
                forProfileURL: "us.api.jamfcloud.com", authMethod: "platform"), "")
    }

    // MARK: - Doctor

    func testDoctorNamesTheTwinOnEitherWorkspace() {
        let all = [platform, direct]
        for me in ["gw", "direct"] {
            let rows = ConfigDoctorService.platformTwinRows(
                profile: me, discovered: all, hasWorkspace: { _ in true },
                learn: { _ in "https://acme.jamfcloud.com" })
            XCTAssertEqual(rows.map(\.id), ["platform.twin"], me)
            XCTAssertEqual(rows.first?.severity, .suggest)
            XCTAssertTrue(rows[0].detail.contains("'gw'") && rows[0].detail.contains("'direct'"))
        }
    }

    func testDoctorStaysQuietWithoutAMatchOrBothWorkspaces() {
        let all = [platform, direct]
        XCTAssertTrue(ConfigDoctorService.platformTwinRows(
            profile: "gw", discovered: all, hasWorkspace: { _ in true },
            learn: { _ in "https://another.jamfcloud.com" }).isEmpty)
        XCTAssertTrue(ConfigDoctorService.platformTwinRows(
            profile: "gw", discovered: all, hasWorkspace: { $0 == "gw" },
            learn: { _ in "https://acme.jamfcloud.com" }).isEmpty)
        XCTAssertTrue(ConfigDoctorService.platformTwinRows(
            profile: "gw", discovered: all, hasWorkspace: { _ in true },
            learn: { _ in nil }).isEmpty)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
