import XCTest
@testable import JamfReports

/// Attaching an existing Security Cloud login: the pin key, the writer, the card row and the
/// Data Sources button's rule.
final class SecurityCloudAttachTests: XCTestCase {
    private var root: URL!
    private let ws = "scattach"
    private var support: URL { root.appendingPathComponent("support", isDirectory: true) }
    private var configURL: URL {
        root.appendingPathComponent(ws).appendingPathComponent("config.yaml")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JRC-SCAttach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws, isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func write(_ text: String) throws {
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func check() -> SharedConfigPin.Check {
        SharedConfigPin.check(profile: ws, appSupport: support)
    }

    private func allowed(_ name: String) -> Bool {
        SharedConfigPin.securityCloudAllowed(profile: ws, name: name, appSupport: support)
    }

    private let shared = "shared_workspace:\n  enabled: true\nprofiles:\n  jamf_pro: scattach\n"

    // MARK: - Pin

    func testTheSlotIsHeldAtFirstSightAndADriftNeedsAConfirm() throws {
        try write(shared + "  security_cloud: sc-a\n")
        XCTAssertEqual(check().drifts.map(\.key), [.securityCloudProfile])
        XCTAssertFalse(allowed("sc-a"))
        try SharedConfigPin.confirm(profile: ws, drifts: check().drifts, appSupport: support)
        XCTAssertTrue(allowed("sc-a"))
        try write(shared + "  security_cloud: sc-peer\n")
        XCTAssertEqual(check().drifts.map(\.key), [.securityCloudProfile])
        XCTAssertFalse(allowed("sc-peer"))
        XCTAssertFalse(allowed("sc-a"), "the name the run loaded before the edit is held too")
        try SharedConfigPin.confirm(profile: ws, drifts: check().drifts, appSupport: support)
        XCTAssertTrue(allowed("sc-peer"))
    }

    func testAnEmptySlotIsNotHeld() throws {
        try write(shared)
        XCTAssertTrue(check().drifts.isEmpty)
    }

    func testAnOlderPinWithoutTheKeyAdoptsItAsUnconfirmed() throws {
        try write(shared)
        _ = check()
        var older = try XCTUnwrap(SharedConfigPin.load(profile: ws, appSupport: support))
        older.pinnedKeys.removeAll { $0 == SharedConfigPin.Key.securityCloudProfile.rawValue }
        try SharedConfigPin.save(older, profile: ws, appSupport: support)
        try write(shared + "  security_cloud: sc-a\n")
        XCTAssertEqual(check().drifts.map(\.key), [.securityCloudProfile])
        let pin = try XCTUnwrap(SharedConfigPin.load(profile: ws, appSupport: support))
        XCTAssertTrue(pin.unconfirmed.contains(SharedConfigPin.Key.securityCloudProfile.rawValue))
        XCTAssertFalse(allowed("sc-a"))
    }

    func testAPinFileWithoutTheFieldStillDecodes() throws {
        try write(shared)
        _ = check()
        let pin = try XCTUnwrap(SharedConfigPin.load(profile: ws, appSupport: support))
        XCTAssertEqual(pin.securityCloudProfile, "")
    }

    // MARK: - Writer

    func testAttachWritesTheSlotAndConfirmsThePin() throws {
        try write("shared_workspace:\n  enabled: true\n")
        SharedConfigPin.checkpoint(profile: ws, appSupport: support, onLine: nil)
        try UnassignedProfilesCardText.attachSecurityCloud(
            "sc-a", workspace: ws, appSupport: support)
        let environment = EnvironmentProfiles.resolve(
            config: try ConfigLoader.load(from: configURL), workspace: ws)
        XCTAssertEqual(environment.securityCloud, "sc-a")
        XCTAssertEqual(environment.jamfPro, ws)
        XCTAssertTrue(check().drifts.isEmpty)
        XCTAssertTrue(allowed("sc-a"))
    }

    func testAttachRefusesAnUnusableName() throws {
        try write("profiles:\n  jamf_pro: scattach\n")
        XCTAssertThrowsError(
            try UnassignedProfilesCardText.attachSecurityCloud(
                "bad\u{7}", workspace: ws, appSupport: support))
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(text.contains("security_cloud"))
    }

    func testRemoveClearsTheSlotAndThePin() throws {
        try write("shared_workspace:\n  enabled: true\n")
        SharedConfigPin.checkpoint(profile: ws, appSupport: support, onLine: nil)
        try UnassignedProfilesCardText.attachSecurityCloud(
            "sc-a", workspace: ws, appSupport: support)
        try ProfilesConfigWriter.save(.securityCloud, to: nil, workspace: ws, appSupport: support)
        let environment = EnvironmentProfiles.resolve(
            config: try ConfigLoader.load(from: configURL), workspace: ws)
        XCTAssertNil(environment.securityCloud)
        XCTAssertTrue(check().drifts.isEmpty)
    }

    // MARK: - Button rule

    private func row(_ product: JamfCLIProduct) -> AddSheetPlan.UnassignedProfile {
        .init(name: "sc", product: product, url: "", use: .unavailable("x"))
    }

    func testTheButtonIsOfferedOnlyForASecurityCloudLoginAndNeverInDemo() {
        let text = UnassignedProfilesCardText.self
        func offers(_ product: JamfCLIProduct, _ accepts: Bool, _ demo: Bool) -> Bool {
            text.offersAttach(row(product), acceptsSecurityCloud: accepts, demo: demo)
        }
        XCTAssertTrue(offers(.securityCloud, true, false))
        XCTAssertFalse(offers(.securityCloud, true, true))
        XCTAssertFalse(offers(.securityCloud, false, false))
        XCTAssertFalse(offers(.protect, true, false))
    }

    func testTheRefusalNowSaysWhereToAddIt() {
        let reason = ExistingCLISetupFlow.securityCloudReason
        XCTAssertTrue(reason.contains("Data Sources"))
        XCTAssertFalse(reason.contains("not supported yet"))
        let profile = JamfCLIProfile(
            name: "sc", url: "https://sec.example.com", schedules: 0, status: .idle,
            authMethod: "security", product: .securityCloud)
        XCTAssertEqual(ExistingCLISetupFlow.refusal(for: profile), reason)
        XCTAssertTrue(JamfCLIProduct.securityCloud.isNeverAWorkspace)
    }

    // MARK: - Card

    private func card(_ yaml: String) throws -> EnvironmentCardState {
        EnvironmentCardState.build(
            workspace: ws,
            environment: EnvironmentProfiles.resolve(
                config: try ConfigLoader.loadFromString(yaml), workspace: ws),
            resolve: { _ in .init(authMethod: "security", isTenantLevel: false) },
            newest: { _ in nil },
            drifted: { $0 == .securityCloudProfile })
    }

    func testTheCardHasASecurityCloudRowForProAndSchool() throws {
        for yaml in ["profiles:\n  jamf_pro: scattach\n  security_cloud: sc-a\n",
                     "profiles:\n  jamf_school: scattach\n  security_cloud: sc-a\n"] {
            let state = try card(yaml)
            let row = try XCTUnwrap(state.rows.first { $0.slot == .securityCloud })
            XCTAssertEqual(row.profile, "sc-a")
            XCTAssertEqual(row.product, "Jamf Security Cloud")
            XCTAssertTrue(row.pinNeedsConfirming)
            XCTAssertTrue(row.canRemove)
            XCTAssertFalse(state.acceptsSecurityCloud)
        }
        XCTAssertEqual(EnvironmentCardState.kinds(for: .securityCloud), ["security-risk"])
    }

    func testTheCardAcceptsAnAttachOnlyWithAnMDMAndAnEmptySlot() throws {
        XCTAssertTrue(try card("profiles:\n  jamf_pro: scattach\n").acceptsSecurityCloud)
        XCTAssertTrue(try card("profiles:\n  jamf_school: scattach\n").acceptsSecurityCloud)
        XCTAssertFalse(try card("profiles:\n  protect: scattach\n").acceptsSecurityCloud)
        XCTAssertTrue(try card("jamf_cli:\n  data_dir: x\n").acceptsSecurityCloud)
    }

    func testTheDoctorWarnsForASlotNamingAnotherProduct() throws {
        let config = try ConfigLoader.loadFromString(
            "profiles:\n  jamf_pro: scattach\n  security_cloud: sc-a\n")
        func rows(_ product: JamfCLIProduct) -> [DoctorRow] {
            ConfigDoctorService.securityCloudProfileProductRows(
                config: config, workspace: ws,
                resolved: { _ in
                    .init(authMethod: "oauth2", isTenantLevel: false, product: product)
                })
        }
        XCTAssertEqual(rows(.pro).map(\.id), ["security_cloud.profile_product"])
        XCTAssertTrue(rows(.securityCloud).isEmpty)
        XCTAssertTrue(rows(.unknown).isEmpty)
    }
}
