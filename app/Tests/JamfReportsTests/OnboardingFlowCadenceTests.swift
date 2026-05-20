import Foundation
import XCTest
@testable import JamfReports

/// PR-23 T-24: the onboarding preset prompt. The chosen preset is stamped
/// into config.yaml once the CSV-mapping (or skip) step writes the file.
@MainActor
final class OnboardingFlowCadenceTests: XCTestCase {

    func testDefaultPresetIsOnPrem() {
        // Conservative default — matches CadenceResolver's missing-config
        // behavior and the most common (self-hosted) deployment shape.
        XCTAssertEqual(OnboardingFlow().selectedCollectionPreset, .onPrem)
    }

    func testSelectedPresetLandsInConfigAfterSkipMapping() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnbCadence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let profile = "onbcad\(Int.random(in: 1000...9999))"
        let flow = OnboardingFlow()
        flow.profileName = profile
        try flow.createWorkspace()

        flow.selectedCollectionPreset = .cloud
        await flow.skipCSVMapping()
        XCTAssertNil(flow.lastError, "skipCSVMapping should succeed: \(flow.lastError ?? "")")

        let url = try ConfigService.configURL(for: profile)
        let config = try ConfigLoader.load(from: url)
        XCTAssertEqual(config.collectCadence?.preset, .cloud,
                       "The onboarding preset choice must be written into config.yaml")
    }

    func testOnPremPresetAlsoPersists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnbCadence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let profile = "onbcad\(Int.random(in: 1000...9999))"
        let flow = OnboardingFlow()
        flow.profileName = profile
        try flow.createWorkspace()

        // Leave the default (.onPrem) untouched.
        await flow.skipCSVMapping()
        XCTAssertNil(flow.lastError)

        let url = try ConfigService.configURL(for: profile)
        let config = try ConfigLoader.load(from: url)
        XCTAssertEqual(config.collectCadence?.preset, .onPrem)
    }
}
