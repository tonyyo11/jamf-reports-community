import Foundation
import XCTest
@testable import JamfReports

// MARK: - CollectRouterTests
//
// Tests for ProfileProductType.detect and CollectRouter.run product-type dispatch.
//
// All tests are fully offline — no jamf-cli required. Routing is verified by
// counting how many times each spy closure was called, not by inspecting actual
// jamf-cli output.
//
// Swift 6 / XCTest concurrency: @MainActor class-level annotation, per the
// established project pattern (see swift_test_concurrency_pattern.md memory).

@MainActor
final class CollectRouterTests: XCTestCase {

    // MARK: - SchoolCLIConfig decoding

    /// ConfigLoader must parse school_cli.enabled and school_cli.profile from YAML.
    func test_schoolCLIConfig_decodesFromYAML() throws {
        let yaml = """
        school_cli:
          enabled: true
          profile: my-school-profile
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.schoolCli?.isEnabled, true,
                       "school_cli.enabled must decode to true")
        XCTAssertEqual(config.schoolCli?.resolvedProfile, "my-school-profile",
                       "school_cli.profile must decode to the configured value")
    }

    /// When school_cli.enabled is false, the key is parsed but isEnabled returns false.
    func test_schoolCLIConfig_enabledFalse() throws {
        let yaml = """
        school_cli:
          enabled: false
          profile: unused
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.schoolCli?.isEnabled, false)
    }

    /// When school_cli is absent entirely, schoolCli is nil.
    func test_schoolCLIConfig_absentIsNil() throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        XCTAssertNil(config.schoolCli, "schoolCli must be nil when school_cli key is absent")
    }

    // MARK: - ProfileProductType.detect

    /// A nil config (load failure) must degrade to .jamfPro with no Protect.
    func test_detect_nilConfig_returnsPro() {
        let result = ProfileProductType.detect(from: nil, profile: "ws")
        XCTAssertEqual(result.type, .jamfPro)
        XCTAssertFalse(result.runsProtect)
    }

    /// school_cli.enabled == true with the workspace's own profile → .jamfSchool, no Protect.
    func test_detect_schoolEnabled_returnsSchool() throws {
        let config = try ConfigLoader.loadFromString("""
        school_cli:
          enabled: true
          profile: ws
        """)
        let result = ProfileProductType.detect(from: config, profile: "ws")
        XCTAssertEqual(result.type, .jamfSchool)
        XCTAssertFalse(result.runsProtect, "no protect block, no Protect")
    }

    /// A blank or absent school_cli.profile means the workspace's own profile → .jamfSchool.
    func test_detect_schoolEnabledBlankProfile_returnsSchool() throws {
        for yaml in ["school_cli:\n  enabled: true\n",
                     "school_cli:\n  enabled: true\n  profile: \"  \"\n"] {
            let config = try ConfigLoader.loadFromString(yaml)
            XCTAssertEqual(ProfileProductType.detect(from: config, profile: "ws").type,
                           .jamfSchool, yaml)
        }
    }

    /// A School login recorded in a Jamf Pro workspace (another jamf-cli profile) is not used:
    /// the workspace is Jamf Pro, with Protect when enabled. A case variant is another profile.
    func test_detect_schoolForeignProfile_returnsPro() throws {
        for name in ["school", "WS"] {
            let config = try ConfigLoader.loadFromString("""
            school_cli:
              enabled: true
              profile: \(name)
            protect:
              enabled: true
              profile: protect
            """)
            let result = ProfileProductType.detect(from: config, profile: "ws")
            XCTAssertEqual(result.type, .jamfPro, name)
            XCTAssertTrue(result.runsProtect, name)
        }
    }

    /// school_cli.enabled == false → .jamfPro (disabled School key is not enough).
    func test_detect_schoolDisabled_returnsPro() throws {
        let config = try ConfigLoader.loadFromString("""
        school_cli:
          enabled: false
          profile: school
        """)
        let result = ProfileProductType.detect(from: config, profile: "ws")
        XCTAssertEqual(result.type, .jamfPro)
    }

    /// Absent school_cli → .jamfPro.
    func test_detect_noSchoolKey_returnsPro() throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        let result = ProfileProductType.detect(from: config, profile: "ws")
        XCTAssertEqual(result.type, .jamfPro)
    }

    /// Jamf Pro with protect.enabled == true → .jamfPro, runsProtect == true.
    func test_detect_proWithProtect_returnsProRunsProtect() throws {
        let config = try ConfigLoader.loadFromString("""
        protect:
          enabled: true
          profile: protect-profile
        """)
        let result = ProfileProductType.detect(from: config, profile: "ws")
        XCTAssertEqual(result.type, .jamfPro)
        XCTAssertTrue(result.runsProtect)
    }

    /// Jamf Pro without protect key → .jamfPro, runsProtect == false.
    func test_detect_proNoProtect_returnsProNoProtect() throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        let result = ProfileProductType.detect(from: config, profile: "ws")
        XCTAssertEqual(result.type, .jamfPro)
        XCTAssertFalse(result.runsProtect)
    }

    /// School + protect.enabled present → School collect, and Protect follows it (2.11).
    func test_detect_schoolWithProtect_returnsSchoolRunsProtect() throws {
        let config = try ConfigLoader.loadFromString("""
        school_cli:
          enabled: true
          profile: ws
        protect:
          enabled: true
          profile: protect
        """)
        let result = ProfileProductType.detect(from: config, profile: "ws")
        XCTAssertEqual(result.type, .jamfSchool)
        XCTAssertTrue(result.runsProtect, "Protect augments a Jamf School workspace too")
    }

    // MARK: - CollectRouter.run dispatch

    /// For a Jamf Pro profile, only proCollect is called; school and protect are not called.
    func test_router_proProfile_callsProCollectOnly() async throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        let spy = RouterSpy()

        try await CollectRouter.run(
            profile: "testpro",
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: spy.proCollect,
            schoolCollect: spy.schoolCollect,
            protectCollect: spy.protectCollect,
            onLine: { _ in }
        )

        XCTAssertEqual(spy.proCallCount, 1, "Pro collect must be called exactly once")
        XCTAssertEqual(spy.schoolCallCount, 0, "School collect must not be called for a Pro profile")
        XCTAssertEqual(spy.protectCallCount, 0, "Protect collect must not be called without protect.enabled")
    }

    /// The run's start reaches the engine unchanged, so the collect dates its summary by the
    /// day the run began, not by whenever the router's product probe finished.
    func test_router_handsTheRunsStartToTheEngine() async throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        let seen = RouterDates()

        try await CollectRouter.run(
            profile: "testpro",
            config: config,
            workspacePaths: WorkspacePaths.self,
            now: .testNoon,
            proEngine: { _, _, _, _, _, now, _ in seen.add(now); return .collected },
            protectCollect: { _, _, _ in },
            onLine: { _ in }
        )

        XCTAssertEqual(seen.values, [.testNoon])
    }

    /// For a School profile, only schoolCollect is called; pro and protect are not called.
    func test_router_schoolProfile_callsSchoolCollectOnly() async throws {
        let config = try ConfigLoader.loadFromString("""
        school_cli:
          enabled: true
          profile: testschool
        """)
        let spy = RouterSpy()

        try await CollectRouter.run(
            profile: "testschool",
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: spy.proCollect,
            schoolCollect: spy.schoolCollect,
            protectCollect: spy.protectCollect,
            onLine: { _ in }
        )

        XCTAssertEqual(spy.schoolCallCount, 1, "School collect must be called exactly once")
        XCTAssertEqual(spy.proCallCount, 0, "Pro collect must not be called for a School profile")
        XCTAssertEqual(spy.protectCallCount, 0, "no Protect without protect.enabled")
    }

    /// A Jamf Pro workspace holding a foreign school_cli.profile (written by earlier builds)
    /// collects Jamf Pro again, and Protect when enabled; School collect is never called.
    func test_router_foreignSchoolProfile_collectsProNotSchool() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-foreign-school-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try ConfigLoader.loadFromString("""
        school_cli:
          enabled: true
          profile: school
        """)
        let spy = RouterSpy()

        try await CollectRouter.run(
            profile: "testpro",
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: spy.proCollect,
            schoolCollect: spy.schoolCollect,
            protectCollect: spy.protectCollect,
            onLine: { _ in }
        )

        XCTAssertEqual(spy.proCallCount, 1, "Pro collect must run for the Pro workspace")
        XCTAssertEqual(spy.schoolCallCount, 0, "a foreign School login must not route to School")
    }

    /// For a Pro profile with protect.enabled, proCollect then protectCollect are both called.
    /// The spy's Pro collect returns `.collected` — the one disposition that runs Protect.
    func test_router_proWithProtect_callsBothProAndProtect() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectRouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        // Create a workspace so WorkspacePaths.dataDir(for:) resolves.
        let profile = "testprotect\(Int.random(in: 1000...9999))"
        let ws = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        let config = try ConfigLoader.loadFromString("""
        protect:
          enabled: true
          profile: my-protect
        """)
        let spy = RouterSpy()

        try await CollectRouter.run(
            profile: profile,
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: spy.proCollect,
            schoolCollect: spy.schoolCollect,
            protectCollect: spy.protectCollect,
            onLine: { _ in }
        )

        XCTAssertEqual(spy.proCallCount, 1, "Pro collect must be called")
        XCTAssertEqual(spy.protectCallCount, 1, "Protect collect must be called after Pro")
        XCTAssertEqual(spy.schoolCallCount, 0, "School collect must not be called")
    }

    /// A protect-collect failure must not rethrow — Pro run already succeeded.
    func test_router_protectFailure_isNonFatal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectRouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let profile = "testprotfail\(Int.random(in: 1000...9999))"
        let ws = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        let config = try ConfigLoader.loadFromString("""
        protect:
          enabled: true
          profile: my-protect
        """)
        let warnEmitted = RouterValueBox<Bool>(false)
        let watcher = CollectHonestyWatcher()

        // Does not throw despite protectCollect throwing.
        try await CollectRouter.run(
            profile: profile,
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: { _, _, _, _, _, _ in .collected },
            schoolCollect: { _, _, _, _, _ in },
            protectCollect: { _, _, _ in throw NSError(domain: "test", code: 42) },
            onLine: { line in
                watcher.observe(line.text)
                if line.level == .warn, line.text.hasPrefix("[partial] protect collect failed") {
                    warnEmitted.set(true)
                }
            }
        )

        XCTAssertTrue(warnEmitted.value, "A warning must be emitted when protect collect fails")
        XCTAssertTrue(watcher.incomplete, "Run History still reads the run as Partial")
        XCTAssertFalse(watcher.retryCouldHelp { _ in false },
                       "a throw (no jamf-cli, bad profile) repeats on a same-day retry")
    }

    // MARK: - Product guard

    private func resolved(
        _ product: JamfCLIProduct, org: Bool = false
    ) -> @Sendable (String) -> ProfileAuthMethod.Resolved? {
        { _ in .init(authMethod: "oauth2", isTenantLevel: false,
                     isOrganizationLevel: org, product: product) }
    }

    /// A Protect, Security Cloud, School (without school_cli) or organization-level profile in
    /// a Jamf Pro workspace sends nothing: not Pro, not Protect, and one `[error]` line.
    func test_router_anotherProduct_collectsNothing() async throws {
        let config = try ConfigLoader.loadFromString("""
        protect:
          enabled: true
          profile: my-protect
        """)
        let answers: [(JamfCLIProduct, Bool)] = [
            (.protect, false), (.securityCloud, false), (.school, false), (.pro, true),
        ]
        for (product, org) in answers {
            let spy = RouterSpy()
            let lines = ProductGuardLines()
            do {
                try await CollectRouter.run(
                    profile: "other", config: config, workspacePaths: WorkspacePaths.self,
                    proCollect: spy.proCollect, schoolCollect: spy.schoolCollect,
                    protectCollect: spy.protectCollect, resolved: resolved(product, org: org),
                    onLine: lines.add)
                XCTFail("\(product) org=\(org) was not refused")
            } catch CLIBridgeError.wrongProduct(let refusal) {
                XCTAssertTrue(refusal.hasPrefix("Collect is a Jamf Pro command; 'other' is"))
            }
            XCTAssertEqual(
                [spy.proCallCount, spy.schoolCallCount, spy.protectCallCount], [0, 0, 0])
            XCTAssertEqual(lines.all.count, 1, "\(lines.all)")
            XCTAssertTrue(lines.all[0].hasPrefix("[error] Collect is a Jamf Pro command"))
        }
    }

    /// Nothing known about the profile, or Jamf Pro, runs as before.
    func test_router_unresolvedUnknownAndProRun() async throws {
        let answers: [@Sendable (String) -> ProfileAuthMethod.Resolved?] = [
            { _ in nil }, resolved(.unknown), resolved(.pro),
        ]
        for answer in answers {
            let spy = RouterSpy()
            try await CollectRouter.run(
                profile: "fine", config: nil, workspacePaths: WorkspacePaths.self,
                proCollect: spy.proCollect, schoolCollect: spy.schoolCollect,
                protectCollect: spy.protectCollect, resolved: answer, onLine: { _ in })
            XCTAssertEqual(spy.proCallCount, 1)
        }
    }

    /// A Jamf School workspace (school_cli) on a School profile is the School collect, not a
    /// Pro run, so the product guard leaves it alone.
    func test_router_schoolWorkspaceOnASchoolProfileStillCollectsSchool() async throws {
        let config = try ConfigLoader.loadFromString(
            "school_cli:\n  enabled: true\n  profile: sch\n")
        let spy = RouterSpy()
        try await CollectRouter.run(
            profile: "sch", config: config, workspacePaths: WorkspacePaths.self,
            proCollect: spy.proCollect, schoolCollect: spy.schoolCollect,
            protectCollect: spy.protectCollect, resolved: resolved(.school), onLine: { _ in })
        XCTAssertEqual([spy.proCallCount, spy.schoolCallCount], [0, 1])
    }

    /// Nil config must degrade to Jamf Pro without crashing (regression guard).
    func test_router_nilConfig_degradesToPro() async throws {
        let spy = RouterSpy()

        try await CollectRouter.run(
            profile: "testnil",
            config: nil,
            workspacePaths: WorkspacePaths.self,
            proCollect: spy.proCollect,
            schoolCollect: spy.schoolCollect,
            protectCollect: spy.protectCollect,
            onLine: { _ in }
        )

        XCTAssertEqual(spy.proCallCount, 1, "Nil config must default to Pro collect")
        XCTAssertEqual(spy.schoolCallCount, 0)
        XCTAssertEqual(spy.protectCallCount, 0)
    }

    /// Regression guard: Pro path receives the same force and skipExpensive values
    /// that the caller passes — no silent flipping.
    func test_router_forceAndSkipPassedThroughToPro() async throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        let capturedForce = RouterValueBox<Bool?>(nil)
        let capturedSkip = RouterValueBox<Bool?>(nil)

        try await CollectRouter.run(
            profile: "testpro",
            skipExpensive: true,
            force: true,
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: { _, _, _, skipExpensive, force, _ in
                capturedSkip.set(skipExpensive)
                capturedForce.set(force)
                return .collected
            },
            schoolCollect: { _, _, _, _, _ in },
            protectCollect: { _, _, _ in },
            onLine: { _ in }
        )

        XCTAssertEqual(capturedForce.value, true, "force must be passed through unchanged")
        XCTAssertEqual(capturedSkip.value, true, "skipExpensive must be passed through unchanged")
    }

    // MARK: - Protect follows only a Pro collect that ran

    /// A Pro collect that stood down for a peer fetched nothing, and the peer holds
    /// the shared-workspace claim: Protect must not collect beside it.
    func test_router_proStoodDown_skipsProtect() async throws {
        let (spy, lines, _) = try await runProtectEnabledProfile(proReturning: .stoodDown)

        XCTAssertEqual(spy.proCallCount, 1, "Pro collect must still be asked")
        XCTAssertEqual(spy.protectCallCount, 0, "Protect must not run after a stand-down")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[skip] protect:") },
                      "the skip must be visible in the run log; got: \(lines)")
    }

    /// The once-per-day guard skipped the Pro collect, so Protect skips with it.
    func test_router_proAlreadyCollected_skipsProtect() async throws {
        let (spy, lines, _) = try await runProtectEnabledProfile(proReturning: .alreadyCollected)

        XCTAssertEqual(spy.proCallCount, 1)
        XCTAssertEqual(spy.protectCallCount, 0,
                       "Protect must not run when today's Pro collect already ran")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[skip] protect:") }, "got: \(lines)")
    }

    // MARK: - Protect after a failed Pro collect

    /// A dead run or dead credentials reached Jamf and failed; Protect has its own login, so it
    /// still runs, and the Pro error is what the caller sees.
    func test_router_proVerdictThrow_stillRunsProtectAndRethrowsProError() async throws {
        let verdicts: [ReportEngineError] = [
            .authExpired(profile: "p", failedCount: 3),
            .collectDead(profile: "p", failedCount: 3),
        ]
        for verdict in verdicts {
            let (spy, _, thrown) = try await runProtectEnabledProfile(proThrowing: verdict)
            XCTAssertEqual(spy.protectCallCount, 1, "\(verdict)")
            XCTAssertEqual(thrown?.localizedDescription, verdict.localizedDescription)
        }
    }

    /// A Protect failure after a Pro failure is a `[partial]` line; it never replaces the Pro error.
    func test_router_protectFailureAfterProVerdict_keepsProError() async throws {
        let verdict = ReportEngineError.authExpired(profile: "p", failedCount: 2)
        let (spy, lines, thrown) = try await runProtectEnabledProfile(
            proThrowing: verdict, protectThrowing: NSError(domain: "test", code: 7))
        XCTAssertEqual(spy.protectCallCount, 1)
        XCTAssertEqual(thrown?.localizedDescription, verdict.localizedDescription)
        XCTAssertTrue(lines.contains { $0.hasPrefix(ReportEngine.protectCollectFailedMarker) })
    }

    /// Anything that is not a collect verdict (no jamf-cli, a bad profile, a collect refusal)
    /// stops the run before Protect.
    func test_router_proPreflightThrow_doesNotRunProtect() async throws {
        let errors: [Error] = [
            ReportEngineError.jamfCLINotFound,
            ReportEngineError.profileMismatch(named: "a", run: "b"),
            CLIBridgeError.tickLockHeld,
            CLIBridgeError.collectInProgress,
        ]
        for error in errors {
            let (spy, _, thrown) = try await runProtectEnabledProfile(proThrowing: error)
            XCTAssertEqual(spy.protectCallCount, 0, "\(error)")
            XCTAssertEqual(thrown?.localizedDescription, error.localizedDescription)
        }
    }

    /// The product guard refuses before the Pro collect, so Protect does not run either.
    func test_router_wrongProduct_doesNotRunProtect() async throws {
        let config = try ConfigLoader.loadFromString(
            "protect:\n  enabled: true\n  profile: my-protect\n")
        let spy = RouterSpy()
        do {
            try await CollectRouter.run(
                profile: "other", config: config, workspacePaths: WorkspacePaths.self,
                proCollect: spy.proCollect, schoolCollect: spy.schoolCollect,
                protectCollect: spy.protectCollect, resolved: resolved(.protect), onLine: { _ in })
            XCTFail("not refused")
        } catch CLIBridgeError.wrongProduct {}
        XCTAssertEqual([spy.proCallCount, spy.protectCallCount], [0, 0])
    }

    // MARK: - Protect after a Jamf School collect (2.11)

    func test_router_schoolWithProtect_callsSchoolThenProtect() async throws {
        let (spy, _, thrown) = try await runProtectEnabledProfile(school: true)
        XCTAssertNil(thrown)
        XCTAssertEqual(
            [spy.proCallCount, spy.schoolCallCount, spy.protectCallCount], [0, 1, 1])
    }

    /// A School run that reached Jamf and failed still runs Protect, then rethrows its error.
    func test_router_schoolVerdictThrow_stillRunsProtectAndRethrows() async throws {
        let verdicts: [ReportEngineError] = [
            .authExpired(profile: "p", failedCount: 3),
            .collectDead(profile: "p", failedCount: 3),
        ]
        for verdict in verdicts {
            let (spy, _, thrown) = try await runProtectEnabledProfile(
                proThrowing: verdict, school: true)
            XCTAssertEqual(spy.protectCallCount, 1, "\(verdict)")
            XCTAssertEqual(thrown?.localizedDescription, verdict.localizedDescription)
        }
    }

    func test_router_schoolPreflightThrow_doesNotRunProtect() async throws {
        let errors: [Error] = [
            ReportEngineError.jamfCLINotFound, ReportEngineError.invalidProfile("x"),
            CLIBridgeError.tickLockHeld,
        ]
        for error in errors {
            let (spy, _, thrown) = try await runProtectEnabledProfile(
                proThrowing: error, school: true)
            XCTAssertEqual(spy.protectCallCount, 0, "\(error)")
            XCTAssertEqual(thrown?.localizedDescription, error.localizedDescription)
        }
    }

    func test_router_schoolWithBlankOrWrongProtectProfile_skipsWithOneWarn() async throws {
        let (blank, blankLines, _) = try await runProtectEnabledProfile(
            protectProfile: "", school: true)
        XCTAssertEqual(blank.protectCallCount, 0)
        XCTAssertEqual(blankLines.filter { $0.hasPrefix("[warn] Jamf Protect not collected") },
                       ["[warn] Jamf Protect not collected: protect.profile is blank"])
        let (wrong, wrongLines, _) = try await runProtectEnabledProfile(
            resolved: protectLogin(.school), school: true)
        XCTAssertEqual(wrong.protectCallCount, 0)
        XCTAssertEqual(
            wrongLines.filter { $0.hasPrefix("[warn] Jamf Protect not collected") }.count, 1)
    }

    // MARK: - protect.profile must be a Protect login

    /// Answers for the Protect profile only; the workspace's own profile stays unresolved.
    private func protectLogin(
        _ product: JamfCLIProduct
    ) -> @Sendable (String) -> ProfileAuthMethod.Resolved? {
        let answer = resolved(product)
        return { $0 == "my-protect" ? answer($0) : nil }
    }

    /// A blank name is not a connection (ConnectedProducts says so): one `[warn]`, not a
    /// `[partial] protect collect failed` on every run.
    func test_router_blankProtectProfile_skipsWithOneWarn() async throws {
        let (spy, lines, thrown) = try await runProtectEnabledProfile(protectProfile: "")
        XCTAssertNil(thrown)
        XCTAssertEqual(spy.protectCallCount, 0)
        XCTAssertEqual(lines.filter { $0.hasPrefix("[warn] Jamf Protect not collected") },
                       ["[warn] Jamf Protect not collected: protect.profile is blank"])
        XCTAssertFalse(lines.contains { $0.hasPrefix("[partial]") })
    }

    func test_router_protectProfileOfAnotherProduct_skipsWithOneWarn() async throws {
        for product in [JamfCLIProduct.pro, .school, .securityCloud] {
            let (spy, lines, thrown) = try await runProtectEnabledProfile(
                resolved: protectLogin(product))
            XCTAssertNil(thrown)
            XCTAssertEqual(spy.protectCallCount, 0, "\(product)")
            let warns = lines.filter { $0.hasPrefix("[warn] Jamf Protect not collected") }
            XCTAssertEqual(warns.count, 1, "\(lines)")
            XCTAssertTrue(warns[0].contains(
                "'my-protect' is a \(product.displayName) profile, not a Jamf Protect profile"))
        }
    }

    /// A Protect login, one nothing is known about, or one that could not be asked, collects.
    func test_router_protectProfileProtectUnknownOrUnresolved_collects() async throws {
        let answers: [@Sendable (String) -> ProfileAuthMethod.Resolved?] = [
            protectLogin(.protect), protectLogin(.unknown), { _ in nil },
        ]
        for answer in answers {
            let (spy, _, _) = try await runProtectEnabledProfile(resolved: answer)
            XCTAssertEqual(spy.protectCallCount, 1)
        }
    }

    // MARK: - Helpers

    /// Runs the router for a Protect-enabled Pro profile whose workspace exists, so
    /// `WorkspacePaths.dataDir(for:)` resolves and a skipped Protect can only come
    /// from the Pro collect's disposition.
    private func runProtectEnabledProfile(
        proReturning disposition: ReportEngine.CollectDisposition = .collected,
        proThrowing proError: Error? = nil,
        protectThrowing protectError: Error? = nil,
        protectProfile: String = "my-protect",
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved? = { _ in nil },
        school: Bool = false
    ) async throws -> (spy: RouterSpy, lines: [String], thrown: Error?) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectRouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let profile = "testdisposition\(Int.random(in: 1000...9999))"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )

        let schoolBlock = school ? "school_cli:\n  enabled: true\n" : ""
        let config = try ConfigLoader.loadFromString(schoolBlock + """
        protect:
          enabled: true
          profile: "\(protectProfile)"
        """)
        // A School run throws through the School spy; `proThrowing` names the run's error.
        let spy = RouterSpy(
            proDisposition: disposition, proError: school ? nil : proError,
            schoolError: school ? proError : nil, protectError: protectError)
        let lines = RouterLineCollector()

        var thrown: Error?
        do {
            try await CollectRouter.run(
                profile: profile,
                config: config,
                workspacePaths: WorkspacePaths.self,
                proCollect: spy.proCollect,
                schoolCollect: spy.schoolCollect,
                protectCollect: spy.protectCollect,
                resolved: resolved,
                onLine: { line in lines.append(line.text) }
            )
        } catch {
            thrown = error
        }
        return (spy, lines.texts, thrown)
    }
}

// MARK: - RouterSpy

/// Thread-safe call counter for CollectRouter spy closures.
/// Uses a plain struct wrapping a class-backed counter so the @Sendable closures
/// can capture it without capturing self, which avoids the lazy-var/@Sendable conflict.
private final class RouterCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

/// Thread-safe box for a single value captured inside a @Sendable router closure.
private final class RouterValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ initial: T) { _value = initial }
    var value: T { lock.withLock { _value } }
    func set(_ newValue: T) { lock.withLock { _value = newValue } }
}

/// Thread-safe record of the text of every line the router streams to `onLine`.
private final class RouterLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _texts: [String] = []
    var texts: [String] { lock.withLock { _texts } }
    func append(_ text: String) { lock.withLock { _texts.append(text) } }
}

private final class RouterDates: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Date] = []
    var values: [Date] { lock.withLock { stored } }
    func add(_ date: Date) { lock.withLock { stored.append(date) } }
}

private struct RouterSpy {
    let proCounter = RouterCallCounter()
    let schoolCounter = RouterCallCounter()
    let protectCounter = RouterCallCounter()
    /// What the spy's Pro collect reports; `.collected` is the only value that
    /// lets Protect follow.
    var proDisposition: ReportEngine.CollectDisposition = .collected
    var proError: Error?
    var schoolError: Error?
    var protectError: Error?

    var proCallCount: Int { proCounter.value }
    var schoolCallCount: Int { schoolCounter.value }
    var protectCallCount: Int { protectCounter.value }

    var proCollect: CollectRouter.ProCollect {
        let counter = proCounter
        let disposition = proDisposition
        let error = proError
        return { _, _, _, _, _, _ in
            counter.increment()
            if let error { throw error }
            return disposition
        }
    }

    var schoolCollect: CollectRouter.SchoolCollect {
        let counter = schoolCounter
        let error = schoolError
        return { _, _, _, _, _ in
            counter.increment()
            if let error { throw error }
        }
    }

    var protectCollect: CollectRouter.ProtectCollect {
        let counter = protectCounter
        let error = protectError
        return { _, _, _ in
            counter.increment()
            if let error { throw error }
        }
    }
}

/// A scheduled School run that collects and then generates forces past School's 12 h cadence;
/// snapshot-only and Jamf Pro do not.
final class ScheduledCollectForceTests: XCTestCase {
    func test_forcesCollect_onlyForSchoolCollectThenGenerate() {
        typealias Mode = Schedule.RunMode
        XCTAssertTrue(Mode.jamfCLIFull.forcesCollect(for: .jamfSchool))
        XCTAssertFalse(Mode.snapshotOnly.forcesCollect(for: .jamfSchool))
        XCTAssertFalse(Mode.jamfCLIOnly.forcesCollect(for: .jamfSchool))
        XCTAssertFalse(Mode.backup.forcesCollect(for: .jamfSchool))
        XCTAssertFalse(Mode.jamfCLIFull.forcesCollect(for: .jamfPro))
    }

    func test_router_passesForceToSchoolCollect() async throws {
        let config = try ConfigLoader.loadFromString("""
        school_cli:
          enabled: true
          profile: testschool
        """)
        let seen = LockedForce()
        let mode = Schedule.RunMode.jamfCLIFull
        try await CollectRouter.run(
            profile: "testschool",
            force: mode.forcesCollect(for: ProfileProductType.detect(from: config, profile: "testschool").type),
            config: config,
            schoolCollect: { _, _, _, force, _ in seen.set(force) },
            protectCollect: { _, _, _ in },
            onLine: { _ in })
        XCTAssertEqual(seen.value, true)
    }
}

private final class LockedForce: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ v: Bool) { lock.withLock { stored = v } }
}
