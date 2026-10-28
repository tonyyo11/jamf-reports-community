import XCTest
@testable import JamfReports

/// Add environments and Update credentials for all, with jamf-cli, the workspace folders and
/// the checks injected: no test registers a profile or launches jamf-cli.
@MainActor
final class ConnectionCredentialsModelTests: XCTestCase {

    private actor Recorder {
        var registrations: [ConnectionCredentialsModel.Registration] = []
        var checked: [String] = []
        func record(_ registration: ConnectionCredentialsModel.Registration) {
            registrations.append(registration)
        }
        func record(checked profile: String) { checked.append(profile) }
    }

    private final class Provisioned {
        var profiles: [String] = []
    }

    /// Verdicts that replace the harness's for later runs.
    private final class LaterVerdicts: @unchecked Sendable {
        private let lock = NSLock()
        private var byProfile: [String: ConnectionCheck.Verdict] = [:]
        func set(_ verdict: ConnectionCheck.Verdict, for profile: String) {
            lock.lock(); byProfile[profile] = verdict; lock.unlock()
        }
        func verdict(for profile: String) -> ConnectionCheck.Verdict? {
            lock.lock(); defer { lock.unlock() }
            return byProfile[profile]
        }
    }

    /// The jamf-cli profile list, which a test changes between runs.
    private final class ProfileNames {
        var names: [String]
        init(_ names: [String]) { self.names = names }
    }

    private struct Harness {
        let model: ConnectionCredentialsModel
        let store: ConnectionStore
        let recorder: Recorder
        let provisioned: Provisioned
        let connectionID: UUID
        let profiles: ProfileNames
        let later: LaterVerdicts
    }

    private let context = ConnectionCredentialsModel.JamfCLIContext(
        binary: URL(fileURLWithPath: "/nonexistent/stub-cli"))

    private func harness(
        mode: ConnectionCredentialsModel.Mode,
        members: [Connection.Member] = [
            .init(profile: "acme-prod", scopeID: "env-prod", label: "Prod", product: .unknown),
        ],
        verdicts: [String: ConnectionCheck.Verdict] = [:],
        failRegistration: Set<String> = [],
        existingProfiles: [String] = ["acme-prod"],
        reRegistrable: Set<String> = [],
        usesStoredLeftoverRule: Bool = false,
        region: Connection.Region = .eu,
        gatewayURL: String? = nil
    ) throws -> Harness {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("credentials-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ConnectionStore(url: dir.appendingPathComponent("connections.json"))
        let connection = Connection(
            name: "Acme", region: region, level: .environment, members: members,
            gatewayURL: gatewayURL)
        try store.upsert(connection)
        let recorder = Recorder()
        let provisioned = Provisioned()
        let profiles = ProfileNames(existingProfiles)
        let later = LaterVerdicts()
        let context = self.context
        let dependencies = ConnectionCredentialsModel.Dependencies(
            jamfCLI: { context },
            register: { _, registration in
                await recorder.record(registration)
                if failRegistration.contains(registration.profile) {
                    throw OnboardingFlow.FlowError.processFailed("jamf-cli exited 1.")
                }
            },
            check: { _, profile in
                await recorder.record(checked: profile)
                return later.verdict(for: profile) ?? verdicts[profile]
                    ?? .accepted(jamfProVersion: "11.25.0")
            },
            existingProfiles: { profiles.names },
            workspaceConflict: { _ in nil },
            provisionWorkspace: { provisioned.profiles.append($0); return true },
            store: store,
            canReRegister: { name in
                guard usesStoredLeftoverRule else { return reRegistrable.contains(name) }
                return ConnectionCredentialsModel.isLeftoverPlatformProfile(
                    JamfCLIProfile(
                        name: name, url: "", schedules: 0, status: .idle,
                        authMethod: "platform"),
                    connections: store.load(), workspaceExists: false)
            })
        let model = ConnectionCredentialsModel(
            connection: connection, mode: mode, dependencies: dependencies)
        return Harness(
            model: model, store: store, recorder: recorder, provisioned: provisioned,
            connectionID: connection.id, profiles: profiles, later: later)
    }

    private func fill(_ model: ConnectionCredentialsModel, ids: String = "") {
        model.idsText = ids
        model.clientID = "client-id-1234"
        model.setSecret(Data("s3cret-value".utf8))
    }

    private func members(_ harness: Harness) -> [Connection.Member] {
        harness.store.load().first { $0.id == harness.connectionID }?.members ?? []
    }

    // MARK: Add environments

    func testAnAcceptedIDRegistersChecksProvisionsAndJoinsTheConnection() async throws {
        let h = try harness(mode: .addEnvironments)
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()

        XCTAssertEqual(h.model.rows.map(\.outcome),
                       [.added(jamfProVersion: "11.25.0", workspaceNote: nil)])
        XCTAssertEqual(h.provisioned.profiles, ["acme-staging"])
        let added = members(h).first { $0.profile == "acme-staging" }
        XCTAssertEqual(added?.scopeID, "env-stage")
        XCTAssertEqual(added?.label, "Staging")
        XCTAssertEqual(added?.product, .pro)
        let registrations = await h.recorder.registrations
        XCTAssertEqual(registrations.count, 1)
        XCTAssertEqual(registrations[0].gatewayURL, "https://eu.api.jamfcloud.com")
        XCTAssertEqual(registrations[0].scope, .environment)
        XCTAssertEqual(registrations[0].clientSecret, Data("s3cret-value".utf8))
    }

    func testNoJamfProAddsNothingAndPointsAtJamfSchool() async throws {
        let h = try harness(mode: .addEnvironments, verdicts: ["acme-school": .noJamfPro])
        fill(h.model, ids: "env-school School")
        await h.model.run()

        let row = try XCTUnwrap(h.model.rows.first)
        XCTAssertEqual(row.outcome, .notJamfPro)
        XCTAssertTrue(row.suggestsJamfSchool)
        XCTAssertTrue(row.leavesProfileRegistered)
        XCTAssertTrue(row.message.contains("jamf-cli config remove-profile acme-school"))
        XCTAssertTrue(h.provisioned.profiles.isEmpty)
        XCTAssertEqual(members(h).map(\.profile), ["acme-prod"])
    }

    func testARejectedIDAddsNothingAndKeepsTheProfileItRegistered() async throws {
        let h = try harness(
            mode: .addEnvironments,
            verdicts: ["acme-typo": .rejectedID(.unknownEnvironment)])
        fill(h.model, ids: "env-typo Typo")
        await h.model.run()

        let row = try XCTUnwrap(h.model.rows.first)
        XCTAssertEqual(row.outcome, .rejected(.unknownEnvironment))
        XCTAssertFalse(row.suggestsJamfSchool)
        XCTAssertTrue(row.leavesProfileRegistered)
        XCTAssertTrue(h.provisioned.profiles.isEmpty)
        XCTAssertEqual(members(h).map(\.profile), ["acme-prod"])
    }

    func testAMissingPermissionAddsNothingAndNamesIt() async throws {
        let h = try harness(
            mode: .addEnvironments,
            verdicts: ["acme-perm": .missingPermission(names: ["Settings: Read"])])
        fill(h.model, ids: "env-perm Perm")
        await h.model.run()

        let row = try XCTUnwrap(h.model.rows.first)
        XCTAssertEqual(row.outcome, .missingPermission(names: ["Settings: Read"]))
        XCTAssertFalse(row.suggestsJamfSchool)
        XCTAssertFalse(row.isSuccess)
        XCTAssertTrue(row.leavesProfileRegistered)
        XCTAssertTrue(row.message.contains("Settings: Read"), row.message)
        XCTAssertTrue(h.provisioned.profiles.isEmpty)
        XCTAssertEqual(members(h).map(\.profile), ["acme-prod"])
    }

    func testAnUndecidedCheckAddsNothing() async throws {
        let h = try harness(
            mode: .addEnvironments, verdicts: ["acme-slow": .undecided(exitCode: -2)])
        fill(h.model, ids: "env-slow Slow")
        await h.model.run()

        XCTAssertEqual(h.model.rows.map(\.outcome), [.notConfirmed(exitCode: -2)])
        XCTAssertTrue(h.provisioned.profiles.isEmpty)
        XCTAssertEqual(members(h).map(\.profile), ["acme-prod"])
    }

    func testAFailedRegistrationRunsNoCheck() async throws {
        let h = try harness(mode: .addEnvironments, failRegistration: ["acme-staging"])
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()

        guard case .registrationFailed = h.model.rows.first?.outcome else {
            return XCTFail("expected a registration failure")
        }
        let checked = await h.recorder.checked
        XCTAssertTrue(checked.isEmpty)
        XCTAssertFalse(h.model.didChange)
    }

    func testANameThatExistsIsRefusedWithoutRegistering() async throws {
        let h = try harness(mode: .addEnvironments, existingProfiles: ["acme-prod", "acme-staging"])
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()

        XCTAssertEqual(h.model.rows.map(\.outcome), [.refused(.profileExists("acme-staging"))])
        let registrations = await h.recorder.registrations
        XCTAssertTrue(registrations.isEmpty)
    }

    func testALeftoverProfileFromAnEarlierAttemptIsRegisteredAgain() async throws {
        let h = try harness(
            mode: .addEnvironments, existingProfiles: ["acme-prod", "acme-staging"],
            reRegistrable: ["acme-staging"])
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()

        let row = try XCTUnwrap(h.model.rows.first)
        XCTAssertEqual(row.outcome, .added(jamfProVersion: "11.25.0", workspaceNote: nil))
        XCTAssertTrue(row.reRegistered)
        XCTAssertTrue(row.message.contains("registered the earlier jamf-cli profile again"))
        let registrations = await h.recorder.registrations
        XCTAssertEqual(registrations.map(\.profile), ["acme-staging"])
        XCTAssertEqual(members(h).map(\.profile).sorted(), ["acme-prod", "acme-staging"])
    }

    func testAProfileThatIsNotALeftoverIsStillRefused() async throws {
        let h = try harness(
            mode: .addEnvironments, existingProfiles: ["acme-prod", "acme-staging"],
            reRegistrable: ["somebody-else"])
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()

        XCTAssertEqual(h.model.rows.map(\.outcome), [.refused(.profileExists("acme-staging"))])
        let registrations = await h.recorder.registrations
        XCTAssertTrue(registrations.isEmpty)
    }

    func testAProfileTheAppRegisteredButCouldNotConfirmIsRegisteredAgain() async throws {
        let h = try harness(
            mode: .addEnvironments, verdicts: ["acme-staging": .undecided(exitCode: 1)],
            usesStoredLeftoverRule: true)
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()

        let first = try XCTUnwrap(h.model.rows.first)
        XCTAssertEqual(first.outcome, .notConfirmed(exitCode: 1))
        XCTAssertEqual(h.store.load().first?.unconfirmedProfiles, ["acme-staging"])

        // The profile is now in jamf-cli, and the second check accepts the ID.
        h.profiles.names.append("acme-staging")
        h.later.set(.accepted(jamfProVersion: "11.25.0"), for: "acme-staging")
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()

        let second = try XCTUnwrap(h.model.rows.first)
        XCTAssertEqual(second.outcome, .added(jamfProVersion: "11.25.0", workspaceNote: nil))
        XCTAssertTrue(second.reRegistered)
        let registrations = await h.recorder.registrations
        XCTAssertEqual(registrations.map(\.profile), ["acme-staging", "acme-staging"])
        XCTAssertEqual(members(h).map(\.profile).sorted(), ["acme-prod", "acme-staging"])
        XCTAssertEqual(h.store.load().first?.unconfirmedProfiles, [],
                       "a confirmed profile is a member, not a leftover")
    }

    func testAProfileMadeOutsideTheAppIsRefusedEvenWithTheShapeOfALeftover() async throws {
        // Platform, in no connection, no workspace folder: made in Terminal, not by this app.
        let h = try harness(
            mode: .addEnvironments, existingProfiles: ["acme-prod", "acme-staging"],
            usesStoredLeftoverRule: true)
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()

        XCTAssertEqual(h.model.rows.map(\.outcome), [.refused(.profileExists("acme-staging"))])
        let row = try XCTUnwrap(h.model.rows.first)
        XCTAssertTrue(row.message.contains("not made by this app"))
        let registrations = await h.recorder.registrations
        XCTAssertTrue(registrations.isEmpty, "the outside profile's credentials are untouched")
        XCTAssertEqual(h.store.load().first?.unconfirmedProfiles, [])
    }

    func testAMemberOrAWorkspaceProfileIsNotALeftover() {
        let member = Connection(
            name: "Acme", region: .eu, level: .environment,
            members: [.init(profile: "acme-prod", scopeID: "e", label: "Prod", product: .pro)],
            unconfirmedProfiles: ["acme-staging", "acme-prod"])
        func isLeftover(
            _ name: String, auth: String = "platform", workspace: Bool = false
        ) -> Bool {
            ConnectionCredentialsModel.isLeftoverPlatformProfile(
                JamfCLIProfile(name: name, url: "", schedules: 0, status: .idle, authMethod: auth),
                connections: [member], workspaceExists: workspace)
        }
        XCTAssertTrue(isLeftover("acme-staging"))
        XCTAssertFalse(isLeftover("acme-other"), "not registered by this app")
        XCTAssertFalse(isLeftover("acme-prod"), "a member")
        XCTAssertFalse(isLeftover("acme-staging", workspace: true), "has a workspace folder")
        XCTAssertFalse(isLeftover("acme-staging", auth: "oauth2"), "not a Platform profile")
    }

    func testEachIDGetsItsOwnOutcome() async throws {
        let h = try harness(
            mode: .addEnvironments,
            verdicts: ["acme-b": .noJamfPro, "acme-c": .rejectedID(.scopeRejected)])
        fill(h.model, ids: "env-a A\nenv-b B\nenv-c C")
        await h.model.run()

        XCTAssertEqual(h.model.rows.map(\.isSuccess), [true, false, false])
        XCTAssertEqual(h.provisioned.profiles, ["acme-a"])
        XCTAssertEqual(members(h).map(\.profile), ["acme-prod", "acme-a"])
    }

    // MARK: Secret

    func testTheSecretIsClearedWhenARunFinishes() async throws {
        let h = try harness(mode: .addEnvironments)
        fill(h.model, ids: "env-stage Staging")
        h.model.secretFieldHasText = true
        await h.model.run()

        XCTAssertTrue(h.model.clientSecret.isEmpty)
        XCTAssertFalse(h.model.secretFieldHasText)
        XCTAssertFalse(h.model.canRun)
    }

    func testTheSecretIsClearedWhenARunStopsEarly() async throws {
        let h = try harness(mode: .addEnvironments, failRegistration: ["acme-staging"])
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()
        XCTAssertTrue(h.model.clientSecret.isEmpty)
    }

    func testClosingTheSheetClearsATypedSecret() throws {
        let h = try harness(mode: .addEnvironments)
        fill(h.model, ids: "env-stage Staging")
        h.model.secretFieldHasText = true
        h.model.close()
        XCTAssertTrue(h.model.clientSecret.isEmpty)
        XCTAssertFalse(h.model.secretFieldHasText)
    }

    func testClosingTheSheetZeroesTheStoredSecret() throws {
        let h = try harness(mode: .addEnvironments)
        XCTAssertTrue(try secretBufferIsZeroed(store: { h.model.setSecret($0) }, clear: {
            h.model.close()
        }))
        XCTAssertTrue(h.model.clientSecret.isEmpty)
    }

    func testARunNeedsASecretAndAKnownRegion() throws {
        let h = try harness(mode: .addEnvironments)
        h.model.idsText = "env-stage"
        h.model.clientID = "client-id-1234"
        XCTAssertFalse(h.model.canRun)
        h.model.setSecret(Data("x".utf8))
        XCTAssertTrue(h.model.canRun)

        let other = try harness(mode: .addEnvironments, region: .other)
        fill(other.model, ids: "env-stage")
        XCTAssertFalse(other.model.canRun)
    }

    // MARK: Update credentials for all

    func testUpdateAllRegistersEveryMemberWithItsOwnID() async throws {
        let h = try harness(
            mode: .updateAll,
            members: [
                .init(profile: "acme-prod", scopeID: "env-prod", label: "Prod"),
                .init(profile: "acme-stage", scopeID: "env-stage", label: "Stage"),
                .init(profile: "acme-blank", scopeID: "", label: "Blank"),
            ],
            verdicts: ["acme-stage": .rejectedID(.scopeRejected)])
        fill(h.model)
        await h.model.run()

        let registrations = await h.recorder.registrations
        XCTAssertEqual(registrations.map(\.profile), ["acme-prod", "acme-stage"])
        XCTAssertEqual(registrations.map(\.scopeID), ["env-prod", "env-stage"])
        XCTAssertEqual(h.model.rows.map(\.profile), ["acme-prod", "acme-stage", "acme-blank"])
        XCTAssertEqual(h.model.rows[0].outcome, .updated(jamfProVersion: "11.25.0"))
        XCTAssertEqual(h.model.rows[1].outcome, .rejected(.scopeRejected))
        guard case .skipped = h.model.rows[2].outcome else { return XCTFail("expected a skip") }
        XCTAssertFalse(h.model.rows[1].leavesProfileRegistered)
        XCTAssertEqual(members(h).first { $0.profile == "acme-prod" }?.product, .pro)
        XCTAssertTrue(h.model.clientSecret.isEmpty)
    }

    /// A stored ID that could read as a flag, or holds other characters, is never sent to jamf-cli.
    func testUpdateAllSkipsAStoredIDThatIsNotUsable() async throws {
        let h = try harness(
            mode: .updateAll,
            members: [
                .init(profile: "acme-prod", scopeID: "env-prod", label: "Prod"),
                .init(profile: "acme-flag", scopeID: "--insecure", label: "Flag"),
                .init(profile: "acme-space", scopeID: "env prod", label: "Space"),
            ])
        fill(h.model)
        await h.model.run()

        let registrations = await h.recorder.registrations
        XCTAssertEqual(registrations.map(\.profile), ["acme-prod"])
        for row in h.model.rows.dropFirst() {
            guard case .skipped(let reason) = row.outcome else { return XCTFail("expected a skip") }
            XCTAssertTrue(reason.contains("cannot be used"), reason)
            XCTAssertFalse(reason.contains("--insecure"), reason)
        }
    }

    // MARK: Leaving a connection

    func testRemovingAMemberLeavesItsWorkspaceInPlace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credentials-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(try OnboardingFlow.createJamfCLIOnlyWorkspace(for: "acme-prod"))
        let config = root.appendingPathComponent("acme-prod/config.yaml")
        let before = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(before.contains("profile: \"acme-prod\""))

        let h = try harness(mode: .addEnvironments)
        try h.store.removeMember(profile: "acme-prod")

        XCTAssertTrue(h.store.load().isEmpty)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), before)
        // A config.yaml already there is kept, not rewritten.
        XCTAssertFalse(try OnboardingFlow.createJamfCLIOnlyWorkspace(for: "acme-prod"))
    }

    // MARK: Gateway host

    func testAnOtherRegionUsesItsRecordedHost() async throws {
        let h = try harness(
            mode: .addEnvironments, region: .other, gatewayURL: "https://gateway.example.org:8443")
        XCTAssertNil(h.model.gatewayProblem)
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()
        let registrations = await h.recorder.registrations
        XCTAssertEqual(registrations.map(\.gatewayURL), ["https://gateway.example.org:8443"])
    }

    func testAnOtherRegionOnTheRetiredGatewayRegistersNothing() async throws {
        let h = try harness(
            mode: .addEnvironments, region: .other, gatewayURL: "https://us.apigw.jamf.com")
        XCTAssertNil(h.model.gatewayURL)
        XCTAssertEqual(h.model.gatewayProblem, GatewayRegion.retiredRefusal)
        fill(h.model, ids: "env-stage Staging")
        XCTAssertFalse(h.model.canRun)
        await h.model.run()
        let registrations = await h.recorder.registrations
        XCTAssertTrue(registrations.isEmpty)
    }

    func testAnOtherRegionWithNoRecordedHostSaysItIsUnknown() throws {
        let h = try harness(mode: .updateAll, region: .other)
        XCTAssertNil(h.model.gatewayURL)
        XCTAssertNotNil(h.model.gatewayProblem)
        XCTAssertNotEqual(h.model.gatewayProblem, GatewayRegion.retiredRefusal)
    }
}
