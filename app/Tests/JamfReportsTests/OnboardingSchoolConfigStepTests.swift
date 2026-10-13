import Foundation
import XCTest
@testable import JamfReports

/// The Jamf School path maps no CSV: its CSV step only writes config.yaml, because the scaffold
/// reads Jamf Pro column names and School reports come from jamf-cli.
@MainActor
final class OnboardingSchoolConfigStepTests: XCTestCase {

    private nonisolated(unsafe) var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-config-\(UUID().uuidString)", isDirectory: true)
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

    func testOnlyTheJamfProPathMapsACSV() {
        let pro = flow(.pro)
        let school = flow(.school)
        XCTAssertTrue(pro.offersCSVMapping)
        XCTAssertFalse(school.offersCSVMapping)
        XCTAssertEqual(pro.label(for: .csvMapping), "CSV mapping")
        XCTAssertEqual(school.label(for: .csvMapping), "Workspace config")
        XCTAssertEqual(school.label(for: .schoolConnect), "Connect School")
    }

    func testASchoolWorkspaceRefusesACSV() async throws {
        let school = flow(.school)
        school.profileName = "prod-school"
        try school.createWorkspace()
        let csv = tempRoot.appendingPathComponent("devices.csv")
        try Data("Serial Number,Name\n".utf8).write(to: csv)

        await school.scaffoldCSV(from: csv)

        XCTAssertFalse(school.csvScaffolded)
        XCTAssertEqual(
            school.lastError, OnboardingFlow.FlowError.csvMappingNotOffered.localizedDescription)
        let config = tempRoot.appendingPathComponent("prod-school/config.yaml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
    }

    func testTheSchoolConfigStepWritesConfigAndSaysWhy() async throws {
        let school = flow(.school)
        school.profileName = "prod-school"
        try school.createWorkspace()

        await school.skipCSVMapping()

        XCTAssertTrue(school.csvMappingSkipped)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("prod-school/config.yaml").path))
        XCTAssertEqual(
            school.csvOutput.last?.text,
            "[ok] config.yaml written — Jamf School reports come from jamf-cli")
    }
}
