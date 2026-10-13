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

    private struct Harness {
        let model: ConnectionCredentialsModel
        let store: ConnectionStore
        let recorder: Recorder
        let provisioned: Provisioned
        let connectionID: UUID
    }

    private let context = ConnectionCredentialsModel.JamfCLIContext(
        binary: URL(fileURLWithPath: "/nonexistent/stub-cli"), version: "1.31.1")

    private func harness(
        mode: ConnectionCredentialsModel.Mode,
        members: [Connection.Member] = [
            .init(profile: "acme-prod", scopeID: "env-prod", label: "Prod", product: .unknown),
        ],
        verdicts: [String: ConnectionCheck.Verdict] = [:],
        failRegistration: Set<String> = [],
        existingProfiles: [String] = ["acme-prod"],
        region: Connection.Region = .eu
    ) throws -> Harness {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("credentials-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ConnectionStore(url: dir.appendingPathComponent("connections.json"))
        let connection = Connection(
            name: "Acme", region: region, level: .environment, members: members)
        try store.upsert(connection)
        let recorder = Recorder()
        let provisioned = Provisioned()
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
                return verdicts[profile] ?? .accepted(jamfProVersion: "11.25.0")
            },
            existingProfiles: { existingProfiles },
            workspaceConflict: { _ in nil },
            provisionWorkspace: { provisioned.profiles.append($0); return true },
            store: store)
        let model = ConnectionCredentialsModel(
            connection: connection, mode: mode, dependencies: dependencies)
        return Harness(
            model: model, store: store, recorder: recorder, provisioned: provisioned,
            connectionID: connection.id)
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
        XCTAssertEqual(registrations[0].clientSecret, "s3cret-value")
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

        XCTAssertEqual(h.model.clientSecret, "")
        XCTAssertFalse(h.model.secretFieldHasText)
        XCTAssertFalse(h.model.canRun)
    }

    func testTheSecretIsClearedWhenARunStopsEarly() async throws {
        let h = try harness(mode: .addEnvironments, failRegistration: ["acme-staging"])
        fill(h.model, ids: "env-stage Staging")
        await h.model.run()
        XCTAssertEqual(h.model.clientSecret, "")
    }

    func testClosingTheSheetClearsATypedSecret() throws {
        let h = try harness(mode: .addEnvironments)
        fill(h.model, ids: "env-stage Staging")
        h.model.secretFieldHasText = true
        h.model.close()
        XCTAssertEqual(h.model.clientSecret, "")
        XCTAssertFalse(h.model.secretFieldHasText)
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
        XCTAssertEqual(h.model.clientSecret, "")
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
}
