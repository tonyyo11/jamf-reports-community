import XCTest
@testable import JamfReports

final class ConnectionStoreTests: XCTestCase {

    private static let prodID = "7c1e5a90-3b2d-4f68-9a14-d2e8b6f05c37"
    private static let stageID = "a41b9c27-0d65-4e83-b7f2-18c4d93e6a50"

    private static let both = [("prod", prodID), ("stage", stageID)]

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("connection-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func store() throws -> ConnectionStore {
        ConnectionStore(url: try tempDir().appendingPathComponent("connections.json"))
    }

    private func connection(
        _ name: String, profiles: [(String, String)], created: TimeInterval = 100
    ) -> Connection {
        Connection(
            name: name, region: .eu, level: .environment,
            members: profiles.map { .init(profile: $0.0, scopeID: $0.1, product: .pro) },
            createdAt: Date(timeIntervalSince1970: created))
    }

    // MARK: Store

    func testConnectionRoundTrip() throws {
        let store = try store()
        let original = connection("Acme", profiles: Self.both)
        try store.upsert(original)
        XCTAssertEqual(store.load(), [original])
    }

    func testConnectionFileIsOwnerOnly() throws {
        let store = try store()
        try store.upsert(connection("Acme", profiles: [("prod", Self.prodID)]))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testConnectionDecodeIgnoresUnknownFieldsAndValues() throws {
        let store = try store()
        let id = UUID().uuidString
        let json = """
            [{"id": "\(id)", "name": "Acme", "region": "mars", "level": "galaxy",
              "createdAt": "not a date", "futureField": {"a": 1},
              "members": [{"profile": "prod", "scopeID": "x", "product": "quantum",
                           "extra": true}]}]
            """
        try json.write(to: store.url, atomically: true, encoding: .utf8)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].region, .other)
        XCTAssertEqual(loaded[0].level, .environment)
        XCTAssertEqual(loaded[0].members[0].product, .unknown)
        XCTAssertEqual(loaded[0].members[0].label, "prod")
    }

    func testConnectionCorruptFileIsSetAsideNotOverwritten() throws {
        let store = try store()
        try "{ not json".write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: store.url.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("connections.json.broken-") })
    }

    func testConnectionUpsertMovesAProfileToItsNewConnection() throws {
        let store = try store()
        try store.upsert(connection("One", profiles: Self.both))
        try store.upsert(connection("Two", profiles: [("stage", Self.stageID)], created: 200))
        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.name), ["One", "Two"])
        XCTAssertEqual(loaded[0].members.map(\.profile), ["prod"])
        XCTAssertEqual(loaded[1].members.map(\.profile), ["stage"])
    }

    func testConnectionRemoveMemberDropsAnEmptyConnection() throws {
        let store = try store()
        try store.upsert(connection("One", profiles: Self.both))
        try store.removeMember(profile: "prod")
        XCTAssertEqual(store.load()[0].members.map(\.profile), ["stage"])
        try store.removeMember(profile: "stage")
        XCTAssertEqual(store.load(), [])
    }

    func testConnectionRecordMemberKeepsAnExistingLabelAndConnection() throws {
        let store = try store()
        var existing = connection("Acme", profiles: [("prod", "old")])
        existing.members[0].label = "Production"
        try store.upsert(existing)
        let updated = try store.recordMember(
            profile: "prod", scopeID: Self.prodID, product: .unknown, region: .us, level: .tenant)
        XCTAssertEqual(updated.id, existing.id)
        let member = try XCTUnwrap(store.load().first?.members.first)
        XCTAssertEqual(member.label, "Production")
        XCTAssertEqual(member.scopeID, Self.prodID)
        XCTAssertEqual(member.product, .unknown)
        XCTAssertEqual(store.load().count, 1)
    }

    func testConnectionRegionComesFromTheGatewayHost() {
        func region(_ url: String) -> Connection.Region { .region(forGatewayURL: url) }
        XCTAssertEqual(region("https://eu.api.jamfcloud.com"), .eu)
        XCTAssertEqual(region("https://apac.api.jamfcloud.com"), .apac)
        XCTAssertEqual(region("https://gov.example.com"), .other)
        XCTAssertEqual(region("not a url"), .other)
    }

    // MARK: Grouping

    private func profiles(_ names: String...) -> [JamfCLIProfile] {
        names.map { JamfCLIProfile(name: $0, url: "", schedules: 0, status: .ok) }
    }

    func testConnectionGroupingSplitsGroupedFromUngrouped() {
        let result = ProfileService.connectionGrouping(
            profiles: profiles("prod", "solo", "stage"),
            connections: [connection("Acme", profiles: [("prod", "a"), ("stage", "b")])])
        XCTAssertEqual(result.sections.count, 1)
        XCTAssertEqual(result.sections[0].entries.map(\.profile.name), ["prod", "stage"])
        XCTAssertEqual(result.ungrouped.map(\.name), ["solo"])
    }

    func testConnectionGroupingDropsMembersWithNoProfileAndEmptyConnections() {
        let gone = connection("Gone", profiles: [("deleted", "a")], created: 50)
        let acme = connection("Acme", profiles: [("deleted", "b"), ("prod", "c")])
        let result = ProfileService.connectionGrouping(
            profiles: profiles("prod"), connections: [gone, acme])
        XCTAssertEqual(result.sections.map(\.connection.name), ["Acme"])
        XCTAssertEqual(result.sections[0].entries.map(\.profile.name), ["prod"])
        // The store is not touched by grouping.
        XCTAssertEqual(acme.members.count, 2)
    }

    func testConnectionGroupingOrdersTwoConnectionsByAgeAndUsesMemberLabels() {
        var newer = connection("Newer", profiles: [("b", "1")], created: 300)
        newer.members[0].label = "Beta"
        let older = connection("Older", profiles: [("a", "2")], created: 100)
        let result = ProfileService.connectionGrouping(
            profiles: profiles("a", "b"), connections: [newer, older])
        XCTAssertEqual(result.sections.map(\.connection.name), ["Older", "Newer"])
        XCTAssertEqual(result.sections[1].entries.map(\.label), ["Beta"])
        XCTAssertTrue(result.ungrouped.isEmpty)
    }

    func testConnectionGroupingPlacesAProfileInOneSectionOnly() {
        let first = connection("First", profiles: [("p", "1")], created: 100)
        let second = connection("Second", profiles: [("p", "2")], created: 200)
        let result = ProfileService.connectionGrouping(
            profiles: profiles("p"), connections: [second, first])
        XCTAssertEqual(result.sections.map(\.connection.name), ["First"])
    }

    func testConnectionGroupingWithNoConnectionsListsEverythingUngrouped() {
        let result = ProfileService.connectionGrouping(
            profiles: profiles("a", "b"), connections: [])
        XCTAssertFalse(result.hasConnections)
        XCTAssertEqual(result.ungrouped.map(\.name), ["a", "b"])
    }

    // MARK: Demo mode

    @MainActor
    func testConnectionDemoModeReadsNoStoreAndGroupsDemoProfiles() throws {
        let store = try store()
        try store.upsert(connection("Real", profiles: [("meridian-prod", Self.prodID)]))
        let workspace = WorkspaceStore(demoMode: true, connectionStore: store)
        XCTAssertTrue(workspace.connections.isEmpty)
        XCTAssertEqual(workspace.activeConnections, DemoData.connections)
        let grouping = workspace.connectionGrouping
        XCTAssertEqual(grouping.sections.count, 1)
        XCTAssertEqual(
            grouping.sections[0].entries.map(\.profile.name), ["meridian-prod", "meridian-sandbox"])
        XCTAssertEqual(grouping.ungrouped.count, DemoData.cliProfiles.count - 2)
    }

    // MARK: Diagnostic bundle

    func testConnectionScopeIDsOfSiblingsSeedTheBundleRedactor() throws {
        let store = try store()
        try store.upsert(connection("Acme", profiles: Self.both))
        let missingConfig = try tempDir().appendingPathComponent("none.yaml")
        let ids = DiagnosticBundleService.scopeIDs(
            profile: "prod", configURL: missingConfig, connections: store)
        XCTAssertEqual(Set(ids), [Self.prodID, Self.stageID])
        XCTAssertEqual(
            DiagnosticBundleService.scopeIDs(
                profile: "unlisted", configURL: missingConfig, connections: store), [])
    }

    func testConnectionBundleHoldsNeitherTheFileNorItsScopeIDs() throws {
        let store = try store()
        try store.upsert(connection("Acme", profiles: Self.both))
        let root = try tempDir()
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let summaries = root.appendingPathComponent("summaries", isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        for dir in [logs, summaries, data] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "Environment '\(Self.stageID)' not found.".write(
            to: logs.appendingPathComponent("collect.log"), atomically: true, encoding: .utf8)
        try "profile: prod\n".write(
            to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        var sources = DiagnosticBundleService.Sources(
            workspaceName: "prod", workspaceRoot: root, logsDir: logs, summariesDir: summaries,
            configURL: root.appendingPathComponent("config.yaml"), dataDir: data)
        sources.scopeIDs = DiagnosticBundleService.scopeIDs(
            profile: "prod", configURL: root.appendingPathComponent("none.yaml"),
            connections: store)

        let out = try tempDir()
        let zip = try DiagnosticBundleService.buildBundle(
            sources: sources, outputDir: out, profileSlug: "prod", options: .init(), now: Date())
        let extracted = try tempDir()
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, extracted.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: extracted, includingPropertiesForKeys: [.isRegularFileKey]))
        var checked = 0
        for case let url as URL in files where (try? url.resourceValues(
            forKeys: [.isRegularFileKey]).isRegularFile) == true {
            XCTAssertNotEqual(url.lastPathComponent, "connections.json")
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(Self.prodID), "\(url.lastPathComponent) holds an ID")
            XCTAssertFalse(text.contains(Self.stageID), "\(url.lastPathComponent) holds an ID")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }
}

@MainActor
final class OnboardingConnectionRecordTests: XCTestCase {

    private func flow(store: ConnectionStore) -> OnboardingFlow {
        let flow = OnboardingFlow()
        flow.connectionStore = store
        flow.proConnectionType = .platformGateway
        flow.profileName = "acme-prod"
        flow.gatewayURL = "https://eu.api.jamfcloud.com"
        flow.platformScope = .environment
        flow.platformScopeID = "7c1e5a90-3b2d-4f68-9a14-d2e8b6f05c37"
        return flow
    }

    private func store() throws -> ConnectionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("connection-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return ConnectionStore(url: dir.appendingPathComponent("connections.json"))
    }

    func testAcceptedPlatformProfileIsRecordedAsAProMember() throws {
        let store = try store()
        let flow = flow(store: store)
        flow.applyConnectionCheck(.accepted(jamfProVersion: "11.25.0"))
        let saved = try XCTUnwrap(store.load().first)
        XCTAssertEqual(saved.name, "acme-prod")
        XCTAssertEqual(saved.region, .eu)
        XCTAssertEqual(saved.level, .environment)
        XCTAssertEqual(saved.members, [
            .init(profile: "acme-prod", scopeID: flow.platformScopeID,
                  label: "acme-prod", product: .pro)
        ])
    }

    func testNoJamfProIsRecordedWithAnUnknownProduct() throws {
        let store = try store()
        let flow = flow(store: store)
        flow.platformScope = .tenant
        flow.applyConnectionCheck(.noJamfPro)
        let saved = try XCTUnwrap(store.load().first)
        XCTAssertEqual(saved.members.first?.product, .unknown)
        XCTAssertEqual(saved.level, .tenant)
    }

    func testRejectedAndUndecidedChecksRecordNothing() throws {
        let store = try store()
        let flow = flow(store: store)
        flow.applyConnectionCheck(.rejectedID(.unknownEnvironment))
        flow.applyConnectionCheck(.undecided(exitCode: 1))
        XCTAssertEqual(store.load(), [])
    }

    func testOAuth2ProfilesAreNeverRecorded() throws {
        let store = try store()
        let flow = flow(store: store)
        flow.proConnectionType = .oauth2
        flow.applyConnectionCheck(.accepted(jamfProVersion: nil))
        XCTAssertEqual(store.load(), [])
    }
}
