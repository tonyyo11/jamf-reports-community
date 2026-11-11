import XCTest
@testable import JamfReports

/// A `profiles:` block with only `protect` is a workspace that collects Protect, writes a
/// daily summary, and still refuses every Jamf Pro command.
final class ProtectOnlyCollectTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private struct Boom: Error {}

    private let ws = "protectws"
    private var config: ReportConfig {
        get throws { try ConfigLoader.loadFromString("profiles:\n  protect: \(ws)\n") }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws, isDirectory: true),
            withIntermediateDirectories: true)
        try "profiles:\n  protect: \(ws)\n".write(
            to: root.appendingPathComponent(ws).appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func run(
        landed: Int = 1, throwing: Bool = false, calls: Box, lines: Box? = nil,
        gate: @escaping CollectRouter.Gate = CollectRouter.realGate
    ) async throws {
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: ws), config: try config, now: .testNoon,
            proCollect: { _, _, _, _, _, _, _ in calls.add("pro"); return .collected },
            schoolCollect: { _, _, _, _, _, _ in calls.add("school") },
            protectCollect: { profile, dataDir, _ in
                calls.add("protect \(profile)")
                if throwing { throw Boom() }
                return landed > 0 ? ["protect-alerts"] : []
            },
            resolved: { _ in nil }, gate: gate, onLine: { lines?.add($0.text) })
    }

    private func summary() throws -> [String: Any] {
        let dir = try WorkspacePaths.summariesDir(for: ws)
        let day = SummaryJSONParser.dateFormatter.string(from: .testNoon)
        let data = try Data(contentsOf: dir.appendingPathComponent("summary_\(day).json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testProtectOnlyCollectsProtectAndWritesASummary() async throws {
        _ = try makeRoot()
        let calls = Box(), lines = Box()
        try await run(calls: calls, lines: lines)
        XCTAssertEqual(calls.all, ["protect \(ws)"])
        XCTAssertTrue(lines.all.contains { $0.contains("routing \(ws) → Jamf Protect collect") })
        let obj = try summary()
        XCTAssertEqual(obj["totalDevices"] as? Int, 0)
        XCTAssertEqual(obj["source"] as? String, "jamf-cli")
        XCTAssertNil(obj["mobileDeviceCount"])
        XCTAssertNil(obj["mobile"])
        XCTAssertNil(obj["fileVaultPct"])
        XCTAssertEqual((obj["collectionSources"] as? [String: String])?["protect-alerts"], "live")
    }

    func testASecondFullCollectTheSameDayIsStoppedByTheDayGuard() async throws {
        _ = try makeRoot()
        let calls = Box()
        try await run(calls: calls)
        try await run(calls: calls)
        XCTAssertEqual(calls.all, ["protect \(ws)"])
    }

    func testAThrowingProtectCollectFailsTheRun() async throws {
        _ = try makeRoot()
        do {
            try await run(throwing: true, calls: Box())
            XCTFail("expected a throw")
        } catch is Boom {}
    }

    func testNoLandedSourceIsADeadRunWithNoSummary() async throws {
        _ = try makeRoot()
        do {
            try await run(landed: 0, calls: Box())
            XCTFail("expected collectDead")
        } catch let error as ReportEngineError {
            guard case .collectDead = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try summary())
    }

    func testASummaryThatCountedMacsIsNotReplaced() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectOnlySummary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = SummaryJSONParser.dateFormatter.string(from: .testNoon)
        let file = dir.appendingPathComponent("summary_\(day).json")
        let counted = DailySummary(
            date: day, totalDevices: 5, fileVaultPct: nil, compliancePct: nil, staleCount: nil,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil, source: "jamf-cli")
        XCTAssertTrue(ReportEngine.writeSummaryFile(counted, to: file, onLine: nil))
        let environment = EnvironmentProfiles.resolve(config: try config, workspace: ws)
        let outcome = ReportEngine.finalizeEnvironmentSummary(
            summariesDir: dir, dataDir: dir, environment: environment,
            workspace: try WorkspaceID(validating: ws), landed: [.protect: ["protect-alerts"]],
            day: .testNoon, onLine: { _ in })
        XCTAssertEqual(outcome, .wrote)
        let data = try Data(contentsOf: file)
        let kept = try SummaryJSONParser.decode(data)
        XCTAssertEqual(kept.totalDevices, 5)
        XCTAssertEqual(kept.products, ["protect"])
    }

    func testProCommandsRefuseAProtectOnlyEnvironment() async throws {
        let config = try config
        let sentence = "'\(ws)' holds only a Jamf Protect profile; "
        XCTAssertEqual(
            CollectRouter.backupRefusal(profile: ws, config: config),
            sentence + "Backup needs Jamf Pro.")
        let audit = await CLIBridge.refusesProCommand(
            profile: ws, operation: "Audit", onLine: nil,
            environment: EnvironmentProfiles.resolve(config: config, workspace: ws),
            resolved: { _ in nil })
        XCTAssertEqual(audit, sentence + "Audit needs Jamf Pro.")
        XCTAssertThrowsError(try CLIBridge.backupProfile(
            for: ws, environment: EnvironmentProfiles.resolve(config: config, workspace: ws),
            onLine: { _ in }))
        XCTAssertNil(CollectRouter.runRefusal(profile: ws, operation: "Collect", config: config))
    }

    func testNoProAuthProbeForAProtectOnlyWorkspace() throws {
        _ = try makeRoot()
        XCTAssertTrue(ProfileAuthMethod.skipsProAuthProbe(profile: ws))
    }

    func testCLIDeviceLookupRefusesAProtectOnlyWorkspace() async throws {
        _ = try makeRoot()
        let refusal = await Device.refusal(profile: ws)
        XCTAssertEqual(refusal, "'\(ws)' holds only a Jamf Protect profile; "
            + "Device lookup needs Jamf Pro.")
    }

    private func backupSchedule(_ profile: String) -> Schedule {
        Schedule(
            name: "b", profile: profile, schedule: "Mon 07:00", cadence: "custom", mode: .backup,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.\(profile).b",
            multiTarget: nil, tiers: nil, excludedProfiles: nil)
    }

    /// A run record exists, is not marked refused, and no failure was recorded.
    private func assertPlainExitZeroRecord(in folder: URL) throws {
        let dir = folder.appendingPathComponent("automation")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix("_status.json") }
        XCTAssertFalse(files.isEmpty, "no run record")
        for file in files {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("refused"), text)
            XCTAssertTrue(text.contains("\"exit_code\":0") && text.contains("\"success\":true"), text)
        }
    }

    /// R13: a scheduled backup with nothing to back up is the #213 quiet skip, not a refusal.
    func testAScheduledBackupOfAProtectOnlyWorkspaceIsAQuietSkip() async throws {
        let root = try makeRoot()
        let outcome = await runSchedule(backupSchedule(ws), verbose: false)
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.endsRetries)
        let folder = root.appendingPathComponent(ws)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .contains("backups"))
        try assertPlainExitZeroRecord(in: folder)
    }

    func testAScheduledSchoolBackupIsStillAQuietSkip() async throws {
        let root = try makeRoot()
        try "school_cli:\n  enabled: true\n  profile: \(ws)\n".write(
            to: root.appendingPathComponent(ws).appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        let outcome = await runSchedule(backupSchedule(ws), verbose: false)
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.endsRetries)
        try assertPlainExitZeroRecord(in: root.appendingPathComponent(ws))
    }

    /// With a Protect profile the scheduled School backup is no longer skipped: it reaches the
    /// bridge, which finds no jamf-cli in a test process and fails instead (2.12).
    func testAScheduledSchoolBackupWithProtectRunsTheBackup() async throws {
        let root = try makeRoot()
        let yaml = "school_cli:\n  enabled: true\n  profile: \(ws)\n"
            + "protect:\n  enabled: true\n  profile: p\n"
        try yaml.write(
            to: root.appendingPathComponent(ws).appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        let outcome = await runSchedule(backupSchedule(ws), verbose: false)
        XCTAssertEqual(outcome.exitCode, 1, "the backup ran and found no jamf-cli")
    }

    /// Same store, same empty snapshots: a Jamf Pro workspace runs the sweep, a Protect-only
    /// one does not, so the Protect-only check alone is what stops it.
    @MainActor
    func testTheLaunchAuditSweepSkipsAProtectOnlyWorkspaceAndOnlyThat() async throws {
        let root = try makeRoot()
        let pro = root.appendingPathComponent("prows", isDirectory: true)
        try FileManager.default.createDirectory(at: pro, withIntermediateDirectories: true)
        try "profiles:\n  jamf_pro: prows\n".write(
            to: pro.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        for (name, expectsAudit) in [("prows", true), (ws, false)] {
            let store = WorkspaceStore(demoMode: false)
            store.profile = name
            XCTAssertTrue(store.canRefreshAutomatically(profileSlug: name), name)
            let called = Box()
            await store.autoRefreshAuditIfStale(audit: { _ in called.add("audit"); return 0 })
            XCTAssertEqual(called.all.isEmpty, !expectsAudit, name)
        }
    }

    func testAnUnconfirmedProfilesProtectPinFailsTheRunWithoutCollecting() async throws {
        let root = try makeRoot()
        let name = "pinned\(Int.random(in: 1000...9999))"
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("config.yaml")
        func write(_ protect: String) throws {
            try "shared_workspace:\n  enabled: true\nprofiles:\n  protect: \(protect)\n"
                .write(to: file, atomically: true, encoding: .utf8)
        }
        try write("someone-elses")
        _ = SharedConfigPin.check(profile: name)
        try write(name)
        let calls = Box()
        do {
            try await CollectRouter.run(
                workspace: WorkspaceID(validating: name), config: try ConfigLoader.load(from: file),
                now: .testNoon,
                protectCollect: { profile, _, _ in calls.add(profile); return ["protect-alerts"] },
                resolved: { _ in nil }, onLine: { _ in })
            XCTFail("expected protectNotConfirmed")
        } catch let error as ReportEngineError {
            guard case .protectNotConfirmed = error else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(calls.all.isEmpty)
    }

    // MARK: - Retention sweep runs in the router

    private func retentionConfigText(_ extra: String) -> String {
        extra + "retention:\n  enabled: true\n  mode: archive\n  snapshot_keep_days: 365\n"
    }

    private func marker(_ root: URL) -> URL {
        root.appendingPathComponent(ws).appendingPathComponent(".retention-last")
    }

    private func routeWith(
        _ text: String, root: URL, gate: @escaping CollectRouter.Gate = CollectRouter.realGate
    ) async throws {
        let file = root.appendingPathComponent(ws).appendingPathComponent("config.yaml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: ws), config: try ConfigLoader.load(from: file),
            now: .testNoon,
            schoolCollect: { _, _, _, _, _, _ in },
            protectCollect: { _, _, _ in ["protect-alerts"] },
            resolved: { _ in nil }, gate: gate, onLine: { _ in })
    }

    func testAProtectOnlyRunSweepsRetention() async throws {
        let root = try makeRoot()
        try await routeWith(retentionConfigText("profiles:\n  protect: \(ws)\n"), root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(root).path))
    }

    func testASchoolRunSweepsRetention() async throws {
        let root = try makeRoot()
        try await routeWith(
            retentionConfigText("school_cli:\n  enabled: true\n  profile: \(ws)\n"), root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(root).path))
    }

    func testAGateStopSweepsNothing() async throws {
        let root = try makeRoot()
        try await routeWith(
            retentionConfigText("profiles:\n  protect: \(ws)\n"), root: root,
            gate: { _, _, _, _, _, _ in .stop(.alreadyCollected) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(root).path))
    }

    func testAGateStopOfAProtectOnlyRunLogsNoJamfProSkip() async throws {
        _ = try makeRoot()
        let lines = Box()
        try await run(calls: Box(), lines: lines, gate: { _, _, _, _, _, _ in .stop(.alreadyCollected) })
        XCTAssertFalse(lines.all.contains { $0.contains("Jamf Pro") }, "\(lines.all)")
    }

    // MARK: - Unconfirmed Protect-only on a pinned workspace

    /// A shared workspace whose pin holds one `profiles.protect` and whose file now says the
    /// workspace's own name: a peer's edit, not yet confirmed on this Mac.
    private func unconfirmedProtectOnly(_ root: URL) throws -> String {
        let name = "unconf\(Int.random(in: 1000...9999))"
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("config.yaml")
        try "shared_workspace:\n  enabled: true\nprofiles:\n  jamf_pro: \(name)\n"
            .write(to: file, atomically: true, encoding: .utf8)
        _ = SharedConfigPin.check(profile: name)
        try "shared_workspace:\n  enabled: true\nprofiles:\n  protect: \(name)\n"
            .write(to: file, atomically: true, encoding: .utf8)
        return name
    }

    func testAnUnconfirmedProtectOnlyBlockDoesNotCountAsProtectOnly() throws {
        let root = try makeRoot()
        let name = try unconfirmedProtectOnly(root)
        let environment = EnvironmentProfiles.read(workspace: name)
        XCTAssertTrue(environment.isProtectOnly)
        XCTAssertFalse(environment.isConfirmedProtectOnly(workspace: name))
        XCTAssertFalse(ProfileAuthMethod.skipsProAuthProbe(profile: name))
        try SharedConfigPin.confirm(profile: name, keys: [.protectProfile])
        XCTAssertTrue(environment.isConfirmedProtectOnly(workspace: name))
    }

    /// A refused run (not a quiet skip): the health reader holds the reason and it never retries.
    func testAnUnconfirmedProtectOnlyBlockIsARefusedScheduledBackup() async throws {
        let root = try makeRoot()
        let name = try unconfirmedProtectOnly(root)
        let outcome = await runSchedule(backupSchedule(name), verbose: false)
        XCTAssertTrue(outcome.endsRetries)
        let input = try XCTUnwrap(LaunchAgentService.healthInputs(
            schedules: [backupSchedule(name)], statusProfile: name).first)
        XCTAssertTrue(try XCTUnwrap(input.refusal).contains("awaiting confirmation"))
    }

    /// The refusal comes before the pin checkpoint, the claim and retention: the gate is never
    /// asked and no Protect collect runs.
    func testAnUnconfirmedProtectOnlyBlockIsRefusedBeforeTheGate() async throws {
        let root = try makeRoot()
        let name = try unconfirmedProtectOnly(root)
        let asked = Box(), calls = Box()
        do {
            try await CollectRouter.run(
                workspace: WorkspaceID(validating: name), config: try configAt(root, name),
                now: .testNoon,
                protectCollect: { profile, _, _ in calls.add(profile); return ["protect-alerts"] },
                resolved: { _ in nil },
                gate: { _, _, _, _, _, _ in asked.add("gate"); return .stop(.alreadyCollected) },
                onLine: { _ in })
            XCTFail("expected protectNotConfirmed")
        } catch let error as ReportEngineError {
            guard case .protectNotConfirmed = error else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(asked.all.isEmpty, "the gate was asked")
        XCTAssertTrue(calls.all.isEmpty)
    }

    /// A second Mac must be able to list the folder to confirm it; runs still need the Confirm.
    func testAnUnconfirmedProtectOnlyLoginIsListedButNotRunnableUntilConfirmed() throws {
        let root = try makeRoot()
        let name = try unconfirmedProtectOnly(root)
        var login = JamfCLIProfile(name: name, url: "", schedules: 0, status: .idle)
        login.product = .protect
        XCTAssertEqual(
            ProfileService.droppingPairedProductProfiles([login], under: root).map(\.name), [name])
        XCTAssertEqual(
            ProfileService.runnableWorkspaces([login], excluding: [], under: root).map(\.name), [])
        try SharedConfigPin.confirm(profile: name, keys: [.protectProfile])
        XCTAssertEqual(
            ProfileService.runnableWorkspaces([login], excluding: [], under: root).map(\.name), [name])
    }

    // MARK: - Product gates (S1, S3, S5, S7, S8)

    private func snapshotSchedule(_ profile: String) -> Schedule {
        var schedule = backupSchedule(profile)
        schedule.mode = .snapshotOnly
        return schedule
    }

    private func configAt(_ root: URL, _ name: String) throws -> ReportConfig {
        try ConfigLoader.load(from: root.appendingPathComponent(name).appendingPathComponent("config.yaml"))
    }

    /// S1: the router would throw after the run record opened and write no `.fail`, so the tick
    /// retried every hour; the pre-check takes the refused path instead.
    func testAnUnconfirmedProtectOnlyEditIsTheRefusedRunConvention() async throws {
        let root = try makeRoot()
        let name = try unconfirmedProtectOnly(root)
        let config = try configAt(root, name)
        let reason = try XCTUnwrap(CollectRouter.runRefusal(
            profile: name, operation: "Collect", config: config))
        XCTAssertTrue(reason.contains("awaiting confirmation"), reason)
        XCTAssertNotNil(CollectRouter.scheduleRunRefusal(snapshotSchedule(name)))
        let outcome = await runSchedule(snapshotSchedule(name), verbose: false)
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.endsRetries, "no retry is due")
        let input = try XCTUnwrap(LaunchAgentService.healthInputs(
            schedules: [snapshotSchedule(name)], statusProfile: name).first)
        XCTAssertEqual(input.refusal, reason, "failing with the reason, not overdue")
        XCTAssertTrue(WorkspaceStore.refusedBeforeAutomaticCollect(profile: name, config: config))
        try SharedConfigPin.confirm(profile: name, keys: [.protectProfile])
        XCTAssertNil(CollectRouter.runRefusal(
            profile: name, operation: "Collect", config: config, resolved: { _ in nil }))
    }

    func testAConfirmedProtectOnlyLoginOfAnotherProductIsRefusedBeforeTheRun() throws {
        let root = try makeRoot()
        let config = try configAt(root, ws)
        let school = ProfileAuthMethod.Resolved(
            authMethod: "apikey", isTenantLevel: false, product: .school)
        XCTAssertNotNil(CollectRouter.runRefusal(
            profile: ws, operation: "Collect", config: config, resolved: { _ in school }))
        let protect = ProfileAuthMethod.Resolved(
            authMethod: "oauth2", isTenantLevel: false, product: .protect)
        XCTAssertNil(CollectRouter.runRefusal(
            profile: ws, operation: "Collect", config: config, resolved: { _ in protect }))
    }

    /// S3: a peer plants `<root>/<Name>/config.yaml` naming itself as the Protect login.
    func testAPlantedProtectOnlyFolderWaitsForAConfirmAndTheAddSheetPathDoesNot() throws {
        let root = try makeRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".stfolder"), withIntermediateDirectories: true)
        let support = root.appendingPathComponent(".support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let planted = "planted"
        let folder = root.appendingPathComponent(planted, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "profiles:\n  protect: \(planted)\n".write(
            to: folder.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            SharedConfigPin.check(profile: planted, appSupport: support).drifts.map(\.key),
            [.protectProfile])
        XCTAssertFalse(ProfileService.isProtectOnlyWorkspace(planted, root: root, appSupport: support))
        var login = JamfCLIProfile(name: planted, url: "", schedules: 0, status: .idle)
        login.product = .protect
        XCTAssertTrue(ProfileService.neverAWorkspace(login, under: root, appSupport: support))
        try SharedConfigPin.confirm(profile: planted, keys: [.protectProfile], appSupport: support)
        XCTAssertTrue(ProfileService.isProtectOnlyWorkspace(planted, root: root, appSupport: support))

        try OnboardingFlow.createProtectOnlyEnvironment(login: "created", appSupport: support)
        XCTAssertTrue(ProfileService.isProtectOnlyWorkspace("created", root: root, appSupport: support))
        var created = JamfCLIProfile(name: "created", url: "", schedules: 0, status: .idle)
        created.product = .protect
        XCTAssertFalse(ProfileService.neverAWorkspace(created, under: root, appSupport: support))
    }

    /// S5: the refusal comes from config.yaml, not from a `config list` probe.
    func testSchoolRefusesProCommandsFromConfigAloneAndBackupKeepsItsOwnSentence() async throws {
        for text in ["profiles:\n  jamf_school: \(ws)\n", "school_cli:\n  enabled: true\n  profile: \(ws)\n"] {
            let config = try ConfigLoader.loadFromString(text)
            let environment = EnvironmentProfiles.resolve(config: config, workspace: ws)
            let refusal = await CLIBridge.refusesProCommand(
                profile: ws, operation: "Audit", onLine: nil, environment: environment,
                resolved: { _ in nil })
            XCTAssertEqual(refusal, "Audit is a Jamf Pro command; '\(ws)' is a Jamf School workspace")
            XCTAssertEqual(
                CollectRouter.backupRefusal(profile: ws, config: config),
                CollectRouter.schoolBackupReason(profile: ws))
        }
    }

    /// S2: an unconfirmed Protect-only edit leaves this Mac showing the workspace as it was.
    @MainActor
    func testAnUnconfirmedProtectOnlyEditKeepsTheJamfProTabsAndConfirmedOneDropsThem() throws {
        let root = try makeRoot()
        let name = try unconfirmedProtectOnly(root)
        let store = WorkspaceStore(demoMode: false)
        store.profile = name
        store.refreshEnvironmentProducts()
        XCTAssertTrue(store.environmentProducts.has(.jamfPro))
        XCTAssertFalse(store.environmentProducts.isProtectOnly)
        try SharedConfigPin.confirm(profile: name, keys: [.protectProfile])
        store.refreshEnvironmentProducts()
        XCTAssertTrue(store.environmentProducts.isProtectOnly)
        XCTAssertEqual(store.availableMetrics, TrendSeries.Metric.protectMetrics)
        XCTAssertEqual(RefreshCoordinator.probeKind(for: .refresh, profile: name), "protect-overview")
    }

    /// S7: config.yaml unreadable and the login is Protect, so there is no Jamf Pro to show.
    @MainActor
    func testAnUnreadableConfigWithAProtectLoginIsProtectOnly() throws {
        let root = try makeRoot()
        let name = "noconfig"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        let store = WorkspaceStore(demoMode: false)
        var login = JamfCLIProfile(name: name, url: "", schedules: 0, status: .idle)
        login.product = .protect
        store.profiles = [login]
        store.profile = name
        store.refreshEnvironmentProducts()
        XCTAssertTrue(store.environmentProducts.isProtectOnly)
        let resolved = ProfileAuthMethod.Resolved(
            authMethod: "oauth2", isTenantLevel: false, product: .protect)
        XCTAssertEqual(
            WorkspaceStore.expectedKinds(profile: name, jamfCLIVersion: "1.35.0", auth: resolved,
                                         protectPinAllows: { _, _ in true }), [])
    }

    /// S8
    @MainActor
    func testGenerateOffersNoJamfProTemplateOrAuditToAProtectOnlyEnvironment() {
        let state = GenerateSheetState()
        state.includeAudit = true
        state.noJamfPro = true
        XCTAssertEqual(state.offeredTemplates.map(\.identifier), ["custom"])
        XCTAssertEqual(state.selectedTemplateID, "custom")
        XCTAssertFalse(state.request().runsAudit)
    }
}
