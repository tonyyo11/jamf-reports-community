import Foundation
import XCTest
@testable import JamfReports

/// jamf-cli profile names are free text, and admins commonly capitalise them
/// ("Acme", "Acme-Dev-API"). The slug rule used to be lowercase-only, so
/// first-launch setup failed every such profile with "Workspace not found" and
/// the rest of the app treated them as invalid. jamf-cli has no rename command,
/// so the only way round that was re-adding each profile with its secret.
///
/// Allowing capitals makes names that differ only by case possible; on the
/// default case-insensitive volume those share one workspace folder, so the
/// second spelling must never bind it or collect into it. From 2.8.3 every name
/// jamf-cli accepts is usable except a few (`ProfileNameTests`); "Old Tenant ",
/// with its trailing space, stands for those here.
@MainActor
final class ProfileSlugCaseTests: XCTestCase {

    private nonisolated(unsafe) var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-slug-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    // MARK: - Slug rule

    func testIsValidAcceptsCapitalisedJamfCLIProfileNames() {
        let names = ["Acme", "Acme-API", "Acme-Dev", "Acme-Dev-API", "PROD_1", "9Lives"]
        for name in names {
            XCTAssertTrue(ProfileService.isValid(name), "'\(name)' must be a usable profile slug")
        }
    }

    func testIsValidRejectsOnlyNamesItCannotRepresent() {
        for name in ["Acme Dev", "Acme.Dev", "Äcme", "-Acme", "_Acme", "A/B"] {
            XCTAssertTrue(ProfileService.isValid(name), "'\(name)' is a jamf-cli name")
        }
        for name in ["", "Acme ", " Acme", "Acme\tDev", "Acme\nDev"] {
            XCTAssertFalse(ProfileService.isValid(name), "'\(name)' must stay invalid")
        }
    }

    func testUnusableProfilesFlagsUnsupportedNamesAndCaseVariants() {
        XCTAssertEqual(
            ProfileService.unusableProfiles(in: ["Acme", "Acme-API", "Old Tenant "]),
            ["Old Tenant ": .unsupportedName(.edgeWhitespace)]
        )
        // With no workspace folder yet, the lowercase spelling keeps it even when
        // listed second: it is the only one older builds could have created.
        XCTAssertEqual(
            ProfileService.unusableProfiles(in: ["Prod", "prod"], recordedOwner: { _ in nil }),
            ["Prod": .sharesFolder(with: "prod")]
        )
        XCTAssertEqual(
            ProfileService.unusableProfiles(in: ["PROD", "Prod"], recordedOwner: { _ in nil }),
            ["Prod": .sharesFolder(with: "PROD")],
            "without a lowercase spelling, the first listed keeps the folder"
        )
    }

    /// Discovery must agree with the bind and collect guards, which follow the
    /// profile a workspace folder records: that spelling keeps the folder.
    func testTheSpellingAnExistingWorkspaceRecordsKeepsTheFolder() {
        XCTAssertEqual(
            ProfileService.unusableProfiles(in: ["Prod", "prod"], recordedOwner: { _ in "Prod" }),
            ["prod": .sharesFolder(with: "Prod")]
        )
        XCTAssertEqual(
            ProfileService.unusableProfiles(in: ["Prod", "prod"], recordedOwner: { _ in "PROD" }),
            ["Prod": .sharesFolder(with: "prod")],
            "a recorded profile no longer configured falls back to the lowercase spelling"
        )
    }

    func testInitialProfileSkipsProfilesTheAppCannotUse() {
        let unusable = JamfCLIProfile(name: "Old Tenant ", url: "", schedules: 0, status: .error)
        let usable = JamfCLIProfile(name: "Acme", url: "", schedules: 0, status: .idle)
        XCTAssertEqual(WorkspaceStore.initialProfile(in: [unusable, usable])?.name, "Acme")
        XCTAssertEqual(WorkspaceStore.initialProfile(in: [unusable])?.name, "Old Tenant ")
        XCTAssertNil(WorkspaceStore.initialProfile(in: []))

        let both = [unusable, usable]
        XCTAssertEqual(WorkspaceStore.activeProfile(keeping: "Acme", in: both), "Acme")
        XCTAssertEqual(WorkspaceStore.activeProfile(keeping: "Old Tenant ", in: both), "Acme",
                       "a reload moves off a profile that became unusable")
        XCTAssertEqual(WorkspaceStore.activeProfile(keeping: "gone", in: both), "Acme")
        XCTAssertNil(WorkspaceStore.activeProfile(keeping: "Acme", in: []))
    }

    func testIsCaseVariantOnlyMatchesAnotherSpellingOfTheSameName() {
        XCTAssertTrue(ProfileService.isCaseVariant("acme", of: "Acme"))
        XCTAssertFalse(ProfileService.isCaseVariant("Acme", of: "Acme"))
        XCTAssertFalse(ProfileService.isCaseVariant("", of: "Acme"), "unset owns nothing")
        XCTAssertFalse(ProfileService.isCaseVariant("acme-dev", of: "Acme"))
    }

    /// Discovery lists every configured profile, marking the unusable ones so
    /// Settings greys them out and multi-profile runs skip them. The JSON is what
    /// jamf-cli 1.31.1's `config list --output json` printed for these profiles:
    /// names verbatim in byte order, `auth-method` empty when unset.
    func testDiscoveryKeepsCapitalisedProfilesUsable() throws {
        let stub = tempRoot.appendingPathComponent("fake-cli")
        let json = #"[{"name":"Acme","url":"https://acme.example.invalid","auth-method":"oauth2","#
            + #""default":true},"#
            + #"{"name":"Acme Prod","url":"https://acme-prod.example.invalid","auth-method":""},"#
            + #"{"name":"Acme-Dev","url":"https://acme-dev.example.invalid","#
            + #""auth-method":"oauth2"},"#
            + #"{"name":"Old Tenant ","url":"https://old.example.invalid","auth-method":""},"#
            + #"{"name":"acme-dev","url":"https://other.example.invalid","auth-method":""}]"#
        try Data("#!/bin/sh\nprintf '%s' '\(json)'\n".utf8).write(to: stub)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: stub.path
        )

        let rows = ProfileService.discoverJamfCLIProfiles(
            scheduleCounts: [:], _testBinaryOverride: stub
        )
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })

        XCTAssertEqual(byName["Acme"]?.status, .ok)
        XCTAssertEqual(byName["Acme"]?.authMethod, "oauth2")
        XCTAssertEqual(byName["Acme"]?.url, "acme.example.invalid")
        XCTAssertEqual(byName["acme-dev"]?.status, .idle)
        XCTAssertEqual(byName["Acme-Dev"]?.status, .error)
        XCTAssertEqual(byName["Acme-Dev"]?.authMethod, "(same folder as acme-dev)")
        XCTAssertEqual(byName["Acme Prod"]?.status, .idle, "a space is fine from 2.8.3")
        XCTAssertEqual(byName["Old Tenant "]?.status, .error)
        XCTAssertEqual(byName["Old Tenant "]?.authMethod, "(unsupported name)")
    }

    /// The config-file fallback (jamf-cli missing or failing) reads the same
    /// file `config list` does; this is the config that produced the JSON above.
    func testFallbackReaderMarksTheSameProfilesAsConfigList() throws {
        let config = tempRoot.appendingPathComponent("config.yaml")
        try Data("""
        default-profile: Acme
        profiles:
            Acme:
                url: https://acme.example.invalid
                auth-method: oauth2
            Acme-Dev:
                url: https://acme-dev.example.invalid
            acme-dev:
                url: https://other.example.invalid
            "Old Tenant ":
                url: https://old.example.invalid
            Acme Prod:
                url: https://acme-prod.example.invalid

        """.utf8).write(to: config)

        let rows = ProfileService.fallbackConfigProfiles(scheduleCounts: [:], configURL: config)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })

        XCTAssertEqual(rows.count, 5, "unusable profiles stay listed so Settings can say why")
        XCTAssertEqual(byName["Acme"]?.status, .ok)
        XCTAssertEqual(byName["acme-dev"]?.status, .idle)
        XCTAssertEqual(byName["Acme-Dev"]?.authMethod, "(same folder as acme-dev)")
        XCTAssertEqual(byName["Old Tenant "]?.authMethod, "(unsupported name)",
                       "a quoted key is read without its quotes")
        XCTAssertEqual(byName["Acme Prod"]?.status, .idle)
    }

    func testLocalWorkspaceMergeTreatsADifferentSpellingAsTheProfilesFolder() throws {
        for (folder, hasConfig) in [("acme", true), ("Other", true), ("NoConfig", false)] {
            let dir = tempRoot.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if hasConfig {
                try Data("jamf_cli: {}\n".utf8).write(to: dir.appendingPathComponent("config.yaml"))
            }
        }
        XCTAssertEqual(
            ProfileService.localOnlyWorkspaces(under: tempRoot, cliNames: ["Acme"]), ["Other"],
            "a folder named like a jamf-cli profile apart from case is not a second workspace"
        )
    }

    func testMultiProfileRunsSkipProfilesTheAppCannotUse() {
        let profiles = [
            JamfCLIProfile(name: "Acme", url: "", schedules: 0, status: .ok),
            JamfCLIProfile(name: "Old Tenant ", url: "", schedules: 0, status: .error),
            JamfCLIProfile(name: "prod", url: "", schedules: 0, status: .idle),
        ]
        XCTAssertEqual(
            ProfileService.runnableProfiles(profiles, excluding: ["prod"]).map(\.name), ["Acme"]
        )
    }

    // MARK: - First-launch setup (the reported failure)

    #if DEBUG
    /// The field report: every capitalised profile failed setup with
    /// "Workspace not found for profile 'Acme'." Runs the real workspace
    /// initializer; only the network collect is stubbed.
    func testSetupInitializesWorkspaceForCapitalisedProfile() async throws {
        let flow = ExistingCLISetupFlow(profileNames: ["Acme-Dev"])
        await flow.run(collect: { _, _ in 0 })

        XCTAssertEqual(flow.statuses["Acme-Dev"], .done)
        let config = tempRoot.appendingPathComponent("Acme-Dev/config.yaml")
        XCTAssertEqual(try ConfigLoader.load(from: config).jamfCli?.profile, "Acme-Dev",
                       "jamf-cli is called with -p exactly as the profile is spelled")
    }
    #endif

    func testSetupNeverSelectsOrRunsProfilesItCannotUse() async {
        let flow = ExistingCLISetupFlow(profileNames: ["Acme", "Old Tenant ", "ACME"])
        XCTAssertEqual(flow.unusable["Old Tenant "], .unsupportedName(.edgeWhitespace))
        XCTAssertEqual(flow.unusable["ACME"], .sharesFolder(with: "Acme"))
        XCTAssertEqual(flow.selected, ["Acme"])

        flow.selected.insert("Old Tenant ")
        var initialized: [String] = []
        await flow.run(
            initialize: { initialized.append($0); return 0 },
            collect: { _, _ in 0 }
        )
        XCTAssertEqual(initialized, ["Acme"])
    }

    // MARK: - Errors name the real cause

    func testInitializeWorkspaceRejectsUnsupportedNameWithItsReason() async {
        do {
            _ = try await CLIBridge().initializeWorkspace(
                profile: "Old Tenant ", onLine: CLIBridge.noOpOnLine
            )
            XCTFail("an unsupported name must not initialize")
        } catch let error as CLIBridgeError {
            XCTAssertEqual(error, .invalidProfile("Old Tenant "))
            XCTAssertFalse(error.localizedDescription.contains("not found"),
                           "the reported failure blamed a missing workspace")
            XCTAssertTrue(error.localizedDescription.contains("starts or ends with a space"),
                          "the message says what is wrong with the name")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Binding records the profile through the scoped writer

    /// Binding rewrites `jamf_cli:` to record the profile. A comment there is not kept, so the
    /// file is copied first and the run log names the copy; a key the app does not read stays.
    func testBindingBacksUpACommentInsideJamfCLIAndSaysWhere() async throws {
        let workspace = tempRoot.appendingPathComponent("acme", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        try Data("jamf_cli:\n  # tenant A\n  profile: \"\"\n  team_key: keep\n".utf8)
            .write(to: config)
        let lines = CaseTestBox<[String]>([])

        _ = try await CLIBridge().initializeWorkspace(profile: "acme") { line in
            lines.value.append(line.text)
        }

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("profile: acme") || text.contains("profile: \"acme\""), text)
        XCTAssertTrue(text.contains("team_key: keep"), text)
        let copies = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
            .filter { $0.hasPrefix("config.yaml.bak-") }
        XCTAssertEqual(copies.count, 1, "\(copies)")
        let copy = try XCTUnwrap(copies.first)
        let copied = try String(
            contentsOf: workspace.appendingPathComponent(copy), encoding: .utf8)
        XCTAssertTrue(copied.contains("# tenant A"), copied)
        XCTAssertTrue(lines.value.contains { $0.contains(copy) }, "\(lines.value)")
    }

    /// A `jamf_cli` typed as a single value is left as typed, and the error names the key and
    /// the fix: not "could not be parsed" (the file parsed), and no path.
    func testBindingRefusesAJamfCLIBlockTypedAsAValue() async throws {
        let workspace = tempRoot.appendingPathComponent("acme", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        let typed = Data("jamf_cli: off\ncolumns:\n  serial_number: Serial\n".utf8)
        try typed.write(to: config)

        do {
            _ = try await CLIBridge().initializeWorkspace(
                profile: "acme", onLine: CLIBridge.noOpOnLine)
            XCTFail("a jamf_cli typed as a value must not be bound")
        } catch let error as CLIBridgeError {
            guard case .configWriteRefused = error else { return XCTFail("got \(error)") }
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("jamf_cli"), text)
            XCTAssertFalse(text.contains("parsed"), text)
            XCTAssertFalse(text.contains(tempRoot.path), text)
            XCTAssertFalse(text.contains(".."), text)
        }
        XCTAssertEqual(try Data(contentsOf: config), typed)
    }

    /// A workspace seeded from the shipped example is written with the profile recorded, so
    /// binding it writes nothing and no backup of a file the app just made is kept.
    func testBindingASeededWorkspaceKeepsNoBackupOfTheSeed() async throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.example.yaml").path) {
            guard dir.pathComponents.count > 1 else { throw XCTSkip("no config.example.yaml") }
            dir = dir.deletingLastPathComponent()
        }
        try ReportEngine.initializeWorkspace(
            profile: "Seeded", workspacesRoot: tempRoot,
            seedConfigURL: dir.appendingPathComponent("config.example.yaml"), onLine: { _ in })
        let lines = CaseTestBox<[String]>([])

        _ = try await CLIBridge().initializeWorkspace(profile: "Seeded") { line in
            lines.value.append(line.text)
        }

        let workspace = tempRoot.appendingPathComponent("Seeded", isDirectory: true)
        let text = try String(
            contentsOf: workspace.appendingPathComponent("config.yaml"), encoding: .utf8)
        let loaded = try ConfigService.load(profile: "Seeded", workspaceRoot: tempRoot)
        XCTAssertEqual(loaded.document.root.mapping?.value(for: "jamf_cli")?.mapping?
            .value(for: "profile")?.stringValue, "Seeded")
        XCTAssertTrue(text.contains("# jamf-reports community edition — example configuration"))
        let copies = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
            .filter { $0.hasPrefix("config.yaml.bak-") }
        XCTAssertEqual(copies, [])
        XCTAssertFalse(lines.value.contains { $0.contains("a copy of config.yaml") },
                       "\(lines.value)")
    }

    // MARK: - Case variants never share a workspace

    #if DEBUG
    /// Written into the folder `Acme` resolves to, so the test holds on a
    /// case-sensitive volume too.
    private func writeWorkspace(folder: String, recordedProfile: String) throws -> URL {
        let workspace = tempRoot.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        try Data("jamf_cli:\n  profile: \"\(recordedProfile)\"\n".utf8).write(to: config)
        return config
    }

    func testBindingRefusesAWorkspaceRecordedForACaseVariant() async throws {
        let config = try writeWorkspace(folder: "Acme", recordedProfile: "acme")
        do {
            _ = try await CLIBridge().initializeWorkspace(
                profile: "Acme", onLine: CLIBridge.noOpOnLine
            )
            XCTFail("a case variant must not take over another profile's workspace")
        } catch let error as CLIBridgeError {
            XCTAssertEqual(error, .profileCaseConflict(profile: "Acme", owner: "acme"))
        }
        XCTAssertEqual(try ConfigLoader.load(from: config).jamfCli?.profile, "acme",
                       "the owner's jamf_cli.profile must not be rewritten")
    }

    func testCaseVariantWorkspaceFindsADifferentlySpelledFolder() throws {
        _ = try writeWorkspace(folder: "acme", recordedProfile: "acme")
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("prod"), withIntermediateDirectories: true
        )
        XCTAssertEqual(ProfileService.caseVariantWorkspace(of: "Acme"), "acme")
        XCTAssertNil(ProfileService.caseVariantWorkspace(of: "acme"), "its own folder")
        XCTAssertNil(ProfileService.caseVariantWorkspace(of: "Prod"), "no config.yaml")
    }

    func testRecordedWorkspaceOwnerReadsTheFolderConfig() throws {
        _ = try writeWorkspace(folder: "Prod", recordedProfile: "Prod")
        _ = try writeWorkspace(folder: "blank", recordedProfile: "")
        XCTAssertEqual(ProfileService.recordedWorkspaceOwner(matching: "prod"), "Prod")
        XCTAssertEqual(
            ProfileService.unusableProfiles(in: ["prod", "Prod"]),
            ["prod": .sharesFolder(with: "Prod")]
        )
        XCTAssertEqual(ProfileService.recordedWorkspaceOwner(matching: "blank"), "blank",
                       "a blank jamf_cli.profile falls back to the folder name")
        XCTAssertNil(ProfileService.recordedWorkspaceOwner(matching: "absent"))
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("Bare"), withIntermediateDirectories: true
        )
        XCTAssertNil(ProfileService.recordedWorkspaceOwner(matching: "bare"),
                     "a folder without config.yaml is not a workspace")
    }

    /// Audit and Refresh write for the active profile without binding its
    /// workspace, so an unusable profile must never become active.
    func testAnUnusableProfileNeverBecomesActiveOrCountsAsInitialized() throws {
        _ = try writeWorkspace(folder: "Acme", recordedProfile: "Acme")
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(), jamfCLIProfileNames: { [] }
        )
        store.profiles = [
            JamfCLIProfile(name: "Acme", url: "", schedules: 0, status: .ok),
            JamfCLIProfile(name: "ACME", url: "", schedules: 0, status: .error),
        ]
        store.profile = "Acme"

        store.setProfile("ACME")

        XCTAssertEqual(store.profile, "Acme")
        XCTAssertEqual(store.toast?.message.hasPrefix("ACME can't be used. Matches Acme"), true)
        XCTAssertEqual(store.initializedProfiles.map(\.name), ["Acme"],
                       "the owner's folder answers to ACME too; count it once")
    }

    func testBindingReportsAMalformedConfigAsAConfigProblem() async throws {
        let workspace = tempRoot.appendingPathComponent("acme", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("- one\n- two\n".utf8).write(to: workspace.appendingPathComponent("config.yaml"))
        do {
            _ = try await CLIBridge().initializeWorkspace(
                profile: "acme", onLine: CLIBridge.noOpOnLine
            )
            XCTFail("a malformed config.yaml must not bind")
        } catch let error as CLIBridgeError {
            guard case .configLoadFailed = error else { return XCTFail("got \(error)") }
        }
    }

    func testOnboardingRefusesANameThatDiffersOnlyByCaseFromAWorkspace() throws {
        _ = try writeWorkspace(folder: "acme", recordedProfile: "acme")
        let flow = OnboardingFlow()
        flow.profileName = "Acme"
        XCTAssertThrowsError(try flow.createWorkspace()) { error in
            guard case OnboardingFlow.FlowError.profileCaseConflict(let existing) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(existing, "acme")
        }
    }
    #endif

    func testCollectRouterRefusesAWorkspaceRecordedForACaseVariant() async throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  profile: \"acme\"\n")
        let collected = CaseTestBox(false)
        let proCollect: CollectRouter.ProCollect = { _, _, _, _, _, _ in
            collected.value = true
            return .collected
        }

        do {
            try await CollectRouter.run(
                profile: "Acme", config: config, proCollect: proCollect, onLine: { _ in }
            )
            XCTFail("collect must not write into a case variant's workspace")
        } catch let error as CLIBridgeError {
            XCTAssertEqual(error, .profileCaseConflict(profile: "Acme", owner: "acme"))
        }
        XCTAssertFalse(collected.value)

        try await CollectRouter.run(
            profile: "acme", config: config, proCollect: proCollect, onLine: { _ in }
        )
        XCTAssertTrue(collected.value, "the owning profile still collects")
    }

    /// Only a case variant is refused: a workspace recording some other name, or
    /// none, is the ordinary unbound or hand-edited case and still collects.
    func testCollectRouterOnlyRefusesACaseVariant() async throws {
        for recorded in ["acme-dev", ""] {
            let config = try ConfigLoader.loadFromString("jamf_cli:\n  profile: \"\(recorded)\"\n")
            let collected = CaseTestBox(false)
            try await CollectRouter.run(
                profile: "Acme", config: config,
                proCollect: { _, _, _, _, _, _ in collected.value = true; return .collected },
                onLine: { _ in }
            )
            XCTAssertTrue(collected.value, "recorded '\(recorded)' is not another spelling of Acme")
        }
    }
}

private final class CaseTestBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
