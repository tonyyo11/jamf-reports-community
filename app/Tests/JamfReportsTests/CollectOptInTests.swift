import XCTest
@testable import JamfReports

/// `jamf_cli.collect_opt_in`: the admin-hygiene sources are off until the file lists them AND this
/// Mac confirmed the list, so a peer's addition never turns one on here, while a removal applies
/// at once.
final class CollectOptInTests: XCTestCase {
    private let fileManager = FileManager.default
    private let profile = "optinprofile"
    private var root: URL!
    private var workspace: URL!
    private var macA: URL!
    private var macB: URL!

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-optin-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent(profile, isDirectory: true)
        macA = root.appendingPathComponent(".mac-a", isDirectory: true)
        macB = root.appendingPathComponent(".mac-b", isDirectory: true)
        for url in [workspace!, macA!, macB!] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fileManager.removeItem(at: root)
    }

    private var configURL: URL { workspace.appendingPathComponent("config.yaml") }

    private func write(_ list: String?, shared: Bool = true) throws {
        let line = list.map { "\n  collect_opt_in: \($0)" } ?? ""
        let text = (shared ? "shared_workspace:\n  enabled: true\n" : "")
            + "jamf_cli:\n  profile: \"\(profile)\"\(line)\n"
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func typed() throws -> [String]? {
        try ConfigLoader.load(from: configURL).jamfCli?.collectOptIn
    }

    private func effective(on mac: URL) throws -> [String] {
        SharedConfigPin.collectOptInList(
            configured: try typed(), profile: profile, appSupport: mac).effective
    }

    private func drifted(on mac: URL) -> Bool {
        SharedConfigPin.check(profile: profile, appSupport: mac).isDrifted(.collectOptIn)
    }

    private func confirm(on mac: URL) throws {
        try SharedConfigPin.confirm(
            profile: profile, drifts: SharedConfigPin.check(profile: profile, appSupport: mac).drifts,
            appSupport: mac)
    }

    // MARK: - Decoder and reader

    func testANonListReadsAsEmptyAndTheDecodeStillSucceeds() throws {
        for typed in ["laps-pending-rotations", "true", "{a: b}", "7"] {
            try write(typed, shared: false)
            XCTAssertNil(try self.typed(), typed)
            XCTAssertEqual(try effective(on: macA), [], typed)
        }
    }

    func testALocalWorkspaceUsesTheFilesListNarrowedToRealSources() throws {
        try write("[LAPS_Pending_Rotations, nonsense]", shared: false)
        XCTAssertEqual(
            SharedConfigPin.collectOptIn(
                configured: try typed(), profile: profile, appSupport: macA),
            ["laps-pending-rotations"])
        XCTAssertFalse(drifted(on: macA))
    }

    // MARK: - Pin

    func testAListAtFirstSightWaitsForAConfirm() throws {
        try write("[admin-accounts]")
        XCTAssertEqual(try effective(on: macA), [])
        XCTAssertTrue(drifted(on: macA))
        try confirm(on: macA)
        XCTAssertEqual(try effective(on: macA), ["admin-accounts"])
        XCTAssertFalse(drifted(on: macA))
    }

    func testAPeerAddingASourceIsDriftAndTurnsNothingOnHere() throws {
        try write("[admin-accounts]")
        try confirm(on: macA)
        try write("[admin-accounts, laps-pending-rotations]")
        XCTAssertEqual(try effective(on: macA), ["admin-accounts"])
        XCTAssertTrue(drifted(on: macA))
        try confirm(on: macA)
        XCTAssertEqual(try effective(on: macA), ["admin-accounts", "laps-pending-rotations"])
    }

    func testAPeerRemovingASourceTurnsItOffAtOnceWithNoConfirm() throws {
        try write("[admin-accounts, api-integrations]")
        try confirm(on: macA)
        try write("[admin-accounts]")
        XCTAssertEqual(try effective(on: macA), ["admin-accounts"])
        XCTAssertFalse(drifted(on: macA), "the safe value is pinned, not shown as drift")
        // Adding it back is an addition again: it waits.
        try write("[admin-accounts, api-integrations]")
        XCTAssertEqual(try effective(on: macA), ["admin-accounts"])
        XCTAssertTrue(drifted(on: macA))
    }

    /// Two Macs on one shared file: each follows only what it confirmed.
    func testTwoMacsEachFollowTheirOwnConfirmedSet() throws {
        try write("[laps-pending-rotations]")
        try confirm(on: macA)
        XCTAssertEqual(try effective(on: macA), ["laps-pending-rotations"])
        XCTAssertEqual(try effective(on: macB), [], "Mac B never confirmed")
        try write("[laps-pending-rotations, admin-accounts]")
        XCTAssertEqual(try effective(on: macA), ["laps-pending-rotations"])
        XCTAssertEqual(try effective(on: macB), [])
        try confirm(on: macB)
        XCTAssertEqual(try effective(on: macB), ["admin-accounts", "laps-pending-rotations"])
        XCTAssertEqual(try effective(on: macA), ["laps-pending-rotations"], "A still waits")
        try write("[admin-accounts]")
        XCTAssertEqual(try effective(on: macA), [], "a removal applies on both")
        XCTAssertEqual(try effective(on: macB), ["admin-accounts"])
        XCTAssertTrue(drifted(on: macA), "admin-accounts is still an addition A never confirmed")
        XCTAssertFalse(drifted(on: macB))
    }

    func testAPinWrittenBeforeTheKeyTreatsAListAsUnconfirmed() throws {
        try write(nil)
        _ = SharedConfigPin.check(profile: profile, appSupport: macA)
        var pin = try XCTUnwrap(SharedConfigPin.load(profile: profile, appSupport: macA))
        pin.pinnedKeys.removeAll { $0 == SharedConfigPin.Key.collectOptIn.rawValue }
        try SharedConfigPin.save(pin, profile: profile, appSupport: macA)
        try write("[api-integrations]")
        XCTAssertEqual(try effective(on: macA), [])
        XCTAssertTrue(drifted(on: macA))
    }

    func testEmptyingTheListEndsAFirstSightHold() throws {
        try write("[api-integrations]")
        XCTAssertTrue(drifted(on: macA))
        try write("[]")
        XCTAssertFalse(drifted(on: macA))
    }

    // MARK: - Writer

    func testTurningASourceOnWritesItAndConfirmsItOnThisMac() throws {
        try write(nil)
        try CollectSkipConfigWriter.setOptedIn(
            true, kind: "admin-accounts", profile: profile, appSupport: macA)
        XCTAssertEqual(try typed(), ["admin-accounts"])
        XCTAssertEqual(try effective(on: macA), ["admin-accounts"])
        XCTAssertFalse(drifted(on: macA))
        XCTAssertEqual(try effective(on: macB), [], "another Mac still waits")
    }

    func testTurningASourceOffWritesTheRemovalAndKeepsTheOthers() throws {
        try write("[admin-accounts, laps-pending-rotations]")
        try confirm(on: macA)
        try CollectSkipConfigWriter.setOptedIn(
            false, kind: "laps-pending-rotations", profile: profile, appSupport: macA)
        XCTAssertEqual(try typed(), ["admin-accounts"])
        XCTAssertEqual(try effective(on: macA), ["admin-accounts"])
        try CollectSkipConfigWriter.setOptedIn(
            false, kind: "admin-accounts", profile: profile, appSupport: macA)
        XCTAssertNil(try typed(), "the key goes when the list empties")
    }

    func testWhileAPeersAdditionWaitsARemovalIsWrittenAndAnAdditionIsRefused() throws {
        try write("[admin-accounts]")
        try confirm(on: macA)
        try write("[admin-accounts, laps-pending-rotations]")
        XCTAssertTrue(drifted(on: macA))
        XCTAssertThrowsError(try CollectSkipConfigWriter.setOptedIn(
            true, kind: "api-integrations", profile: profile, appSupport: macA)) {
            XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError, .changedOnAnotherMac)
        }
        XCTAssertEqual(try typed(), ["admin-accounts", "laps-pending-rotations"])
        try CollectSkipConfigWriter.setOptedIn(
            false, kind: "admin-accounts", profile: profile, appSupport: macA)
        XCTAssertEqual(try typed(), ["laps-pending-rotations"])
        XCTAssertEqual(try effective(on: macA), [], "the peer's addition was never confirmed")
        XCTAssertTrue(drifted(on: macA))
    }

    func testAPeerWritingBetweenTheCheckAndTheWriteIsNeverConfirmed() throws {
        try write("[admin-accounts]")
        try confirm(on: macA)
        XCTAssertThrowsError(try CollectSkipConfigWriter.setOptedIn(
            true, kind: "api-integrations", profile: profile, appSupport: macA,
            beforeWrite: { try? self.write("[admin-accounts, laps-pending-rotations]") })) {
            XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError, .changedOnAnotherMac)
        }
        XCTAssertEqual(try typed(), ["admin-accounts", "laps-pending-rotations"])
    }

    func testTheWritersRefuseWhatBelongsToTheOtherSwitch() throws {
        try write(nil, shared: false)
        XCTAssertThrowsError(try CollectSkipConfigWriter.setCollecting(
            "admin-accounts", false, profile: profile, appSupport: macA)) {
            XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError,
                           .optInSource("admin-accounts"))
        }
        XCTAssertThrowsError(try CollectSkipConfigWriter.setOptedIn(
            true, kind: "sofa", profile: profile, appSupport: macA)) {
            XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError, .unknownSource("sofa"))
        }
        XCTAssertNil(try typed())
    }

    func testAnOptInKindListedInCollectSkipTurnsNothingOff() {
        XCTAssertEqual(ReportEngine.listedSkipKinds(["admin-accounts", "sofa"]), ["sofa"])
        XCTAssertFalse(ReportEngine.optionalKinds().contains("laps-pending-rotations"))
        XCTAssertEqual(ReportEngine.listedOptInKinds([" Admin_Accounts ", "sofa"]),
                       ["admin-accounts"])
    }

    // MARK: - Freshness strip

    func testExpectedKindsListAnOptInSourceOnlyWhenItIsOn() {
        func kinds(_ optIn: Set<String>) -> Set<String> {
            Set(WorkspaceStore.expectedKinds(
                skipExpensive: false, authMethod: "oauth2", jamfCLIVersion: "1.38.0",
                optIn: optIn))
        }
        XCTAssertFalse(kinds([]).contains("api-integrations"))
        XCTAssertTrue(kinds(["api-integrations"]).contains("api-integrations"))
        XCTAssertTrue(kinds([]).contains("certificate-authority"))
    }

    func testTheFreshnessDefaultFailsTheSameWayAsThePlannerOnAnUnknownVersion() {
        XCTAssertFalse(WorkspaceStore.expectedKinds(skipExpensive: false, authMethod: "oauth2")
            .contains("certificate-authority"))
    }

    func testThePinHoldsOnlyOptInNamesThatExist() {
        let typed: [Any] = ["Laps_Pending_Rotations", "junk", "admin-accounts", 7]
        XCTAssertEqual(SharedConfigPin.collectOptInText(typed),
                       "admin-accounts, laps-pending-rotations")
        XCTAssertEqual(SharedConfigPin.collectOptInText(["junk"] as [Any]), "")
    }

    func testTheStoreReadsTheConfirmedListForTheFreshnessStrip() throws {
        try write("[api-integrations]", shared: false)
        XCTAssertTrue(WorkspaceStore.expectedKinds(
            profile: profile, jamfCLIVersion: "1.38.0", auth: nil).contains("api-integrations"))
        try write(nil, shared: false)
        XCTAssertFalse(WorkspaceStore.expectedKinds(
            profile: profile, jamfCLIVersion: "1.38.0", auth: nil).contains("api-integrations"))
    }

    // MARK: - Config Doctor

    func testDoctorNamesAnUnknownEntryAndANonList() throws {
        try write("[admin-accounts, typo-source]", shared: false)
        var rows = ConfigDoctorService.optInRows(
            profile: profile, config: try ConfigLoader.load(from: configURL))
        let unknown = try XCTUnwrap(rows.first { $0.id == "server_health.opt_in_unknown" })
        XCTAssertEqual(unknown.severity, .warn)
        XCTAssertTrue(unknown.detail.contains("typo-source"))
        XCTAssertFalse(unknown.detail.contains("admin-accounts"))

        try write("laps-pending-rotations", shared: false)
        rows = ConfigDoctorService.optInRows(
            profile: profile, config: try ConfigLoader.load(from: configURL))
        XCTAssertEqual(rows.map(\.id), ["server_health.opt_in_unknown"])
        XCTAssertTrue(rows[0].detail.contains("not a list"))
    }

    func testDoctorWarnsAboutTheLAPSPrivilegeOnlyWhileLAPSIsOn() throws {
        try write("[laps-pending-rotations]", shared: false)
        var rows = ConfigDoctorService.optInRows(
            profile: profile, config: try ConfigLoader.load(from: configURL))
        XCTAssertEqual(rows.map(\.id), ["server_health.laps_privilege"])
        XCTAssertEqual(rows.first?.severity, .warn)
        try write("[admin-accounts, api-integrations]", shared: false)
        rows = ConfigDoctorService.optInRows(
            profile: profile, config: try ConfigLoader.load(from: configURL))
        XCTAssertTrue(rows.isEmpty)
        try write(nil, shared: false)
        XCTAssertTrue(ConfigDoctorService.optInRows(
            profile: profile, config: try ConfigLoader.load(from: configURL)).isEmpty)
    }

    func testTheBundleKeepsTheOptInListAsWritten() {
        XCTAssertTrue(DiagnosticBundleService.vocabularyKeys.contains("collect_opt_in"))
    }

    func testBothListsAreKeysAScreenWrites() {
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["jamf_cli", "collect_skip"]))
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["jamf_cli", "collect_opt_in"]))
    }
}
