import Foundation
import XCTest
@testable import JamfReports

/// The workspace step writes the minimal config.yaml on both paths: no CSV is mapped and no
/// `columns` block or csv-inbox folder is created.
@MainActor
final class OnboardingWorkspaceConfigTests: XCTestCase {

    private nonisolated(unsafe) var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-workspace-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        MainActor.assumeIsolated { OnboardingFlow.pendingProductPath = nil }
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func flow(_ path: OnboardingFlow.ProductPath) -> OnboardingFlow {
        OnboardingFlow.pendingProductPath = path
        return OnboardingFlow(installationProbe: { nil }, profileLister: { [] })
    }

    func testNoPathHasACSVStep() {
        for path in [OnboardingFlow.ProductPath.pro, .school] {
            XCTAssertFalse(flow(path).stepSequence.map(\.label).contains("CSV mapping"))
        }
        XCTAssertEqual(OnboardingFlow.Step.schoolConnect.label, "Connect School")
    }

    func testCreatingAWorkspaceWritesTheMinimalConfigWithoutColumnsOrAnInbox() throws {
        for (path, name) in [(OnboardingFlow.ProductPath.pro, "prod-pro"), (.school, "prod-school")] {
            let onboarding = flow(path)
            onboarding.profileName = name
            try onboarding.createWorkspace()

            let workspace = tempRoot.appendingPathComponent(name)
            let text = try String(
                contentsOf: workspace.appendingPathComponent("config.yaml"), encoding: .utf8)
            // D3: the block names the workspace in its MDM slot; no jamf_cli.profile beside it.
            let slot = path == .school ? "jamf_school" : "jamf_pro"
            XCTAssertTrue(text.contains("profiles:\n  \(slot): \"\(name)\""), text)
            XCTAssertFalse(text.contains("  profile:"), text)
            XCTAssertFalse(text.contains("columns"), "no column mapping is written")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("csv-inbox").path))
        }
    }

    func testCreatingAWorkspaceKeepsAConfigThatIsAlreadyThere() throws {
        let onboarding = flow(.pro)
        onboarding.profileName = "prod-pro"
        let workspace = tempRoot.appendingPathComponent("prod-pro")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        try "thresholds:\n  stale_device_days: 61\n".write(to: config, atomically: true, encoding: .utf8)

        try onboarding.createWorkspace()

        XCTAssertEqual(
            try String(contentsOf: config, encoding: .utf8),
            "thresholds:\n  stale_device_days: 61\n")
    }
}
