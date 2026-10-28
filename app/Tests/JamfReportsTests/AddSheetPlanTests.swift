import XCTest
@testable import JamfReports

final class AddSheetPlanTests: XCTestCase {
    private func profile(
        _ name: String, _ product: JamfCLIProduct = .pro, level: PlatformScopeLevel? = nil
    ) -> JamfCLIProfile {
        JamfCLIProfile(name: name, url: "https://\(name).example.com", schedules: 0,
                       status: .idle, product: product, platformLevel: level)
    }

    private func unassigned(
        _ profiles: [JamfCLIProfile], workspaces: [String] = [], paired: Set<String> = [],
        unusable: [String: String] = [:]
    ) -> [AddSheetPlan.UnassignedProfile] {
        AddSheetPlan.unassigned(
            profiles: profiles, workspaces: workspaces, paired: paired, unusable: unusable)
    }

    // MARK: - Add while setup is running

    func testAddIsRefusedOnlyWhileASetupHoldsRegisteredWork() {
        XCTAssertNil(AddSheetPlan.addRefusal(onboardingRunHasWork: false))
        let refusal = AddSheetPlan.addRefusal(onboardingRunHasWork: true)
        XCTAssertTrue(refusal?.contains("Finish the setup in progress") == true)
    }

    @MainActor
    func testARunHasWorkOnceItRegisteredAProfileOrCreatedAFolder() {
        let flow = OnboardingFlow()
        XCTAssertFalse(flow.startOverRemovesSomething)
        flow.createdProfiles.append("alpha")
        XCTAssertTrue(flow.startOverRemovesSomething)
    }

    // MARK: - Adoption outcome

    func testAFailedFirstCollectIsReportedNotCalledSetUp() {
        let failed = AddSheetPlan.adoptionOutcome(
            name: "alpha", status: .failed("collect exited 3"))
        XCTAssertNil(failed.message)
        XCTAssertEqual(failed.error, "alpha's workspace was created, but its first collect "
            + "failed (collect exited 3). Fix the cause, then collect from that workspace.")

        let done = AddSheetPlan.adoptionOutcome(name: "alpha", status: .done)
        XCTAssertEqual(done.message, "alpha is set up. Switch to it from the workspace menu.")
        XCTAssertNil(done.error)
    }

    // MARK: - Unassigned profiles

    func testProfilesWithAWorkspaceOrNamedByOneAreLeftOut() {
        let rows = unassigned(
            [profile("prod"), profile("prod-protect", .protect), profile("lab"),
             profile("school", .school), profile("old-school", .school)],
            workspaces: ["prod"], paired: ["prod-protect", "old-school"])
        XCTAssertEqual(rows.map(\.name), ["lab", "school"])
    }

    func testAWorkspaceSpelledInAnotherCaseStillCounts() {
        XCTAssertEqual(unassigned([profile("Prod")], workspaces: ["prod"]), [])
    }

    func testEachProductGetsItsUse() {
        let rows = unassigned([
            profile("pro"), profile("unknown", .unknown), profile("school", .school),
            profile("protect", .protect), profile("cloud", .securityCloud),
        ])
        XCTAssertEqual(rows.map(\.use), [
            .newWorkspace, .newWorkspace, .newWorkspace, .addToCurrent,
            .unavailable(AddSheetPlan.securityCloudReason),
        ])
    }

    func testOrganizationLevelAndUnusableProfilesSayWhy() {
        let rows = unassigned(
            [profile("org", level: .organization), profile("env", level: .environment),
             profile("bad name")],
            unusable: ["bad name": "Rename it."])
        XCTAssertEqual(rows.map(\.use), [
            .unavailable(PlatformScopeLevel.organizationLevelReason), .newWorkspace,
            .unavailable("Rename it."),
        ])
    }

    func testRowsKeepJamfCLIsOrderAndFacts() {
        let rows = unassigned([profile("b", .school), profile("a")])
        XCTAssertEqual(rows.map(\.name), ["b", "a"])
        XCTAssertEqual(rows.first?.product, .school)
        XCTAssertEqual(rows.first?.url, "https://b.example.com")
    }

    // MARK: - Preselection

    private func preselection(
        _ profiles: [JamfCLIProfile], acceptsProtect: Bool = true,
        requested: AddSheetPlan.NewProduct? = nil
    ) -> AddSheetPlan.Choice {
        AddSheetPlan.preselection(
            unassigned: unassigned(profiles), currentAcceptsProtect: acceptsProtect,
            requested: requested)
    }

    func testAnMDMProfileOpensNewWorkspace() {
        XCTAssertEqual(preselection([profile("lab")]), .newWorkspace)
        XCTAssertEqual(preselection([profile("school", .school)]), .newWorkspace)
    }

    func testAProtectProfileOpensAddToCurrent() {
        XCTAssertEqual(preselection([profile("p", .protect)]), .addToCurrent)
    }

    func testAnMDMProfileWinsOverAProtectProfile() {
        XCTAssertEqual(preselection([profile("p", .protect), profile("lab")]), .newWorkspace)
    }

    func testProtectDoesNotOpenAddToCurrentWhenTheWorkspaceCannotTakeIt() {
        XCTAssertEqual(preselection([profile("p", .protect)], acceptsProtect: false),
                       .newWorkspace)
    }

    func testARequestedProductOpensNewWorkspace() {
        XCTAssertEqual(preselection([profile("p", .protect)], requested: .jamfSchool),
                       .newWorkspace)
    }

    func testNothingUnassignedOrOnlyUnavailableOpensNewWorkspace() {
        XCTAssertEqual(preselection([]), .newWorkspace)
        XCTAssertEqual(preselection([profile("cloud", .securityCloud)]), .newWorkspace)
    }

    // MARK: - Rows and Re-check

    private func discovery(
        _ profiles: [JamfCLIProfile], workspaces: [String] = [], currentProtect: String? = nil
    ) -> AddSheetDiscovery {
        AddSheetDiscovery(
            unassigned: unassigned(profiles, workspaces: workspaces),
            currentProtect: currentProtect)
    }

    private func listing(
        _ found: AddSheetDiscovery?, _ choice: AddSheetPlan.Choice = .newWorkspace,
        takesProtect: Bool = true, demo: Bool = false, checking: Bool = false
    ) -> AddSheetPlan.Listing {
        AddSheetPlan.listing(
            demoMode: demo, isChecking: checking, choice: choice, takesProtect: takesProtect,
            discovery: found)
    }

    private func names(_ listing: AddSheetPlan.Listing) -> [String] {
        if case .rows(let rows) = listing { return rows.map(\.name) }
        return []
    }

    func testNewWorkspaceListsEveryoneButProtectAndKeepsRefusedRowsWithTheirReason() {
        let found = discovery([
            profile("lab"), profile("p", .protect), profile("cloud", .securityCloud),
            profile("org", level: .organization),
        ])
        guard case .rows(let rows) = listing(found) else { return XCTFail("no rows") }
        XCTAssertEqual(rows.map(\.name), ["lab", "cloud", "org"])
        XCTAssertEqual(rows.map(\.use), [
            .newWorkspace, .unavailable(AddSheetPlan.securityCloudReason),
            .unavailable(PlatformScopeLevel.organizationLevelReason),
        ])
    }

    func testAddToCurrentListsOnlyProtectLogins() {
        let found = discovery([profile("lab"), profile("p", .protect)])
        XCTAssertEqual(names(listing(found, .addToCurrent)), ["p"])
    }

    func testAddToCurrentSaysWhyThereIsNothingToAdd() {
        XCTAssertEqual(listing(discovery([profile("lab")]), .addToCurrent),
                       .empty("No Jamf Protect profile in jamf-cli is free to add. Connect new "
                           + "above."))
        XCTAssertEqual(
            listing(discovery([profile("p", .protect)], currentProtect: "other"), .addToCurrent),
            .empty("This workspace already has Jamf Protect."))
    }

    func testAChoiceOfAddToCurrentIsIgnoredWhenTheWorkspaceCannotTakeProtect() {
        let found = discovery([profile("lab"), profile("p", .protect)])
        XCTAssertEqual(names(listing(found, .addToCurrent, takesProtect: false)), ["lab"])
    }

    func testListingStatesFollowDemoReadingAndUnreadable() {
        XCTAssertEqual(listing(discovery([profile("lab")]), demo: true), .demo)
        XCTAssertEqual(listing(nil, checking: true), .reading)
        let unreadable = AddSheetDiscovery(unassigned: nil, currentProtect: nil)
        XCTAssertEqual(listing(unreadable, checking: true), .unreadable)
        guard case .empty(let text) = listing(discovery([])) else { return XCTFail("not empty") }
        XCTAssertTrue(text.hasPrefix("Every jamf-cli profile already has a workspace."))
    }

    func testRecheckPreselectsAgainOnlyWhileTheChoiceIsUntouched() {
        let found = discovery([profile("p", .protect)])
        XCTAssertEqual(AddSheetPlan.recheck(
            found: found, takesProtect: true, choice: .newWorkspace, choiceTouched: false,
            requested: nil), .addToCurrent)
        XCTAssertEqual(AddSheetPlan.recheck(
            found: found, takesProtect: true, choice: .newWorkspace, choiceTouched: true,
            requested: nil), .newWorkspace)
        XCTAssertEqual(AddSheetPlan.recheck(
            found: found, takesProtect: true, choice: .newWorkspace, choiceTouched: false,
            requested: .jamfPro), .newWorkspace)
    }

    func testRecheckShowsAProfileAddedAfterLaunch() {
        let before = discovery([profile("lab")])
        let after = discovery([profile("lab"), profile("made-in-terminal")])
        XCTAssertEqual(names(listing(before)), ["lab"])
        XCTAssertEqual(names(listing(after)), ["lab", "made-in-terminal"])
        XCTAssertEqual(AddSheetPlan.recheck(
            found: after, takesProtect: true, choice: .addToCurrent, choiceTouched: false,
            requested: nil), .newWorkspace)
    }

    func testTheStepFallsBackToNewWorkspaceWhenTheWorkspaceCannotTakeProtect() {
        XCTAssertEqual(AddSheetPlan.step(choice: .addToCurrent, takesProtect: true), .addToCurrent)
        XCTAssertEqual(AddSheetPlan.step(choice: .addToCurrent, takesProtect: false),
                       .newWorkspace)
        XCTAssertEqual(AddSheetPlan.step(choice: .newWorkspace, takesProtect: true),
                       .newWorkspace)
        XCTAssertEqual(AddSheetPlan.step(choice: .newWorkspace, takesProtect: false),
                       .newWorkspace)
    }

    func testDemoModeOutranksReadingAndUnreadable() {
        let unreadable = AddSheetDiscovery(unassigned: nil, currentProtect: nil)
        XCTAssertEqual(listing(nil, demo: true, checking: true), .demo)
        XCTAssertEqual(listing(unreadable, demo: true), .demo)
    }

    func testRecheckWithAWorkspaceThatCannotTakeProtectOpensNewWorkspace() {
        let found = discovery([profile("p", .protect)])
        XCTAssertEqual(AddSheetPlan.recheck(
            found: found, takesProtect: false, choice: .addToCurrent, choiceTouched: false,
            requested: nil), .newWorkspace)
    }

    func testRecheckOfUnreadableProfilesOpensNewWorkspace() {
        let unreadable = AddSheetDiscovery(unassigned: nil, currentProtect: nil)
        XCTAssertEqual(AddSheetPlan.recheck(
            found: unreadable, takesProtect: true, choice: .addToCurrent, choiceTouched: false,
            requested: nil), .newWorkspace)
    }

    func testRecheckDropsAProfileThatGainedAWorkspace() {
        let all = [profile("lab"), profile("p", .protect)]
        let before = discovery(all)
        let after = discovery(all, workspaces: ["lab"])
        XCTAssertEqual(names(listing(before)), ["lab"])
        XCTAssertEqual(listing(after), .empty("Every jamf-cli profile already has a workspace. "
            + "Profiles made in Terminal appear here after Re-check."))
        XCTAssertEqual(AddSheetPlan.recheck(
            found: after, takesProtect: true, choice: .newWorkspace, choiceTouched: false,
            requested: nil), .addToCurrent)
    }

    // MARK: - Which workspace takes Jamf Protect

    /// A Jamf School workspace takes Protect as a Jamf Pro one does (2.11); a profile with no
    /// workspace on disk, and demo mode, do not.
    func testAJamfProOrJamfSchoolWorkspaceTakesProtect() {
        let initialized = ["prod", "campus"]
        XCTAssertTrue(AddSheetPlan.currentTakesProtect(
            demoMode: false, current: "campus", initialized: initialized))
        XCTAssertTrue(AddSheetPlan.currentTakesProtect(
            demoMode: false, current: "prod", initialized: initialized))
        XCTAssertFalse(AddSheetPlan.currentTakesProtect(
            demoMode: false, current: "new", initialized: initialized))
        XCTAssertFalse(AddSheetPlan.currentTakesProtect(
            demoMode: true, current: "campus", initialized: initialized))
    }

    /// Add to current names the Protect login in the School workspace's config.yaml, which
    /// keeps routing to School and now runs Protect after it.
    @MainActor func testAddingProtectToASchoolWorkspaceWritesItsConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-add-school-protect-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("campus", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        try Data("school_cli:\n  enabled: true\n".utf8).write(to: configURL)
        XCTAssertNil(AddSheetDiscovery.load(currentWorkspace: "campus").currentProtect)

        try OnboardingFlow.writeProtectConfig(profileSlug: "campus", protectProfileName: "prot")
        let detected = ProfileProductType.detect(
            from: try ConfigLoader.load(from: configURL), profile: "campus")
        XCTAssertEqual(detected.type, .jamfSchool)
        XCTAssertTrue(detected.runsProtect)
        XCTAssertEqual(AddSheetDiscovery.load(currentWorkspace: "campus").currentProtect, "prot")
    }

    // MARK: - Same Jamf Pro as a workspace

    private func login(_ name: String, auth: String, url: String) -> JamfCLIProfile {
        JamfCLIProfile(name: name, url: url, schedules: 0, status: .idle, authMethod: auth,
                       product: .pro)
    }

    private let gateway = "https://us.api.jamfcloud.com"

    func testAnOAuth2ProfileBesideAPlatformWorkspaceIsNoted() {
        let notes = AddSheetPlan.twinNotes(
            unassigned: [login("direct", auth: "oauth2", url: "https://acme.jamfcloud.com")],
            workspaces: [login("gw", auth: "platform", url: gateway)],
            learn: { $0 == "gw" ? "https://ACME.jamfcloud.com" : nil })
        XCTAssertEqual(notes.keys.sorted(), ["direct"])
        XCTAssertEqual(notes["direct"], "Same Jamf Pro as gw, which has a workspace. A second "
            + "workspace collects the fleet twice, so history is split and fleet totals count "
            + "it twice. Set it up only to collect it anyway.")
    }

    func testAPlatformProfileBesideAnOAuth2WorkspaceIsNoted() {
        let notes = AddSheetPlan.twinNotes(
            unassigned: [login("gw", auth: "platform", url: gateway)],
            workspaces: [login("direct", auth: "oauth2", url: "acme.jamfcloud.com")],
            learn: { _ in "https://acme.jamfcloud.com" })
        XCTAssertTrue(notes["gw"]?.hasPrefix("Same Jamf Pro as direct,") == true)
    }

    func testAFailedProbeAnotherHostOrNoWorkspaceNotesNothing() {
        let direct = login("direct", auth: "oauth2", url: "https://acme.jamfcloud.com")
        let gw = login("gw", auth: "platform", url: gateway)
        XCTAssertEqual(AddSheetPlan.twinNotes(
            unassigned: [direct], workspaces: [gw], learn: { _ in nil }), [:])
        XCTAssertEqual(AddSheetPlan.twinNotes(
            unassigned: [direct], workspaces: [gw],
            learn: { _ in "https://other.jamfcloud.com" }), [:])
        XCTAssertEqual(AddSheetPlan.twinNotes(
            unassigned: [direct, gw], workspaces: [],
            learn: { _ in "https://acme.jamfcloud.com" }), [:])
    }

    func testEachProfileIsProbedOnce() {
        let direct = login("direct", auth: "oauth2", url: "https://acme.jamfcloud.com")
        let other = login("other", auth: "oauth2", url: "https://b.jamfcloud.com")
        let gw = login("gw", auth: "platform", url: gateway)
        let gw2 = login("gw2", auth: "platform", url: gateway)
        var asked: [String] = []
        _ = AddSheetPlan.twinNotes(
            unassigned: [direct, other, gw2], workspaces: [gw, direct],
            learn: { asked.append($0); return nil })
        XCTAssertEqual(asked.sorted(), asked.sorted().reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }, "a profile was probed twice: \(asked)")
        XCTAssertFalse(asked.isEmpty)
    }
}
