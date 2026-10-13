import XCTest
@testable import JamfReports

final class ConnectionCardStateTests: XCTestCase {

    private func store() throws -> ConnectionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("connection-card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return ConnectionStore(url: dir.appendingPathComponent("connections.json"))
    }

    private let connection = Connection(
        name: "Acme", region: .us, level: .environment,
        members: [.init(profile: "acme-prod", scopeID: "env-prod", product: .pro)])

    // MARK: Which card

    func testAMemberShowsItsConnectionWhateverItsAuthMethod() {
        XCTAssertEqual(
            ConnectionCardState.resolve(
                profile: "acme-prod", authMethod: "oauth2", connections: [connection]),
            .member(connection))
    }

    func testAPlatformProfileInNoConnectionOffersToStartOne() {
        XCTAssertEqual(
            ConnectionCardState.resolve(profile: "solo", authMethod: "platform", connections: []),
            .canStart)
    }

    func testAnOAuth2ProfileInNoConnectionShowsNoCard() {
        XCTAssertEqual(
            ConnectionCardState.resolve(profile: "solo", authMethod: "oauth2", connections: []),
            .hidden)
        XCTAssertEqual(
            ConnectionCardState.resolve(profile: "solo", authMethod: "", connections: []),
            .hidden)
    }

    // MARK: Starting a connection

    private let config = """
    profiles:
      solo:
        url: https://eu.api.jamfcloud.com
        auth-method: platform
        environment-id: env-solo
      legacy:
        url: https://us.api.jamfcloud.com
        auth-method: platform
        tenant-id: tenant-legacy
    """

    func testStartingTakesRegionIDAndLevelFromTheProfile() throws {
        let store = try store()
        let started = try ConnectionStarter.start(
            profile: "solo", storedURL: "eu.api.jamfcloud.com", configText: config, store: store)
        XCTAssertEqual(started.name, "solo")
        XCTAssertEqual(started.region, .eu)
        XCTAssertEqual(started.level, .environment)
        XCTAssertEqual(started.members.map(\.scopeID), ["env-solo"])
        XCTAssertEqual(store.load().map(\.id), [started.id])
    }

    func testStartingAFileTenantProfileRecordsTenantLevel() throws {
        let started = try ConnectionStarter.start(
            profile: "legacy", storedURL: "us.api.jamfcloud.com", configText: config,
            store: try store())
        XCTAssertEqual(started.level, .tenant)
        XCTAssertEqual(started.members.map(\.scopeID), ["tenant-legacy"])
    }

    func testStartingWithoutTheConfigLeavesTheIDBlank() throws {
        let started = try ConnectionStarter.start(
            profile: "solo", storedURL: "(jamf-cli profile)", configText: nil,
            store: try store())
        XCTAssertEqual(started.region, .other)
        XCTAssertEqual(started.members.map(\.scopeID), [""])
    }

    // MARK: Store edits

    func testRenameChangesDisplayNamesOnly() throws {
        let store = try store()
        try store.upsert(connection)
        try store.rename(
            id: connection.id, name: " Acme Cloud ", labels: ["acme-prod": "Production"])
        let renamed = try XCTUnwrap(store.load().first)
        XCTAssertEqual(renamed.name, "Acme Cloud")
        XCTAssertEqual(renamed.members[0].label, "Production")
        XCTAssertEqual(renamed.members[0].profile, "acme-prod")
    }

    func testRenameIgnoresBlankNamesAndLabels() throws {
        let store = try store()
        try store.upsert(connection)
        try store.rename(id: connection.id, name: "  ", labels: ["acme-prod": ""])
        let kept = try XCTUnwrap(store.load().first)
        XCTAssertEqual(kept.name, "Acme")
        XCTAssertEqual(kept.members[0].label, "acme-prod")
    }

    func testAddMemberSkipsAProfileAlreadyInAConnection() throws {
        let store = try store()
        try store.upsert(connection)
        let duplicate = Connection.Member(profile: "acme-prod", scopeID: "other", product: .pro)
        let fresh = Connection.Member(profile: "acme-new", scopeID: "env-new", product: .pro)
        try store.addMember(duplicate, toConnection: connection.id)
        try store.addMember(fresh, toConnection: connection.id)
        XCTAssertEqual(store.load().first?.members.map(\.profile), ["acme-prod", "acme-new"])
        XCTAssertEqual(store.load().first?.members.first?.scopeID, "env-prod")
    }
}
