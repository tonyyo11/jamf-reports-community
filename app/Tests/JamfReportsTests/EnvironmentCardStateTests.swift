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
        XCTAssertEqual(card.rows.map(\.slot), [.jamfPro, .platform, .protect])
        XCTAssertEqual(card.rows.map(\.profile), ["ws", nil, "ws-P"])
    }

    func testABlockMarksAHeldPlatformSlot() throws {
        let card = try state("profiles:\n  jamf_pro: ws\n  platform: ws-API\n",
                             drifted: [.platformProfile])
        XCTAssertTrue(card.fromBlock)
        XCTAssertEqual(card.rows.first { $0.slot == .platform }?.pinNeedsConfirming, true)
    }

    func testASchoolEnvironmentHasNoPlatformRow() throws {
        let card = try state("school_cli:\n  enabled: true\n")
        XCTAssertEqual(card.rows.map(\.slot), [.jamfSchool, .protect])
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
}
