import XCTest
@testable import JamfReports

final class DeploymentHealthHtmlTests: XCTestCase {

    private func row(_ id: String, failed: Int, inScope: Int = 100) -> DeploymentHealth.Row {
        .init(source: .patchPolicy, id: id, name: "Policy \(id)", enabled: true, failed: failed,
              inScope: inScope, assignedElsewhere: nil, deployedVersion: nil, latestVersion: nil,
              updateBehavior: nil, completed: inScope - failed, deferred: 0, pending: 0,
              targetVersion: "1", softwareTitle: "T")
    }

    private func inputs(_ rows: [DeploymentHealth.Row], asOf: Date? = nil) -> HtmlReport.Inputs {
        var inputs = HtmlReport.Inputs()
        inputs.deployments = [.patchPolicy: .rows(rows, asOf: asOf, leftOut: 0),
                              .appInstallers: .notSetUp]
        return inputs
    }

    func testOneAndManySentencesAndNoneBelowTheLevels() {
        XCTAssertEqual(HtmlReport.deploymentSentences(inputs([row("1", failed: 12)])),
                       ["1 patch policy has failed on 10% or more of its Macs."])
        XCTAssertEqual(HtmlReport.deploymentSentences(
            inputs([row("1", failed: 12), row("2", failed: 40)])),
            ["2 patch policies have failed on 10% or more of their Macs."])
        XCTAssertEqual(HtmlReport.deploymentSentences(inputs([row("1", failed: 2)])), [])
        XCTAssertEqual(HtmlReport.deploymentSentences(
            inputs([row("1", failed: 12)], asOf: Date())), [], "an old snapshot is not current")
    }

    func testTheSectionCapsAndSaysWhyASourceIsNotListed() {
        let report = HtmlReport(config: ReportConfig().withDefaults(),
                                dataDir: URL(fileURLWithPath: "/tmp/nonexistent-html-tests"))
        let many = (1...30).map { row("\($0)", failed: 20) }
        let block = report.buildDeploymentHealth(inputs(many))
        XCTAssertTrue(block.isShown)
        let html = block.html
        XCTAssertTrue(html.contains("id=\"deployment-health\""))
        XCTAssertTrue(html.contains("25 of 30 shown."))
        XCTAssertTrue(html.contains("Not set up on this Jamf Pro server"))
        var none = HtmlReport.Inputs()
        none.deployments = [.patchPolicy: .notCollected, .appInstallers: .notCollected]
        XCTAssertFalse(report.buildDeploymentHealth(none).isShown,
                       "left out with nothing collected")
    }
}
