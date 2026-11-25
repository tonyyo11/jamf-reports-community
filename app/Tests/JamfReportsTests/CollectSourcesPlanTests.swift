import XCTest
@testable import JamfReports

/// Data Sources lists what a full collect runs for the workspace's product, from the collects'
/// own lists. Before 2.10 it was one fixed list of Jamf Pro commands plus `protect overview` on
/// every workspace, School and Platform API included.
final class CollectSourcesPlanTests: XCTestCase {
    private typealias Plan = CollectSourcesPlan

    private func plan(
        _ product: ProfileProductType = .jamfPro, auth: String? = "oauth2",
        tenantLevel: Bool = false, hasTenantID: Bool = false, protect: String? = nil,
        skip: Set<String> = [],
        skipExpensive: Bool = false
    ) -> Plan {
        Plan.build(.init(
            product: product, profile: "prod", protectProfile: protect,
            installedVersion: "1.38.0", skipExpensive: skipExpensive, authMethod: auth,
            tenantLevel: tenantLevel, hasTenantID: hasTenantID, collectSkipList: skip.sorted()))
    }

    func testServerHealthKindsAreListedAndExplainedWhenRefusedOrUnsupported() {
        func reason(_ edit: (inout Plan.Inputs) -> Void) -> String?? {
            var inputs = Plan.Inputs(product: .jamfPro, profile: "prod")
            inputs.installedVersion = "1.38.0"
            edit(&inputs)
            return Plan.build(inputs).sources.first { $0.kind == "certificate-authority" }
                .map(\.skipReason)
        }
        XCTAssertEqual(reason { _ in }, .some(nil), "listed and collected")
        XCTAssertEqual(reason { $0.installedVersion = "1.37.0" }, "needs jamf-cli 1.38.0 or later")
        XCTAssertEqual(reason { $0.workspaceAuthIsPlatform = true },
                       "not collected through a Platform API profile yet")
        XCTAssertEqual(
            reason {
                $0.advisory = ["certificate-authority": FailureCause(
                    kind: .missingPermission, names: [], hint: nil, exitCode: 5)]
            }, "not permitted for this login; checked again weekly")
        XCTAssertEqual(
            reason {
                $0.advisory = ["certificate-authority": FailureCause(
                    kind: .notConfiguredOnServer, names: [], hint: nil, exitCode: 4)]
            }, "not set up on this Jamf Pro server; checked again weekly")
    }

    func testDeploymentSourcesAreSkippedOnAnOldOrUnknownJamfCLI() {
        func reasons(_ version: String?) -> [String?] {
            var inputs = Plan.Inputs(product: .jamfPro, profile: "prod")
            inputs.installedVersion = version
            let sources = Plan.build(inputs).sources
            return ["app-installers-deployments", "patch-policies"].map { kind in
                guard let source = sources.first(where: { $0.kind == kind }) else {
                    return "not listed"
                }
                return source.skipReason
            }
        }
        XCTAssertEqual(reasons("1.35.0"), [nil, nil])
        XCTAssertEqual(reasons("1.34.9"), Array(repeating:
            "needs jamf-cli 1.35.0 or later (installed: 1.34.9)", count: 2))
        XCTAssertEqual(reasons(nil), Array(repeating:
            "needs jamf-cli 1.35.0 or later (installed: unknown)", count: 2))
    }

    /// The other sources are SOFA, which a School collect fetches for OS currency, and the
    /// weekly per-device scan.
    func testASchoolWorkspaceListsSchoolCommandsAndSOFAOnly() {
        let school = plan(.jamfSchool)
        XCTAssertEqual(school.sources.map(\.kind),
                       ReportEngine.schoolCommandMatrix(profile: "prod").map(\.kind)
                           + ["sofa", ReportEngine.schoolDeviceDetailKind])
        XCTAssertEqual(plan(.jamfSchool, skip: ["sofa"]).sources.first { $0.kind == "sofa" }?
            .skipReason, "listed in jamf_cli.collect_skip")
        XCTAssertEqual(school.sources.filter { $0.product == .platformAPI }.map(\.kind),
                       [ReportEngine.schoolBlueprintsKind])
        XCTAssertTrue(school.sources.filter { $0.product != .platformAPI && $0.kind != "sofa" }
            .allSatisfy { $0.product == .school })
        XCTAssertTrue(school.sources.contains { $0.command == "school devices list" })
        XCTAssertFalse(school.sources.contains { $0.command.hasPrefix("pro ") })
    }

    /// Protect follows a School collect (2.11), so a connected Protect is listed after School.
    func testASchoolWorkspaceWithProtectListsTheProtectCommands() {
        let school = plan(.jamfSchool, protect: "prod-protect")
        XCTAssertEqual(
            school.sources(for: .protect).map(\.kind),
            ReportEngine.protectCommandMatrix(profile: "prod-protect").map(\.kind))
        XCTAssertEqual(school.sources.prefix(ReportEngine.schoolCommandMatrix(profile: "prod")
            .count).map(\.product).contains(.protect), false)
    }

    func testSchoolBlueprintsAreSkippedOnlyWhenTheProfileLacksPlatformFields() {
        func reason(auth: String?, tenant: Bool) -> String?? {
            plan(.jamfSchool, auth: auth, hasTenantID: tenant).sources
                .first { $0.kind == ReportEngine.schoolBlueprintsKind }?.skipReason
        }
        XCTAssertEqual(
            reason(auth: "apikey", tenant: false) ?? nil,
            "the Jamf School profile has no Platform API fields (Data Sources › Add Platform API)")
        XCTAssertEqual(reason(auth: "apikey", tenant: true), .some(nil))
        let both = plan(.jamfSchool, auth: "apikey", tenantLevel: false, hasTenantID: true)
        XCTAssertNil(both.sources.first { $0.kind == ReportEngine.schoolBlueprintsKind }?.skipReason,
                     "a tenant-id with an environment-id is still a Platform profile for School")
        XCTAssertEqual(reason(auth: nil, tenant: false), .some(nil), "unresolved collects")
        let school = plan(.jamfSchool, auth: "apikey")
        XCTAssertTrue(school.sources.filter { $0.product == .school }
            .allSatisfy { $0.skipReason == nil })
    }

    func testTheJamfProListIsTheCollectMatrixPlusTheScanAndTheLateSources() {
        let pro = plan()
        let matrix = ReportEngine.collectCommandMatrix(profile: "prod", staleDays: 30)
        XCTAssertEqual(
            Array(pro.sources.map(\.kind).prefix(matrix.count)), matrix.map(\.kind),
            "the matrix as collect runs it, in order")
        for kind in [ReportEngine.ddmDeviceStatusKind, ReportEngine.mdmCommandHealthKind,
                     ReportEngine.patchReleaseDatesKind, ReportEngine.sofaKind] {
            XCTAssertTrue(pro.sources.contains { $0.kind == kind }, kind)
        }
        XCTAssertTrue(pro.sources(for: .protect).isEmpty, "no Protect unless connected")
    }

    func testPlatformOnlyReportsAreSkippedWithTheReasonOnAnOAuthProfile() {
        let platform = plan(auth: "oauth2").sources(for: .platformAPI)
        XCTAssertEqual(Set(platform.map(\.kind)), ReportEngine.platformOnlyKinds)
        XCTAssertTrue(platform.allSatisfy {
            $0.skipReason?.contains("requires a Platform API profile") == true
        })
        XCTAssertTrue(plan(auth: "platform").sources(for: .platformAPI)
            .allSatisfy { $0.skipReason == nil })
        XCTAssertTrue(plan(auth: nil).sources(for: .platformAPI)
            .allSatisfy { $0.skipReason == nil }, "an unknown method skips nothing, as collect")
    }

    func testATenantLevelProfileSkipsTheEnvironmentLevelReports() {
        let skipped = plan(auth: "platform", tenantLevel: true).sources
            .filter { $0.skipReason != nil }.map(\.kind)
        // The admin-hygiene sources are skipped too: they are off until opted in.
        XCTAssertEqual(
            Set(skipped),
            ReportEngine.environmentLevelKinds.union(ReportEngine.serverHealthOptInKinds))
    }

    func testProtectIsListedOnlyWhenConnected() {
        let protect = plan(protect: "prod-protect").sources(for: .protect)
        XCTAssertEqual(protect.map(\.kind),
                       ReportEngine.protectCommandMatrix(profile: "x").map(\.kind))
        XCTAssertEqual(protect.first?.command, "protect overview")
    }

    func testProtectIsSkippedWithTheReasonWhenTheProfileIsAnotherProduct() {
        let reason = "'prod-protect' is a Jamf Pro profile, not a Jamf Protect profile"
        let protect = Plan.build(.init(
            product: .jamfPro, profile: "prod", protectProfile: "prod-protect",
            protectRefusal: reason)).sources(for: .protect)
        XCTAssertFalse(protect.isEmpty)
        XCTAssertTrue(protect.allSatisfy { $0.skipReason == reason })
        XCTAssertTrue(plan(protect: "prod-protect").sources(for: .protect)
            .allSatisfy { $0.skipReason == nil })
    }

    func testCollectSkipAndTheSettingsSwitchShowAsSkipped() {
        let skipped = plan(skip: ["sofa"]).sources.first { $0.kind == ReportEngine.sofaKind }
        XCTAssertEqual(skipped?.skipReason, "listed in jamf_cli.collect_skip")

        let off = plan(skipExpensive: true).sources
        let scan = off.first { $0.kind == ReportEngine.mdmCommandHealthKind }
        XCTAssertEqual(scan?.skipReason, "Settings: Skip expensive collections")
        XCTAssertTrue(off.filter { ReportEngine.expensivePerDeviceKinds.contains($0.kind) }
            .allSatisfy { $0.skipReason != nil })
    }

    func testCommandsReadAsTyped() {
        XCTAssertEqual(
            Plan.command(["-p", "prod", "pro", "report", "security", "--output", "json"]),
            "pro report security")
    }

    @MainActor
    func testTheGroupLineAndRowStatusSayWhatRunsAndWhy() {
        let sources = plan().sources(for: .platformAPI)
        XCTAssertEqual(SourcesView.groupSummary(sources, cachedAt: [:]), "0 runs · 4 skipped")
        let pro = plan().sources(for: .jamfPro)
        let one = [pro[0].kind: Date(timeIntervalSince1970: 0)]
        XCTAssertTrue(SourcesView.groupSummary(pro, cachedAt: one).contains("1 cached"))
        XCTAssertEqual(SourcesView.sourceStatus(pro[1], cachedAt: nil), "not cached")
        XCTAssertTrue(SourcesView.sourceStatus(sources[0], cachedAt: nil).hasPrefix("skipped: "))
    }

    func testTheSourcesPlanNamesTheMissingPlatformProfile() {
        var inputs = CollectSourcesPlan.Inputs(product: .jamfPro, profile: "ws")
        inputs.platformUnavailable = EnvironmentProfiles.noPlatformReason
        let rules = CollectSourcesPlan.build(inputs).sources.first { $0.kind == "compliance-rules" }
        XCTAssertEqual(rules?.skipReason, EnvironmentProfiles.noPlatformReason)
    }

    private func resolved(_ method: String) -> ProfileAuthMethod.Resolved {
        ProfileAuthMethod.Resolved(authMethod: method, isTenantLevel: false)
    }

    func testPlatformInputsForEachRoute() {
        var asked: [String] = []
        let own = resolved("oauth2")
        let resolve: (String) -> ProfileAuthMethod.Resolved? = {
            asked.append($0)
            return self.resolved("platform")
        }
        let none = EnvironmentProfiles.platformInputs(
            route: .workspaceProfile, workspace: "ws", workspaceAuth: own, resolve: resolve)
        XCTAssertEqual(none.auth?.authMethod, "oauth2")
        XCTAssertNil(none.unavailable)
        let other = EnvironmentProfiles.platformInputs(
            route: .profile("ws-API"), workspace: "ws", workspaceAuth: own, resolve: resolve)
        XCTAssertEqual(other.auth?.authMethod, "platform")
        XCTAssertEqual(asked, ["ws-API"])
        let same = EnvironmentProfiles.platformInputs(
            route: .profile("ws"), workspace: "ws", workspaceAuth: own, resolve: resolve)
        XCTAssertEqual(same.auth?.authMethod, "oauth2")
        XCTAssertEqual(asked, ["ws-API"])
        let orgLevel = EnvironmentProfiles.platformInputs(
            route: .profile("ws-ORG"), workspace: "ws", workspaceAuth: own,
            resolve: { _ in
                ProfileAuthMethod.Resolved(
                    authMethod: "platform", isTenantLevel: false, isOrganizationLevel: true)
            })
        XCTAssertEqual(orgLevel.auth?.authMethod, "oauth2")
        XCTAssertEqual(orgLevel.unavailable, EnvironmentProfiles.organizationLevelPlatformReason)
        let gone = EnvironmentProfiles.platformInputs(
            route: .unavailable("why"), workspace: "ws", workspaceAuth: own, resolve: resolve)
        XCTAssertEqual(gone.auth?.authMethod, "oauth2")
        XCTAssertEqual(gone.unavailable, "why")
        XCTAssertEqual(asked, ["ws-API"])
    }

    func testASchoolWorkspaceIgnoresThePlatformSlot() {
        let own = resolved("apikey")
        let routed = CollectSourcesPlan.routedAuth(
            product: .jamfSchool, route: .profile("ws-API"), workspace: "ws",
            workspaceAuth: own,
            resolve: { _ in XCTFail("School never resolves the slot"); return nil })
        XCTAssertEqual(routed.auth?.authMethod, "apikey")
        XCTAssertNil(routed.unavailable)
    }

    func testAdminHygieneRowsAreOffUntilOptedInAndCarryTheirSwitch() {
        func state(_ kind: String, optIn: [String] = [], drifted: Bool = false)
            -> (reason: String?, control: Plan.SourceSwitch, changed: Bool) {
            var inputs = Plan.Inputs(product: .jamfPro, profile: "prod")
            inputs.installedVersion = "1.38.0"
            inputs.optInList = optIn
            inputs.optInDrifted = drifted
            // The file lists every opt-in kind while a peer's addition waits.
            inputs.optInInFile = drifted ? Array(ReportEngine.serverHealthOptInKinds) : nil
            let built = Plan.build(inputs)
            let source = built.sources.first { $0.kind == kind }!
            let switchState = built.switchState(for: source)
            return (source.skipReason, switchState.control, switchState.changedOnAnotherMac)
        }
        for kind in ReportEngine.serverHealthOptInKinds.sorted() {
            let off = state(kind)
            XCTAssertEqual(off.reason, "off until turned on (jamf_cli.collect_opt_in)", kind)
            XCTAssertEqual(off.control, .optIn(on: false), kind)
            let on = state(kind, optIn: [kind])
            XCTAssertNil(on.reason, kind)
            XCTAssertEqual(on.control, .optIn(on: true), kind)
            XCTAssertTrue(state(kind, drifted: true).changed, "a peer's addition waits")
            XCTAssertFalse(state(kind, optIn: [kind], drifted: true).changed, "confirmed here")
        }
        XCTAssertFalse(state("certificate-authority", drifted: true).changed)
        XCTAssertEqual(state("certificate-authority").control, .on)
        var drifted = Plan.Inputs(product: .jamfPro, profile: "prod")
        drifted.optInDrifted = true
        XCTAssertTrue(Plan.build(drifted).changedOnAnotherMac, "the banner still says so")
        XCTAssertFalse(Plan.build(drifted).holdsSkipSwitches,
                       "an opt-in addition leaves the collect_skip switches usable")
        drifted.collectSkipInFile = ["sofa"]
        XCTAssertTrue(Plan.build(drifted).holdsSkipSwitches)
    }

    func testOnlyTheOptInKindThePeerAddedIsMarkedChanged() {
        var inputs = Plan.Inputs(product: .jamfPro, profile: "prod")
        inputs.installedVersion = "1.38.0"
        inputs.optInDrifted = true
        inputs.optInInFile = ["admin-accounts"]
        let built = Plan.build(inputs)
        func changed(_ kind: String) -> Bool {
            built.switchState(for: built.sources.first { $0.kind == kind }!).changedOnAnotherMac
        }
        XCTAssertTrue(changed("admin-accounts"))
        XCTAssertFalse(changed("api-integrations"))
        XCTAssertFalse(changed("laps-pending-rotations"))
    }

    func testAnUnsupportedJamfCLIIsTheReasonShownEvenForAnOptInSource() {
        var inputs = Plan.Inputs(product: .jamfPro, profile: "prod")
        inputs.installedVersion = "1.37.0"
        let built = Plan.build(inputs)
        let source = built.sources.first { $0.kind == "admin-accounts" }!
        XCTAssertEqual(source.skipReason, "needs jamf-cli 1.38.0 or later")
        XCTAssertEqual(built.switchState(for: source).control, .hidden,
                       "a source that cannot run here has no switch to write a dead setting")
        inputs.installedVersion = "1.38.0"
        inputs.workspaceAuthIsPlatform = true
        let gateway = Plan.build(inputs)
        XCTAssertEqual(gateway.switchState(
            for: gateway.sources.first { $0.kind == "admin-accounts" }!).control, .hidden)
    }
}
