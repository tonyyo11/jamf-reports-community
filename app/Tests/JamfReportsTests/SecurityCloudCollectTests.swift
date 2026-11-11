import XCTest
@testable import JamfReports

private final class SCLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var texts: [String] { lock.withLock { stored } }
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.withLock { self.stored.append(line.text) } }
    }
}

private final class SCCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var skips: [Set<String>] = []
    var value: Int { lock.withLock { count } }
    var skipSets: [Set<String>] { lock.withLock { skips } }
    func hit(_ skip: Set<String> = []) { lock.withLock { count += 1; skips.append(skip) } }
}

/// The Security Cloud collect: the row allow-list, the engine's honesty chain, and where
/// `CollectRouter` runs it. Tests never run jamf-cli: a stub not named `jamf-cli` stands in.
@MainActor
final class SecurityCloudCollectTests: XCTestCase {
    private var root: URL!
    private var profile = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JRC-SC-\(UUID().uuidString)", isDirectory: true)
        profile = "scws\(Int.random(in: 10000...99999))"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { [root] in
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            if let root { try? FileManager.default.removeItem(at: root) }
        }
    }

    private var fixture: URL { TestFixtures.dir("security-cloud/risk-list.json") }

    private func stub(exit: Int = 0, script: String? = nil) throws -> URL {
        let url = root.appendingPathComponent("bin/stub-cli-\(UUID().uuidString.prefix(6))")
        let body = script ?? "cat '\(fixture.path)'\nexit \(exit)"
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func dataDir() throws -> URL {
        let url = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func savedRows(_ dir: URL) throws -> [[String: Any]] {
        let file = try XCTUnwrap(FileManager.newestJSONFile(
            in: dir.appendingPathComponent(ReportEngine.securityRiskKind)))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
    }

    // MARK: - The allow-list

    func testAFullRowSavesOnlyTheAllowList() async throws {
        let dir = try dataDir()
        let lines = SCLines()
        let bin = try stub()
        let kinds = try await ReportEngine.securityCollect(
            profile: "sc", dataDir: dir, locateJamfCLI: { bin },
            onLine: lines.append)
        XCTAssertEqual(kinds, ["security-risk"])
        let rows = try savedRows(dir)
        XCTAssertEqual(rows.count, 3)
        let allowed: Set<String> = [
            "guid", "externalId", "riskCategory", "status", "connectorState", "deploymentState",
            "lastDnsTraffic", "hardwareSpec",
        ]
        for row in rows {
            XCTAssertTrue(Set(row.keys).isSubset(of: allowed), "\(row.keys)")
            XCTAssertEqual(Set(row.keys), allowed)
            XCTAssertEqual((row["hardwareSpec"] as? [String: Any])?.keys.sorted(), ["osType"])
        }
        XCTAssertEqual(rows.compactMap { $0["riskCategory"] as? String }.sorted(),
                       ["HIGH", "MEDIUM", "SECURE"])
        let raw = try String(contentsOf: XCTUnwrap(FileManager.newestJSONFile(
            in: dir.appendingPathComponent("security-risk"))), encoding: .utf8)
        for secret in ["Example User", "example.invalid", "+1555", "Springfield", "Exampleland",
                       "Example Device", "Example Model", "Example Group", "deviceName",
                       "payload", "latitude", "12.34"] {
            XCTAssertFalse(raw.contains(secret), secret)
        }
    }

    func testReducingDropsNonObjectRowsAndRefusesANonArray() throws {
        let rows = try XCTUnwrap(ReportEngine.reducingSecurityRisk(
            Data(#"[{"guid":"g","user":{"name":"x"}}, 5, "s"]"#.utf8)))
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rows) as? [[String: Any]])
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(Set(decoded[0].keys), ["guid"])
        XCTAssertNil(ReportEngine.reducingSecurityRisk(Data(#"{"guid":"g"}"#.utf8)))
    }

    func testANonScalarValueUnderAnAllowListedKeyIsDropped() throws {
        let json = #"[{"guid":"g","status":{"user":"x"},"riskCategory":["HIGH"],"#
            + #""lastDnsTraffic":5,"hardwareSpec":{"osType":{"a":1}}}]"#
        let data = try XCTUnwrap(ReportEngine.reducingSecurityRisk(Data(json.utf8)))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["guid", "lastDnsTraffic"])
    }

    func testATopLevelNullLandsAnEmptySnapshotWithoutPartial() async throws {
        let dir = try dataDir()
        let lines = SCLines()
        let bin = try stub(script: "printf 'null'")
        let kinds = try await ReportEngine.securityCollect(
            profile: "sc", dataDir: dir, locateJamfCLI: { bin }, onLine: lines.append)
        XCTAssertEqual(kinds, ["security-risk"])
        XCTAssertEqual(try savedRows(dir).count, 0)
        XCTAssertFalse(lines.texts.contains { $0.hasPrefix("[partial]") }, "\(lines.texts)")
    }

    func testAnEmptyArrayLandsAnEmptySnapshotWithoutPartial() async throws {
        let dir = try dataDir()
        let lines = SCLines()
        let bin = try stub(script: "printf '[]'")
        let kinds = try await ReportEngine.securityCollect(
            profile: "sc", dataDir: dir,
            locateJamfCLI: { bin }, onLine: lines.append)
        XCTAssertEqual(kinds, ["security-risk"])
        XCTAssertEqual(try savedRows(dir).count, 0)
        XCTAssertFalse(lines.texts.contains { $0.hasPrefix("[partial]") }, "\(lines.texts)")
    }

    func testAFailureRecordsACauseAndLogsPartial() async throws {
        let dir = try dataDir()
        let lines = SCLines()
        let bin = try stub(script: "printf '{}'; exit 5")
        let kinds = try await ReportEngine.securityCollect(
            profile: "sc", dataDir: dir,
            locateJamfCLI: { bin },
            onLine: lines.append)
        XCTAssertTrue(kinds.isEmpty)
        XCTAssertTrue(lines.texts.contains {
            $0.hasPrefix("[partial]") && $0.contains("did not land") && $0.contains("security-risk")
        }, "\(lines.texts)")
        let store = StateFileStore(directory: dir.appendingPathComponent("state"))
        XCTAssertEqual(store.failures(report: "security-risk")?.count, 1)
        XCTAssertEqual(store.lastFailureExitCode(for: "security-risk"), 5)
        XCTAssertNotNil(store.cause(for: "security-risk"))
        XCTAssertNil(FileManager.newestJSONFile(in: dir.appendingPathComponent("security-risk")))
    }

    func testOutputThatIsNotAnArrayIsAFailureNotASnapshot() async throws {
        let dir = try dataDir()
        let lines = SCLines()
        let bin = try stub(script: "printf 'Usage: jamf-cli security'")
        let kinds = try await ReportEngine.securityCollect(
            profile: "sc", dataDir: dir,
            locateJamfCLI: { bin },
            onLine: lines.append)
        XCTAssertTrue(kinds.isEmpty)
        XCTAssertTrue(lines.texts.contains { $0.hasPrefix("[partial]") })
        XCTAssertNil(FileManager.newestJSONFile(in: dir.appendingPathComponent("security-risk")))
    }

    func testCollectSkipRunsNothingAndRecordsNothing() async throws {
        let dir = try dataDir()
        let lines = SCLines()
        let ran = SCCalls()
        let marker = root.appendingPathComponent("ran")
        let bin = try stub(script: "touch '\(marker.path)'")
        let kinds = try await ReportEngine.securityCollect(
            profile: "sc", dataDir: dir, collectSkip: [ReportEngine.securityRiskKind],
            locateJamfCLI: { ran.hit(); return bin },
            onLine: lines.append)
        XCTAssertTrue(kinds.isEmpty)
        XCTAssertEqual(ran.value, 0, "the binary is not even looked up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(lines.texts.contains(
            "[skip] security-risk: listed in jamf_cli.collect_skip"), "\(lines.texts)")
        XCTAssertFalse(lines.texts.contains { $0.hasPrefix("[partial]") })
        XCTAssertNil(StateFileStore(directory: dir.appendingPathComponent("state"))
            .failures(report: "security-risk"))
    }

    func testThePlanLineAndTheArgvAreTheOnesTheBriefNames() async throws {
        let dir = try dataDir()
        let lines = SCLines()
        let argvLog = root.appendingPathComponent("argv.txt")
        let bin = try stub(script: "echo \"$@\" > '\(argvLog.path)'\nprintf '[]'")
        _ = try await ReportEngine.securityCollect(
            profile: "sc-login", dataDir: dir,
            locateJamfCLI: { bin },
            onLine: lines.append)
        XCTAssertEqual(try String(contentsOf: argvLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            "-p sc-login --no-input security risk list --output json")
        XCTAssertTrue(lines.texts.contains {
            $0 == "[plan] profile sc-login — collecting 1 source: security-risk"
        }, "\(lines.texts)")
    }

    func testSkippableKindsAcceptSecurityRisk() {
        XCTAssertEqual(
            ReportEngine.collectSkipKinds(["security_risk", "bogus"]), ["security-risk"])
    }

    // MARK: - CollectRouter

    private func runRouter(
        yaml: String? = nil, proThrowing: Error? = nil,
        securityThrowing: Error? = nil,
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved? = { _ in nil },
        gate: @escaping CollectRouter.Gate = { _, _, _, _, _, _ in
            .proceed(holdsClaim: false, coordinating: false)
        }
    ) async throws -> (calls: SCCalls, lines: [String], thrown: Error?) {
        let text = yaml ?? "profiles:\n  jamf_pro: \"\(profile)\"\n  security_cloud: \"my-sc\"\n"
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try text.write(to: ws.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
        let config = try ConfigLoader.loadFromString(text)
        let calls = SCCalls()
        let lines = SCLines()
        var thrown: Error?
        do {
            try await CollectRouter.run(
                workspace: WorkspaceID(validating: profile), config: config,
                proCollect: { _, _, _, _, _, _, _ in
                    if let proThrowing { throw proThrowing }
                    return .collected
                },
                schoolCollect: { _, _, _, _, _, _ in },
                protectCollect: { _, _, _ in ["protect-alerts"] },
                securityCollect: { _, _, skip, _ in
                    calls.hit(skip)
                    if let securityThrowing { throw securityThrowing }
                    return ["security-risk"]
                },
                resolved: resolved, gate: gate, onLine: lines.append)
        } catch { thrown = error }
        return (calls, lines.texts, thrown)
    }

    private func login(_ product: JamfCLIProduct, explicit: Bool = true)
        -> @Sendable (String) -> ProfileAuthMethod.Resolved? {
        { name in
            name == "my-sc"
                ? .init(authMethod: "security", isTenantLevel: false, product: product,
                        productIsDefaulted: !explicit)
                : nil
        }
    }

    func testRunsAfterACollectedProRun() async throws {
        let (calls, _, thrown) = try await runRouter(resolved: login(.securityCloud))
        XCTAssertNil(thrown)
        XCTAssertEqual(calls.value, 1)
    }

    func testDoesNotRunWithoutTheSlot() async throws {
        let (calls, _, _) = try await runRouter(yaml: "profiles:\n  jamf_pro: \"\(profile)\"\n")
        XCTAssertEqual(calls.value, 0)
    }

    func testNotAfterAStandDownOrADayGuardStop() async throws {
        for stop in [ReportEngine.CollectDisposition.stoodDown, .alreadyCollected] {
            let (calls, lines, _) = try await runRouter(gate: { _, _, _, _, _, _ in .stop(stop) })
            XCTAssertEqual(calls.value, 0, "\(stop)")
            XCTAssertTrue(lines.contains { $0.hasPrefix("[skip] security-risk:") }, "\(lines)")
        }
    }

    func testAfterAVerdictFailureItRunsAndTheMDMErrorStays() async throws {
        let verdict = ReportEngineError.authExpired(profile: profile, failedCount: 2)
        let (calls, _, thrown) = try await runRouter(proThrowing: verdict)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(thrown?.localizedDescription, verdict.localizedDescription)
    }

    func testNotAfterAPreflightRefusal() async throws {
        let (calls, _, thrown) = try await runRouter(proThrowing: ReportEngineError.jamfCLINotFound)
        XCTAssertEqual(calls.value, 0)
        XCTAssertNotNil(thrown)
    }

    func testASecurityFailureIsNonFatalAndNeverReplacesTheMDMError() async throws {
        let failure = NSError(domain: "t", code: 9)
        let (_, lines, thrown) = try await runRouter(securityThrowing: failure)
        XCTAssertNil(thrown)
        XCTAssertTrue(lines.contains { $0.hasPrefix(ReportEngine.securityCollectFailedMarker) })
        let verdict = ReportEngineError.collectDead(profile: profile, failedCount: 3)
        let (_, _, kept) = try await runRouter(proThrowing: verdict, securityThrowing: failure)
        XCTAssertEqual(kept?.localizedDescription, verdict.localizedDescription)
        let watcher = CollectHonestyWatcher()
        lines.forEach { watcher.observe($0) }
        XCTAssertTrue(watcher.incomplete)
        XCTAssertFalse(watcher.retryCouldHelp { _ in false })
    }

    func testAKnownOtherProductGetsOneWarnAndNothingRuns() async throws {
        for product in [JamfCLIProduct.pro, .school, .protect] {
            let (calls, lines, thrown) = try await runRouter(resolved: login(product))
            XCTAssertNil(thrown)
            XCTAssertEqual(calls.value, 0, "\(product)")
            let warns = lines.filter { $0.hasPrefix("[warn] Jamf Security Cloud not collected") }
            XCTAssertEqual(warns.count, 1, "\(lines)")
            XCTAssertTrue(warns[0].contains(
                "'my-sc' is a \(product.displayName) profile, not a Jamf Security Cloud profile"))
        }
    }

    func testAnUnresolvedOrUnknownOrDefaultedLoginRuns() async throws {
        let answers: [@Sendable (String) -> ProfileAuthMethod.Resolved?] = [
            { _ in nil }, login(.unknown), login(.pro, explicit: false), login(.securityCloud),
        ]
        for answer in answers {
            let (calls, _, _) = try await runRouter(resolved: answer)
            XCTAssertEqual(calls.value, 1)
        }
    }

    func testCollectSkipIsPassedToTheCollect() async throws {
        let yaml = "profiles:\n  jamf_pro: \"\(profile)\"\n  security_cloud: \"my-sc\"\n"
            + "jamf_cli:\n  collect_skip: [security-risk]\n"
        let (calls, _, _) = try await runRouter(yaml: yaml)
        XCTAssertEqual(calls.skipSets, [["security-risk"]])
    }

    func testAHeldOrDriftedPinSkipsWithOneSkipLine() async throws {
        let shared = "shared_workspace:\n  enabled: true\nprofiles:\n"
            + "  jamf_pro: \"\(profile)\"\n  security_cloud: \"my-sc\"\n"
        let (first, firstLines, _) = try await runRouter(yaml: shared)
        XCTAssertEqual(first.value, 0, "held unconfirmed at first sight (D18)")
        try SharedConfigPin.confirm(profile: profile, keys: [.securityCloudProfile])
        let (confirmed, _, _) = try await runRouter(yaml: shared)
        XCTAssertEqual(confirmed.value, 1, "Confirm on this Mac releases it")
        let drifted = shared.replacingOccurrences(of: "my-sc", with: "peer-sc")
        let (calls, lines, _) = try await runRouter(yaml: drifted)
        XCTAssertEqual(calls.value, 0)
        for run in [firstLines, lines] {
            XCTAssertEqual(
                run.filter { $0.hasPrefix("[skip] Jamf Security Cloud not collected") }.count, 1)
            // The checkpoint's own `[warn] shared config changed` line is the one warning.
            XCTAssertFalse(
                run.contains { $0.hasPrefix("[warn] Jamf Security Cloud") }, "\(run)")
        }
        try SharedConfigPin.confirm(profile: profile, keys: [.securityCloudProfile])
        let (again, _, _) = try await runRouter(yaml: drifted)
        XCTAssertEqual(again.value, 1)
    }

    func testAProtectOnlyEnvironmentRunsNoSecurityCollect() async throws {
        let yaml = "profiles:\n  protect: \"\(profile)\"\n  security_cloud: \"my-sc\"\n"
        let (calls, _, thrown) = try await runRouter(yaml: yaml)
        XCTAssertNil(thrown, "the Protect-only run itself succeeds")
        XCTAssertEqual(calls.value, 0)
    }

    func testAProtectOnlyEnvironmentRunsNoSecurityCollectAfterAGateStopEither() async throws {
        let yaml = "profiles:\n  protect: \"\(profile)\"\n  security_cloud: \"my-sc\"\n"
        let (calls, lines, _) = try await runRouter(
            yaml: yaml, gate: { _, _, _, _, _, _ in .stop(.stoodDown) })
        XCTAssertEqual(calls.value, 0)
        XCTAssertFalse(lines.contains { $0.contains("security-risk") }, "\(lines)")
    }

    func testAJamfSchoolEnvironmentCollectsItToo() async throws {
        let yaml = "profiles:\n  jamf_school: \"\(profile)\"\n  security_cloud: \"my-sc\"\n"
        let (calls, _, _) = try await runRouter(yaml: yaml)
        XCTAssertEqual(calls.value, 1)
    }

    // MARK: - Freshness and the Data Sources plan

    func testExpectedKindsIncludeTheKindOnlyWhereTheCollectRuns() throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        func kinds(
            _ yaml: String, product: JamfCLIProduct = .securityCloud, pin: Bool = true
        ) throws -> [String] {
            try yaml.write(to: ws.appendingPathComponent("config.yaml"),
                           atomically: true, encoding: .utf8)
            return WorkspaceStore.expectedKinds(
                profile: profile, jamfCLIVersion: nil, auth: nil,
                protectResolved: { _ in nil },
                securityCloudResolved: { _ in
                    .init(authMethod: "security", isTenantLevel: false, product: product)
                },
                protectPinAllows: { _, _ in true }, securityCloudPinAllows: { _, _ in pin })
        }
        let base = "profiles:\n  jamf_pro: \"\(profile)\"\n  security_cloud: \"my-sc\"\n"
        XCTAssertTrue(try kinds(base).contains("security-risk"))
        XCTAssertFalse(try kinds("profiles:\n  jamf_pro: \"\(profile)\"\n")
            .contains("security-risk"))
        XCTAssertFalse(try kinds(base, pin: false).contains("security-risk"))
        XCTAssertFalse(try kinds(base, product: .school).contains("security-risk"))
        XCTAssertFalse(try kinds(base + "jamf_cli:\n  collect_skip: [security-risk]\n")
            .contains("security-risk"))
        let school = "profiles:\n  jamf_school: \"\(profile)\"\n  security_cloud: \"my-sc\"\n"
        XCTAssertTrue(try kinds(school).contains("security-risk"))
        XCTAssertFalse(try kinds(school + "jamf_cli:\n  collect_skip: [security-risk]\n")
            .contains("security-risk"))
        XCTAssertEqual(DataFreshnessHealth.tier(forKind: "security-risk"), .refresh)
    }

    func testTheSourcesPlanListsItUnderItsOwnGroup() {
        func plan(_ edit: (inout CollectSourcesPlan.Inputs) -> Void) -> CollectSourcesPlan {
            var inputs = CollectSourcesPlan.Inputs(product: .jamfPro, profile: "ws")
            edit(&inputs)
            return CollectSourcesPlan.build(inputs)
        }
        let on = plan { $0.securityCloudProfile = "sc" }.sources(for: .securityCloud)
        XCTAssertEqual(on.map(\.kind), ["security-risk"])
        XCTAssertEqual(on.first?.command, "security risk list")
        XCTAssertNil(on.first?.skipReason)
        XCTAssertTrue(plan { _ in }.sources(for: .securityCloud).isEmpty)
        let refused = plan {
            $0.securityCloudProfile = "sc"; $0.securityCloudRefusal = "wrong product"
        }.sources(for: .securityCloud)
        XCTAssertEqual(refused.first?.skipReason, "wrong product")
        let skipped = plan {
            $0.securityCloudProfile = "sc"; $0.collectSkip = ["security-risk"]
        }.sources(for: .securityCloud)
        XCTAssertEqual(skipped.first?.skipReason, "listed in jamf_cli.collect_skip")
        let school = CollectSourcesPlan.build(.init(
            product: .jamfSchool, profile: "ws", securityCloudProfile: "sc"))
        XCTAssertEqual(school.sources(for: .securityCloud).map(\.kind), ["security-risk"])
    }
}
