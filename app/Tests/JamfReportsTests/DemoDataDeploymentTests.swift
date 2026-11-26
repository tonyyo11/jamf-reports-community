import XCTest
@testable import JamfReports

final class DemoDataDeploymentTests: XCTestCase {
    func testTheDemoCardFitsTheDemoFleet() {
        let card = DemoData.deploymentHealth
        for state in card.states.values {
            for row in state.rows {
                XCTAssertLessThanOrEqual(row.inScope ?? 0, DemoData.totalDevices)
            }
        }
        let apps = card.states[.appInstallers]?.rows ?? []
        XCTAssertEqual(DeploymentHealth.atLevel(apps, levels: card.levels).first?.judgement,
                       .warning)
        XCTAssertTrue(apps.contains { DeploymentHealth.versionState($0) == .pinned })
        XCTAssertTrue(apps.contains { DeploymentHealth.judge($0, levels: card.levels)
            == .nothingInScope })
        XCTAssertTrue((card.states[.patchPolicy]?.rows ?? []).contains { $0.enabled == false })
    }
}
