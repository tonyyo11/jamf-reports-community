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
            installedVersion: "1.33.0", skipExpensive: skipExpensive, authMethod: auth,
            tenantLevel: tenantLevel, hasTenantID: hasTenantID, collectSkip: skip))
    }

    /// The one other source is SOFA, which a School collect fetches for OS currency.
    func testASchoolWorkspaceListsSchoolCommandsAndSOFAOnly() {
        let school = plan(.jamfSchool)
        XCTAssertEqual(school.sources.map(\.kind),
                       ReportEngine.schoolCommandMatrix(profile: "prod").map(\.kind) + ["sofa"])
        XCTAssertEqual(plan(.jamfSchool, skip: ["sofa"]).sources.last?.skipReason,
                       "listed in jamf_cli.collect_skip")
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
        XCTAssertEqual(Set(skipped), ReportEngine.environmentLevelKinds)
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
        XCTAssertEqual(SourcesView.groupSummary(sources, cachedAt: [:]), "0 run · 4 skipped")
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

    func testTheSourcesPlanShowsThePlatformProfileInTheCommand() {
        var inputs = CollectSourcesPlan.Inputs(product: .jamfPro, profile: "ws")
        inputs.platformProfile = "ws-API"
        let rules = CollectSourcesPlan.build(inputs).sources.first { $0.kind == "compliance-rules" }
        XCTAssertNil(rules?.skipReason)
    }
}
