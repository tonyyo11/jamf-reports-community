import XCTest
@testable import JamfReports

final class EnvironmentCardStateTests: XCTestCase {
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock(); private var names: [String] = []
        func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    private func state(
        _ yaml: String, ws: String = "ws", drifted: Set<SharedConfigPin.Key> = [],
        asked: Asked = Asked()
    ) throws -> EnvironmentCardState {
        let environment = EnvironmentProfiles.resolve(
            config: try ConfigLoader.loadFromString(yaml), workspace: ws)
        return EnvironmentCardState.build(
            workspace: ws, environment: environment,
            resolve: { asked.add($0); return .init(authMethod: "oauth2", isTenantLevel: false) },
            newest: { _ in nil }, drifted: { drifted.contains($0) })
    }

    func testAnOldShapeWorkspaceShowsItsDerivedSlots() throws {
        let card = try state("protect:\n  enabled: true\n  profile: ws-P\n")
        XCTAssertFalse(card.fromBlock)
        XCTAssertEqual(card.rows.map(\.slot), [.jamfPro, .platform, .protect, .securityCloud])
        XCTAssertEqual(card.rows.map(\.profile), ["ws", nil, "ws-P", nil])
    }

    func testABlockMarksAHeldPlatformSlot() throws {
        let card = try state("profiles:\n  jamf_pro: ws\n  platform: ws-API\n",
                             drifted: [.platformProfile])
        XCTAssertTrue(card.fromBlock)
        XCTAssertEqual(card.rows.first { $0.slot == .platform }?.pinNeedsConfirming, true)
    }

    func testASchoolEnvironmentHasNoPlatformRow() throws {
        let card = try state("school_cli:\n  enabled: true\n")
        XCTAssertEqual(card.rows.map(\.slot), [.jamfSchool, .protect, .securityCloud])
    }

    func testTheMDMRowCannotBeRemoved() throws {
        let card = try state("profiles:\n  jamf_pro: ws\n  protect: ws-P\n")
        XCTAssertEqual(card.rows.first { $0.slot == .jamfPro }?.canRemove, false)
        XCTAssertEqual(card.rows.first { $0.slot == .protect }?.canRemove, true)
    }

    func testOnlyFilledSlotsAreResolved() throws {
        let asked = Asked()
        _ = try state("profiles:\n  jamf_pro: ws\n", asked: asked)
        XCTAssertEqual(asked.all, ["ws"])
    }

    private func build(
        _ yaml: String, resolved: ProfileAuthMethod.Resolved? = nil,
        newest: Date? = nil, drifted: Set<SharedConfigPin.Key> = []
    ) throws -> EnvironmentCardState {
        let environment = EnvironmentProfiles.resolve(
            config: try ConfigLoader.loadFromString(yaml), workspace: "ws")
        return EnvironmentCardState.build(
            workspace: "ws", environment: environment, resolve: { _ in resolved },
            newest: { _ in newest }, drifted: { drifted.contains($0) })
    }

    func testPlatformLevelsAreTyped() throws {
        let yaml = "profiles:\n  jamf_pro: ws\n  platform: ws-API\n"
        let cases: [(Bool, Bool, PlatformScopeLevel)] = [
            (true, false, .tenant), (false, false, .environment), (false, true, .organization)]
        for (tenant, org, expected) in cases {
            let resolved = ProfileAuthMethod.Resolved(
                authMethod: "platform", isTenantLevel: tenant, isOrganizationLevel: org)
            let row = try XCTUnwrap(
                try build(yaml, resolved: resolved).rows.first { $0.slot == .platform })
            XCTAssertEqual(row.authMethod, "platform")
            XCTAssertEqual(row.level, expected)
        }
        let oauth = ProfileAuthMethod.Resolved(authMethod: "oauth2", isTenantLevel: false)
        let mdm = try XCTUnwrap(try build(yaml, resolved: oauth).rows.first)
        XCTAssertNil(mdm.level)
    }

    func testNewestSnapshotOnlyForFilledSlots() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let card = try build("profiles:\n  jamf_pro: ws\n", newest: date)
        XCTAssertEqual(card.rows.first { $0.slot == .jamfPro }?.newestSnapshot, date)
        XCTAssertNil(card.rows.first { $0.slot == .platform }?.newestSnapshot)
    }

    func testProtectDriftMarksOnlyTheProtectRow() throws {
        let yaml = "profiles:\n  jamf_pro: ws\n  protect: ws-P\n"
        let card = try build(yaml, drifted: [.protectProfile])
        XCTAssertEqual(card.rows.map(\.pinNeedsConfirming), [false, false, true, false])
    }

    func testProtectWithoutAProfileHasAnEmptyRow() throws {
        let card = try state("protect:\n  enabled: true\n")
        let row = try XCTUnwrap(card.rows.first { $0.slot == .protect })
        XCTAssertNil(row.profile)
        XCTAssertFalse(row.canRemove)
    }

    func testSlotKindsCoverTheirOwnData() {
        XCTAssertEqual(EnvironmentCardState.kinds(for: .jamfPro), ["computers"])
        XCTAssertEqual(
            Set(EnvironmentCardState.kinds(for: .platform)), ReportEngine.platformOnlyKinds)
        XCTAssertEqual(
            EnvironmentCardState.kinds(for: .protect), DataFreshnessHealth.protectKinds)
        XCTAssertFalse(EnvironmentCardState.kinds(for: .protect).isEmpty)
    }
}
