import XCTest
@testable import JamfReports

/// The deployment-health groups of the daily summary: written only for a kind that landed,
/// with the levels and floor they were judged at, and kept per group by a later run.
@MainActor
final class DeploymentSummaryTests: XCTestCase {
    private let ws = "depsum"
    private let proFile = "profiles:\n  jamf_pro: depsum\n"

    private func makeRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepSummary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
    }

    nonisolated private static var day: String { SummaryJSONParser.dateFormatter.string(from: .testNoon) }
    private func dataDir() throws -> URL { try WorkspacePaths.dataDir(for: ws) }
    private func summaryFile() throws -> URL {
        try WorkspacePaths.summariesDir(for: ws).appendingPathComponent("summary_\(Self.day).json")
    }
    private func summary() throws -> DailySummary {
        try SummaryJSONParser.decode(Data(contentsOf: summaryFile()))
    }

    nonisolated private static func base(_ date: String = day) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 5, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli")
    }

    private func writeMDMSummary() throws {
        let dir = try WorkspacePaths.summariesDir(for: ws)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ReportEngine.writeSummaryFile(Self.base(), to: try summaryFile(), onLine: nil)
    }

    private func save(_ text: String, _ kind: String) throws {
        let folder = try dataDir().appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        try Data(text.utf8).write(to: folder.appendingPathComponent(
            "\(kind)_\(formatter.string(from: .testNoon)).json"))
    }

    /// One patch policy per (failed, inScope); the rest of the scope is completed.
    private func policies(_ rows: [(failed: Int, inScope: Int)]) throws {
        let items = rows.enumerated().map { index, row in
            #"{"id":"\#(index)","policyEnabled":true,"failed":\#(row.failed),"#
                + #""completed":\#(row.inScope - row.failed),"deferred":0,"pending":0}"#
        }
        try save("[\(items.joined(separator: ","))]", "patch-policies")
    }

    private func finalize(
        landed: Set<String>, levels: DeploymentHealth.Levels = .defaults, yaml: String? = nil
    ) throws {
        let environment = EnvironmentProfiles.resolve(
            config: try ConfigLoader.loadFromString(yaml ?? proFile), workspace: ws)
        ReportEngine.finalizeEnvironmentSummary(
            summariesDir: try WorkspacePaths.summariesDir(for: ws), dataDir: try dataDir(),
            environment: environment, workspace: try WorkspaceID(validating: ws),
            landed: [.jamfPro: landed.union(["computers"])], day: .testNoon,
            deploymentLevels: levels, onLine: { _ in })
    }

    // MARK: - Writing

    func testAGroupIsWrittenOnlyForALandedKindWithItsLevelsAndFloor() throws {
        try makeRoot()
        try writeMDMSummary()
        // 1/10 warning, 3/10 critical, 0/10 below, 1/2 under the floor, so not judged.
        try policies([(1, 10), (3, 10), (0, 10), (1, 2)])
        try save("[]", "app-installers-deployments")
        try finalize(landed: ["patch-policies"])
        let s = try summary()
        let group = try XCTUnwrap(s.patchPolicyHealth)
        XCTAssertEqual(group.judged, 3)
        XCTAssertEqual(group.atWarning, 1)
        XCTAssertEqual(group.atCritical, 1)
        XCTAssertEqual(group.atLevel, 2)
        XCTAssertEqual(group.warningPercent, 10)
        XCTAssertEqual(group.criticalPercent, 25)
        XCTAssertEqual(group.minimumInScope, DeploymentHealth.minimumInScope)
        XCTAssertNil(s.appInstallersHealth, "its snapshot is there but it did not land this run")
    }

    func testALandedEmptyListOrAllUnderTheFloorIsAMeasuredZero() throws {
        try makeRoot()
        try writeMDMSummary()
        try save("[]", "app-installers-deployments")
        try policies([(1, 2), (0, 3)])
        try finalize(landed: ["app-installers-deployments", "patch-policies"])
        let s = try summary()
        XCTAssertEqual(s.appInstallersHealth?.judged, 0)
        XCTAssertEqual(s.appInstallersHealth?.atLevel, 0)
        XCTAssertEqual(s.patchPolicyHealth?.judged, 0)
        XCTAssertEqual(s.patchPolicyHealth?.atLevel, 0)
    }

    /// Nothing could be read: rows with no ID, or rows with no counts and none judged. That is
    /// no measurement, so no group (never `judged: 0`), and the earlier value stands.
    func testRowsLeftOutOrUnmeasuredWithNoneJudgedWriteNoGroup() throws {
        try makeRoot()
        try writeMDMSummary()
        try save(#"[{"name":"no id"}]"#, "app-installers-deployments")
        try save(#"[{"id":"1","policyEnabled":true,"failed":1}]"#, "patch-policies")
        try finalize(landed: ["app-installers-deployments", "patch-policies"])
        let s = try summary()
        XCTAssertNil(s.appInstallersHealth, "rows with no ID are not a measured zero")
        XCTAssertNil(s.patchPolicyHealth, "an unmeasured row is not a measured zero")
    }

    func testAnUnreadableSnapshotWritesNoGroup() throws {
        try makeRoot()
        try writeMDMSummary()
        try save(#"{"not":"a list"}"#, "patch-policies")
        try finalize(landed: ["patch-policies"])
        XCTAssertNil(try summary().patchPolicyHealth)
    }

    func testNonDefaultLevelsAreUsedAndRecorded() throws {
        try makeRoot()
        try writeMDMSummary()
        try policies([(1, 10), (3, 10)])
        try finalize(landed: ["patch-policies"], levels: .init(warning: 5, critical: 35))
        let group = try XCTUnwrap(try summary().patchPolicyHealth)
        XCTAssertEqual(group.atWarning, 2, "3 of 10 is under a critical level of 35%")
        XCTAssertEqual(group.atCritical, 0)
        XCTAssertEqual(group.basis, "5/35/\(DeploymentHealth.minimumInScope)")
    }

    func testASchoolEnvironmentWritesNoGroup() throws {
        try makeRoot()
        try writeMDMSummary()
        try policies([(5, 10)])
        try finalize(landed: ["patch-policies"], yaml: "profiles:\n  jamf_school: depsum\n")
        XCTAssertNil(try summary().patchPolicyHealth)
    }

    func testALaterRunWithoutALandingKeepsTheSameDayGroup() throws {
        try makeRoot()
        try writeMDMSummary()
        try policies([(5, 10)])
        try finalize(landed: ["patch-policies"])
        try finalize(landed: [])
        XCTAssertEqual(try summary().patchPolicyHealth?.atCritical, 1)
    }

    // MARK: - The decoded form

    private func group(
        judged: Int = 4, warning: Int = 1, critical: Int = 1,
        levels: (Int, Int) = (10, 25), floor: Int = 10
    ) -> DeploymentSummaryGroup {
        var group = DeploymentSummaryGroup(
            figures: .init(judged: judged, atWarning: warning, atCritical: critical),
            levels: .init(warning: levels.0, critical: levels.1))
        group.minimumInScope = floor
        return group
    }

    private func roundTrip(_ summary: DailySummary) throws -> DailySummary {
        try SummaryJSONParser.decode(JSONEncoder().encode(summary))
    }

    func testOneGroupUpdatesWhileTheOtherKeepsItsOwnLevels() throws {
        let first = Self.base().withEnvironment(products: nil, protect: nil, deployments: [
            .appInstallers: group(levels: (10, 25)), .patchPolicy: group(levels: (10, 25)),
        ])
        let second = first.withEnvironment(products: nil, protect: nil, deployments: [.patchPolicy: group(levels: (5, 50))])
        XCTAssertEqual(second.appInstallersHealth?.basis, "10/25/10")
        XCTAssertEqual(second.patchPolicyHealth?.basis, "5/50/10")
        let filled = Self.base().withEnvironment(
            products: nil, protect: nil, deployments: [.patchPolicy: group(levels: (5, 50))]).filling(from: first)
        XCTAssertEqual(filled.appInstallersHealth?.basis, "10/25/10", "kept from the older day")
        XCTAssertEqual(filled.patchPolicyHealth?.basis, "5/50/10", "the newer group wins")
    }

    func testBoundaryLevelsRoundTrip() throws {
        for levels in [(1, 1), (1, 100), (100, 100)] {
            let written = Self.base().withEnvironment(
                products: nil, protect: nil, deployments: [.appInstallers: group(levels: levels, floor: 1)])
            let read = try roundTrip(written)
            XCTAssertEqual(read.appInstallersHealth, written.appInstallersHealth, "\(levels)")
        }
    }

    func testEachRangeRuleRejectsTheSummary() throws {
        let bad: [(String, DeploymentSummaryGroup)] = [
            ("more at a level than judged", group(judged: 1, warning: 1, critical: 1)),
            ("negative count", group(judged: -1, warning: 0, critical: 0)),
            ("count past the ceiling", group(judged: SummaryJSONParser.maxSummaryNumber + 1,
                                             warning: 0, critical: 0)),
            ("warning above critical", group(levels: (30, 20))),
            ("level 0", group(levels: (0, 25))),
            ("level over 100", group(levels: (10, 101))),
            ("floor 0", group(floor: 0)),
        ]
        for (label, value) in bad {
            let data = try JSONEncoder().encode(
                Self.base().withEnvironment(products: nil, protect: nil, deployments: [.patchPolicy: value]))
            XCTAssertThrowsError(try SummaryJSONParser.decode(data), label)
        }
    }

    func testAMalformedGroupReadsAsAbsentAndAnOlderSummaryDecodes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Self.base())) as? [String: Any])
        XCTAssertNil(try roundTrip(Self.base()).patchPolicyHealth, "no key: an older summary")
        object["patchPolicyHealth"] = ["judged": "four"]
        let read = try SummaryJSONParser.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(read.patchPolicyHealth)
        XCTAssertEqual(read.totalDevices, 5, "the rest of the day still reads")
    }

    // MARK: - The router

    func testTheRouterPassesTheConfiguredLevels() async throws {
        try makeRoot()
        try policies([(1, 10), (3, 10)])
        let yaml = proFile + "thresholds:\n  deployment_failure_warning_percent: 5\n"
            + "  deployment_failure_critical_percent: 50\n"
        let file = try summaryFile()
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: ws),
            config: try ConfigLoader.loadFromString(yaml), now: .testNoon,
            proCollect: { _, _, _, _, _, _, _ in
                ReportEngine.landedSources?.record(.jamfPro, ["computers", "patch-policies"])
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                ReportEngine.writeSummaryFile(Self.base(), to: file, onLine: nil)
                return .collected
            },
            schoolCollect: { _, _, _, _, _, _ in },
            protectCollect: { _, _, _, _ in [] },
            resolved: { _ in nil },
            gate: { _, _, _, _, _, _ in .proceed(holdsClaim: false, coordinating: false) },
            onLine: { _ in })
        let group = try XCTUnwrap(try summary().patchPolicyHealth)
        XCTAssertEqual(group.basis, "5/50/\(DeploymentHealth.minimumInScope)")
        XCTAssertEqual(group.atWarning, 2)
    }
}
