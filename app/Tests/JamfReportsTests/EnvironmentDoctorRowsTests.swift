import XCTest
@testable import JamfReports

final class EnvironmentDoctorRowsTests: XCTestCase {
    private func env(
        _ yaml: String, ws: String = "ws"
    ) throws -> (EnvironmentProfiles, ReportConfig) {
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

    func testTheProtectSlotIsCheckedToo() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  protect: ws-P\n")
        let rows = ConfigDoctorService.unknownSlotProfileRows(environment: e, listed: ["ws"])
        XCTAssertEqual(rows.map(\.id), ["environment.unknown_profile"])
        XCTAssertTrue(rows[0].detail.contains("Jamf Protect"))
    }

    func testASecurityCloudProfileInTwoEnvironmentsFails() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  security_cloud: sc\n")
        let (o, _) = try env("profiles:\n  jamf_pro: other\n  security_cloud: sc\n", ws: "other")
        XCTAssertEqual(ConfigDoctorService.profileSharedRows(
            profile: "ws", environment: e, others: [("other", o)]).map(\.id),
            ["environment.profile_shared"])
    }

    func testPlatformEqualToJamfProGivesNoHostRow() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  platform: ws\n")
        XCTAssertTrue(ConfigDoctorService.platformHostRows(
            profile: "ws", environment: e,
            hosts: ("https://a.jamfcloud.com", "https://b.jamfcloud.com")).isEmpty)
    }

    func testProbesOffAsksJamfCLINothing() throws {
        let (_, c) = try env("profiles:\n  jamf_pro: ws\n  platform: ws-API\n  protect: ws-P\n")
        XCTAssertTrue(ConfigDoctorService.platformHostRows(
            profile: "ws", config: c, includeProbes: false).isEmpty)
        XCTAssertTrue(ConfigDoctorService.unknownSlotProfileRows(
            profile: "ws", config: c, includeProbes: false).isEmpty)
    }

    func testAnotherLocalWorkspaceNameIsRedactedFromARunLogLine() throws {
        let line = "[fail] environment.profile_shared: it is profiles.protect in 'Fabrikam'"
        let out = LogRedactor.redactedForSharing(
            line, profile: "ws", scopeIDs: { _ in [] }, serverHosts: { _ in [] },
            localWorkspaces: { ["Fabrikam"] })
        XCTAssertFalse(out.contains("Fabrikam"), out)
    }

    func testOnlyLongEnoughOtherWorkspaceNamesAreSeeded() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("jrc-seed-\(UUID().uuidString)")
        for name in ["dev", "Fabri"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            fm.createFile(
                atPath: root.appendingPathComponent("\(name)/config.yaml").path, contents: Data())
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT"); try? fm.removeItem(at: root) }
        let out = LogRedactor.redactedForSharing(
            "dev failed; Fabri failed", profile: "ws", scopeIDs: { _ in [] },
            serverHosts: { _ in [] })
        XCTAssertTrue(out.contains("dev"), "3 characters would mask a common word: \(out)")
        XCTAssertFalse(out.contains("Fabri"), out)
    }

    func testTheRealScanSeedsOnlyFoldersWithAConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-seed-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("Fabrikam"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("datafolder"), withIntermediateDirectories: true)
        fm.createFile(
            atPath: root.appendingPathComponent("Fabrikam/config.yaml").path, contents: Data())
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT"); try? fm.removeItem(at: root) }
        let forms = LogRedactor.localWorkspaceNameForms()
        XCTAssertTrue(forms.contains("Fabrikam"))
        XCTAssertFalse(forms.contains("datafolder"))
    }

    func testNoProfileSeedsNoLocalWorkspaces() {
        let out = LogRedactor.redactedForSharing(
            "Fabrikam", profiles: [], scopeIDs: { _ in [] }, serverHosts: { _ in [] },
            localWorkspaces: { ["Fabrikam"] })
        XCTAssertEqual(out, "Fabrikam")
    }

    /// A workspace named like a word the logs use is not masked, so `[partial]` stays readable.
    func testAWorkspaceNamedLikeALogWordDoesNotMaskThatWord() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("jrc-seed-\(UUID().uuidString)")
        for name in ["Test", "partial", "Fabri"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            fm.createFile(
                atPath: root.appendingPathComponent("\(name)/config.yaml").path, contents: Data())
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT"); try? fm.removeItem(at: root) }
        let forms = LogRedactor.localWorkspaceNameForms()
        XCTAssertFalse(forms.contains("Test") || forms.contains("partial"), "\(forms)")
        XCTAssertTrue(forms.contains("Fabri"))
        let out = LogRedactor.redactedForSharing(
            "[partial] test failed; Fabri failed", profile: "ws", scopeIDs: { _ in [] },
            serverHosts: { _ in [] })
        XCTAssertTrue(out.contains("[partial] test failed"), out)
        XCTAssertFalse(out.contains("Fabri"), out)
    }

    // MARK: - environment.protect_match

    private func matchRows(_ yaml: String, _ met: Int?, of: Int = 0) throws -> [DoctorRow] {
        let (e, _) = try env(yaml)
        return ConfigDoctorService.protectMatchRows(
            environment: e, matched: met.map { MobileSummary.Share(met: $0, of: of) })
    }

    func testProtectMatchRowMatrix() throws {
        let pro = "profiles:\n  jamf_pro: ws\n  protect: ws-P\n"
        XCTAssertTrue(try matchRows("profiles:\n  jamf_pro: ws\n", 0, of: 10).isEmpty, "no Protect")
        XCTAssertTrue(try matchRows(pro, nil).isEmpty, "pair absent")
        XCTAssertTrue(try matchRows(pro, 0, of: 4).isEmpty, "too few")
        XCTAssertEqual(try matchRows(pro, 2, of: 5).map(\.id), ["environment.protect_match"])
        XCTAssertEqual(try matchRows(pro, 2, of: 5).map(\.severity), [.warn])
        XCTAssertTrue(try matchRows(pro, 5, of: 10).isEmpty, "exactly half")
        XCTAssertEqual(try matchRows(pro, 999, of: 2000).count, 1, "49.95% is not 50%")
        XCTAssertTrue(try matchRows(pro, Int.max, of: Int.max).isEmpty, "no overflow")
        XCTAssertEqual(try matchRows(pro, 1, of: Int.max).count, 1, "no overflow")
        XCTAssertTrue(try matchRows("profiles:\n  protect: ws-P\n", 0, of: 10).isEmpty,
                      "Protect-only")
    }

    func testProtectMatchRowNamesCountsProfileAndProductWithoutIdentifiers() throws {
        let row = try XCTUnwrap(matchRows(
            "profiles:\n  jamf_school: ws\n  protect: ws-P\n", 1, of: 8).first)
        XCTAssertTrue(row.detail.contains("1 of 8"))
        XCTAssertTrue(row.detail.contains("ws-P"))
        XCTAssertTrue(row.detail.contains("Jamf School"))
        XCTAssertTrue(row.hint?.contains("another environment") ?? false)
    }

    /// The live wrapper reads the newest summary; one older than a week is not a current figure.
    func testProtectMatchRowIsSilentOnAStaleSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("match-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ws"), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT"); try? FileManager.default.removeItem(at: root) }
        let config = try ConfigLoader.loadFromString(
            "profiles:\n  jamf_pro: ws\n  protect: ws-P\n")
        let dir = try WorkspacePaths.summariesDir(for: "ws")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(daysAgo: Int) throws {
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
            let day = SummaryJSONParser.dateFormatter.string(
                from: Date().addingTimeInterval(Double(-daysAgo) * 86_400))
            let summary = DailySummary(
                date: day, totalDevices: 10, fileVaultPct: nil, compliancePct: nil,
                staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
                source: "jamf-cli"
            ).withEnvironment(
                products: nil,
                protect: .init(computers: .init(count: 5, matched: .init(met: 2, of: 5))))
            XCTAssertTrue(ReportEngine.writeSummaryFile(
                summary, to: dir.appendingPathComponent("summary_\(day).json"), onLine: nil))
        }
        try write(daysAgo: 0)
        XCTAssertEqual(
            ConfigDoctorService.protectMatchRows(profile: "ws", config: config).map(\.id),
            ["environment.protect_match"])
        try write(daysAgo: 30)
        XCTAssertTrue(ConfigDoctorService.protectMatchRows(profile: "ws", config: config).isEmpty)
        // A future-dated summary a peer wrote is neither newest nor read.
        try write(daysAgo: -3_000)
        XCTAssertNil(SummaryJSONParser.newestSummaryDay(profile: "ws"))
        XCTAssertTrue(ConfigDoctorService.protectMatchRows(profile: "ws", config: config).isEmpty)
    }
}
