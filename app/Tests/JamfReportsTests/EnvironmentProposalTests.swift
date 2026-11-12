import XCTest
@testable import JamfReports

final class EnvironmentProposalTests: XCTestCase {
    private func profile(
        _ name: String, auth: String, url: String = "", product: JamfCLIProduct = .pro,
        level: PlatformScopeLevel? = nil
    ) -> JamfCLIProfile {
        JamfCLIProfile(
            name: name, url: url, schedules: 0, status: .idle, authMethod: auth,
            product: product, platformLevel: level)
    }

    private func gw(_ name: String) -> JamfCLIProfile {
        profile(name, auth: "platform", url: "us.api.jamfcloud.com", level: .environment)
    }

    private let exampleURLs = [
        "Example-API": "https://example.jamfcloud.com",
        "Example-Dev-API": "https://example-dev.jamfcloud.com",
    ]

    private func four() -> [JamfCLIProfile] {
        [
            profile("Example", auth: "oauth2", url: "example.jamfcloud.com"),
            gw("Example-API"),
            profile("Example-Dev", auth: "oauth2", url: "example-dev.jamfcloud.com"),
            gw("Example-Dev-API"),
        ]
    }

    func testFourProfileExampleGivesTwoEnvironments() {
        let result = EnvironmentProposal.propose(
            profiles: four(), learnedJamfProURLs: exampleURLs, existingWorkspaces: [:])
        XCTAssertEqual(result.environments.map(\.workspace), ["Example", "Example-Dev"])
        XCTAssertEqual(result.environments.map(\.platform), ["Example-API", "Example-Dev-API"])
        XCTAssertTrue(result.unassigned.isEmpty)
    }

    func testConnectionSiblingsAreNeverOneEnvironment() {
        let result = EnvironmentProposal.propose(
            profiles: [gw("A-API"), gw("B-API")],
            learnedJamfProURLs: ["A-API": "a.jamfcloud.com", "B-API": "b.jamfcloud.com"],
            existingWorkspaces: [:])
        XCTAssertEqual(result.environments.map(\.workspace), ["A-API", "B-API"])
        XCTAssertEqual(result.environments.map(\.platform), [nil, nil])
    }

    func testTwoPlatformProfilesOnOneHostAreFlaggedAndUnpaired() {
        let profiles = [profile("Example", auth: "oauth2", url: "example.jamfcloud.com"),
                        gw("P1"), gw("P2")]
        let result = EnvironmentProposal.propose(
            profiles: profiles,
            learnedJamfProURLs: ["P1": "example.jamfcloud.com", "P2": "example.jamfcloud.com"],
            existingWorkspaces: [:])
        XCTAssertEqual(result.environments.map(\.workspace), ["Example"])
        XCTAssertNil(result.environments.first?.platform)
        XCTAssertEqual(Set(result.unassigned.keys), ["P1", "P2"])
        XCTAssertTrue(result.unassigned["P1"]?.contains("example.jamfcloud.com") == true)
    }

    func testExistingWorkspaceIsExtendedNotDuplicated() {
        let existing = ["Example": EnvironmentProfiles(jamfPro: "Example")]
        let result = EnvironmentProposal.propose(
            profiles: Array(four().prefix(2)), learnedJamfProURLs: exampleURLs,
            existingWorkspaces: existing)
        XCTAssertTrue(result.environments.isEmpty)
        XCTAssertEqual(result.extensions.map(\.id), ["Example/Example-API"])
        XCTAssertEqual(result.extensions.first?.slot, .platform)
    }

    /// A free oauth2 profile on the same Jamf Pro must not take the twin from a workspace that
    /// exists, or the Add sheet offers a second workspace for one fleet.
    func testExistingWorkspaceBeatsAFreeTwinOfAnEarlierName() {
        let existing = ["Prod": EnvironmentProfiles(jamfPro: "Prod")]
        let profiles = [
            profile("Admin", auth: "oauth2", url: "example.jamfcloud.com"),
            profile("Prod", auth: "oauth2", url: "example.jamfcloud.com"),
            gw("Prod-API"),
        ]
        let result = EnvironmentProposal.propose(
            profiles: profiles, learnedJamfProURLs: ["Prod-API": "https://example.jamfcloud.com"],
            existingWorkspaces: existing)
        XCTAssertEqual(result.extensions.map(\.id), ["Prod/Prod-API"])
        XCTAssertFalse(result.environments.contains { $0.platform == "Prod-API" })
        XCTAssertFalse(result.environments.contains { $0.workspace == "Prod-API" })
    }

    func testExistingWorkspaceWithAnotherPlatformLeavesTheProfileUnassigned() {
        let existing = ["Example": EnvironmentProfiles(jamfPro: "Example", platform: "Old-API")]
        let result = EnvironmentProposal.propose(
            profiles: Array(four().prefix(2)), learnedJamfProURLs: exampleURLs,
            existingWorkspaces: existing)
        XCTAssertTrue(result.environments.isEmpty)
        XCTAssertTrue(result.extensions.isEmpty)
        XCTAssertEqual(result.unassigned["Example-API"],
                       "Example already has Platform API profile Old-API.")
    }

    func testProtectSuggestedByBoundaryPrefix() {
        let profiles = four() + [
            profile("Example-Protect", auth: "oauth2", url: "p.protect.jamfcloud.com",
                    product: .protect),
            profile("ExampleCorp-Protect", auth: "oauth2", product: .protect),
            profile("Example-Dev-Protect", auth: "oauth2", product: .protect),
        ]
        let result = EnvironmentProposal.propose(
            profiles: profiles, learnedJamfProURLs: exampleURLs, existingWorkspaces: [:])
        let suggested = Dictionary(
            uniqueKeysWithValues: result.protectChoices.map { ($0.profile, $0.suggested) })
        XCTAssertEqual(suggested["Example-Protect"], "Example")
        XCTAssertEqual(suggested["Example-Dev-Protect"], "Example-Dev")
        XCTAssertEqual(suggested["ExampleCorp-Protect"] ?? nil, nil)
        XCTAssertEqual(suggested.count, 3)
    }

    func testProtectIsNeverPlacedInAnEnvironment() {
        let profiles = four() + [profile("Example-Protect", auth: "oauth2", product: .protect)]
        let result = EnvironmentProposal.propose(
            profiles: profiles, learnedJamfProURLs: exampleURLs, existingWorkspaces: [:])
        let names = result.environments.flatMap { [$0.workspace, $0.platform].compactMap { $0 } }
        XCTAssertFalse(names.contains("Example-Protect"))
        XCTAssertEqual(result.protectChoices.map(\.profile), ["Example-Protect"])
    }

    func testSchoolIsItsOwnEnvironment() {
        let result = EnvironmentProposal.propose(
            profiles: [profile("Academy", auth: "apikey", url: "x.jamfschool.com",
                               product: .school)],
            learnedJamfProURLs: [:], existingWorkspaces: [:])
        XCTAssertEqual(result.environments,
                       [.init(workspace: "Academy", isSchool: true, platform: nil,
                              learnedJamfProURL: nil)])
    }

    func testSecurityCloudAndOrganizationLevelAreUnassignedWithReasons() {
        let result = EnvironmentProposal.propose(
            profiles: [
                profile("Sec", auth: "security", product: .securityCloud),
                profile("Org", auth: "platform", url: "us.api.jamfcloud.com", level: .organization),
                profile("Broken", auth: "oauth2"),
            ],
            learnedJamfProURLs: [:], existingWorkspaces: [:], unusable: ["Broken": "Bad name."])
        XCTAssertTrue(result.environments.isEmpty)
        XCTAssertEqual(result.unassigned["Sec"], ExistingCLISetupFlow.securityCloudReason)
        XCTAssertEqual(result.unassigned["Org"], PlatformScopeLevel.organizationLevelReason)
        XCTAssertEqual(result.unassigned["Broken"], "Bad name.")
    }

    func testProfilesExistingWorkspacesNameAreLeftOut() {
        let existing = [
            "example": EnvironmentProfiles(jamfPro: "Example", protect: "Example-Protect"),
        ]
        let profiles = [
            profile("Example", auth: "oauth2", url: "example.jamfcloud.com"),
            profile("Example-Protect", auth: "oauth2", product: .protect),
            profile("Other", auth: "oauth2", url: "other.jamfcloud.com"),
        ]
        let result = EnvironmentProposal.propose(
            profiles: profiles, learnedJamfProURLs: [:], existingWorkspaces: existing)
        XCTAssertEqual(result.environments.map(\.workspace), ["Other"])
        XCTAssertTrue(result.protectChoices.isEmpty)
        XCTAssertTrue(result.unassigned.isEmpty)
    }

    func testKeysSharingAFolderKeyDoNotTrap() {
        let existing = [
            "Example": EnvironmentProfiles(jamfPro: "Example"),
            "example": EnvironmentProfiles(jamfPro: "example"),
        ]
        let result = EnvironmentProposal.propose(
            profiles: [profile("Other", auth: "oauth2", url: "o.jamfcloud.com")],
            learnedJamfProURLs: [:], existingWorkspaces: existing)
        XCTAssertEqual(result.environments.map(\.workspace), ["Other"])
    }

    func testFirstOfTwoTwinsByNameWinsAndTheOtherStaysAnEnvironment() {
        let profiles = [
            profile("B-Twin", auth: "oauth2", url: "example.jamfcloud.com"),
            profile("A-Twin", auth: "oauth2", url: "example.jamfcloud.com"),
            gw("API"),
        ]
        let result = EnvironmentProposal.propose(
            profiles: profiles, learnedJamfProURLs: ["API": "example.jamfcloud.com"],
            existingWorkspaces: [:])
        XCTAssertEqual(result.environments.map(\.workspace), ["A-Twin", "B-Twin"])
        XCTAssertEqual(result.environments.map(\.platform), ["API", nil])
    }

    func testPlatformProfileWithoutALearnedURLIsStandalone() {
        let result = EnvironmentProposal.propose(
            profiles: [profile("Example", auth: "oauth2", url: "example.jamfcloud.com"),
                       gw("API")],
            learnedJamfProURLs: [:], existingWorkspaces: [:])
        XCTAssertEqual(result.environments.map(\.workspace), ["API", "Example"])
        XCTAssertEqual(result.environments.map(\.platform), [nil, nil])
    }

    func testProtectIsSuggestedOnlyToWorkspacesWithNoProtectSlot() {
        let existing = [
            "Alpha": EnvironmentProfiles(jamfPro: "Alpha"),
            "Beta": EnvironmentProfiles(jamfPro: "Beta", protect: "Old-Protect"),
        ]
        let result = EnvironmentProposal.propose(
            profiles: [profile("Alpha-Protect", auth: "oauth2", product: .protect),
                       profile("Beta-Protect", auth: "oauth2", product: .protect)],
            learnedJamfProURLs: [:], existingWorkspaces: existing)
        let suggested = Dictionary(
            uniqueKeysWithValues: result.protectChoices.map { ($0.profile, $0.suggested) })
        XCTAssertEqual(suggested["Alpha-Protect"], "Alpha")
        XCTAssertEqual(suggested["Beta-Protect"] ?? nil, nil)
    }

    func testUnusablePlatformProfileIsUnassignedAndNeverPaired() {
        let result = EnvironmentProposal.propose(
            profiles: Array(four().prefix(2)), learnedJamfProURLs: exampleURLs,
            existingWorkspaces: [:], unusable: ["Example-API": "Bad name."])
        XCTAssertEqual(result.unassigned["Example-API"], "Bad name.")
        XCTAssertEqual(result.environments.map(\.workspace), ["Example"])
        XCTAssertNil(result.environments.first?.platform)
    }
}
