import XCTest
@testable import JamfReports

final class EnvironmentDoctorRowsTests: XCTestCase {
    private func env(_ yaml: String, ws: String = "ws") throws -> (EnvironmentProfiles, ReportConfig) {
        let config = try ConfigLoader.loadFromString(yaml)
        return (EnvironmentProfiles.resolve(config: config, workspace: ws), config)
    }

    func testTwoMDMsFail() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  jamf_school: ws\n")
        XCTAssertEqual(ConfigDoctorService.twoMDMRows(environment: e).map(\.id),
                       ["environment.two_mdms"])
        let (one, _) = try env("profiles:\n  jamf_pro: ws\n")
        XCTAssertTrue(ConfigDoctorService.twoMDMRows(environment: one).isEmpty)
    }

    func testOldKeysUnderABlockAreNamed() throws {
        let (e, c) = try env("profiles:\n  jamf_pro: ws\nprotect:\n  enabled: true\n  profile: p\n")
        let rows = ConfigDoctorService.oldKeyRows(environment: e, config: c)
        XCTAssertEqual(rows.map(\.id), ["environment.old_keys"])
        XCTAssertTrue(rows[0].detail.contains("protect.profile"))
        let (legacy, lc) = try env("protect:\n  enabled: true\n  profile: p\n")
        XCTAssertTrue(ConfigDoctorService.oldKeyRows(environment: legacy, config: lc).isEmpty,
                      "without a block the old keys are live")
    }

    func testASlotProfileJamfCLIDoesNotListWarns() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  platform: ws-API\n")
        XCTAssertEqual(ConfigDoctorService.unknownSlotProfileRows(
            environment: e, listed: ["ws"]).map(\.id), ["environment.unknown_profile"])
        XCTAssertTrue(ConfigDoctorService.unknownSlotProfileRows(
            environment: e, listed: ["ws", "ws-API"]).isEmpty)
        XCTAssertTrue(ConfigDoctorService.unknownSlotProfileRows(
            environment: e, listed: nil).isEmpty, "could not ask: no row")
    }

    func testAProfileInTwoEnvironmentsFails() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  protect: shared-P\n")
        let (o, _) = try env("profiles:\n  jamf_pro: other\n  protect: shared-P\n", ws: "other")
        XCTAssertEqual(ConfigDoctorService.profileSharedRows(
            profile: "ws", environment: e, others: [("other", o)]).map(\.id),
            ["environment.profile_shared"])
        XCTAssertTrue(ConfigDoctorService.profileSharedRows(
            profile: "ws", environment: e, others: []).isEmpty)
    }

    func testAPlatformSlotOnAnotherJamfProNamesBothHosts() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  platform: ws-API\n")
        let rows = ConfigDoctorService.platformHostRows(
            profile: "ws", environment: e,
            hosts: ("https://a.jamfcloud.com", "https://b.jamfcloud.com"))
        XCTAssertEqual(rows.map(\.id), ["environment.platform_host"])
        XCTAssertTrue(rows[0].detail.contains("a.jamfcloud.com"))
        XCTAssertTrue(rows[0].detail.contains("b.jamfcloud.com"))
        XCTAssertTrue(ConfigDoctorService.platformHostRows(
            profile: "ws", environment: e,
            hosts: ("https://a.jamfcloud.com", "https://a.jamfcloud.com")).isEmpty)
        XCTAssertTrue(ConfigDoctorService.platformHostRows(
            profile: "ws", environment: e, hosts: nil).isEmpty)
    }
}
