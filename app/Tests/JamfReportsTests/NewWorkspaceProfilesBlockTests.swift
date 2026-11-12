import Foundation
import XCTest
@testable import JamfReports

/// D3: every path that creates a workspace's config.yaml writes its `profiles:` block, with no
/// `jamf_cli.profile` beside it, and the block routes as the old shape did.
@MainActor
final class NewWorkspaceProfilesBlockTests: XCTestCase {
    private nonisolated(unsafe) var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Under home, not /var: `scaffold --out` refuses a system folder.
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("jrc-new-block-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func config(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("\(name)/config.yaml"), encoding: .utf8)
    }

    private func environment(_ name: String) throws -> EnvironmentProfiles {
        EnvironmentProfiles.read(
            configURL: root.appendingPathComponent("\(name)/config.yaml"), workspace: name)
    }

    func testTheKindComesFromJamfCLIsRecordOfTheProfile() {
        typealias Kind = ProfilesConfigWriter.NewWorkspace
        XCTAssertEqual(Kind.of("p") { _ in nil }, Kind(platform: true))
        XCTAssertEqual(Kind.of("p") { _ in
            .init(authMethod: "oauth2", isTenantLevel: false, product: .pro) }, Kind())
        XCTAssertEqual(Kind.of("p") { _ in
            .init(authMethod: "platform", isTenantLevel: false, product: .pro) },
            Kind(platform: true))
        XCTAssertEqual(Kind.of("p") { _ in
            .init(authMethod: "apikey", isTenantLevel: false, product: .school) },
            Kind(school: true))
    }

    func testInitializeWritesTheBlockAndTheBindingLeavesItAlone() async throws {
        let lines = LineBox()
        _ = try await CLIBridge().initializeWorkspace(profile: "acme") {
            lines.value.append($0.text)
        }
        let first = try config("acme")
        let env = try environment("acme")
        XCTAssertEqual(env.source, .profilesBlock)
        XCTAssertEqual(env.jamfPro, "acme")
        XCTAssertFalse(first.contains("  profile:"))
        let loaded = try ConfigLoader.loadFromString(first)
        XCTAssertEqual(ConfigDoctorService.oldKeyRows(environment: env, config: loaded), [])

        _ = try await CLIBridge().initializeWorkspace(profile: "acme") {
            lines.value.append($0.text)
        }
        XCTAssertEqual(try config("acme"), first)
        XCTAssertFalse(lines.value.contains { $0.contains("set jamf_cli.profile") },
                       "\(lines.value)")
    }

    /// The School setup's `school_cli` write finds the slot already naming the workspace.
    func testASchoolWorkspaceStartsWithItsSlotAndTheSchoolWriteKeepsIt() throws {
        try ReportEngine.initializeWorkspace(
            profile: "district", workspacesRoot: root, kind: .init(school: true)) { _ in }
        let before = try config("district")
        XCTAssertEqual(try environment("district").jamfSchool, "district")
        XCTAssertNoThrow(try OnboardingFlow.writeProductBlock(
            "school_cli", profile: "district", for: "district"))
        XCTAssertEqual(try config("district"), before)
    }

    /// Setup that began on the Jamf Pro path (Set up Jamf School after "no Jamf Pro"), or an
    /// adopted School login jamf-cli could not place, wrote a Jamf Pro block; the School write
    /// for the workspace's own profile moves the MDM slot, as `school_cli` did on the old shape.
    func testTheSchoolWriteMovesAJamfProBlockToSchool() throws {
        let support = root.appendingPathComponent("support", isDirectory: true)
        let pro = OnboardingFlow()
        pro.profileName = "campus"
        try pro.createWorkspace()
        try pro.recordOwnPlatformSlot("campus", appSupport: support)
        XCTAssertEqual(try environment("campus").jamfPro, "campus")

        let school = OnboardingFlow()
        school.productPath = .school
        school.profileName = "campus"
        try school.createWorkspace()
        try school.writeSchoolConfig(profileSlug: "campus", schoolProfileName: "campus")
        let env = try environment("campus")
        XCTAssertEqual(env.jamfSchool, "campus")
        XCTAssertNil(env.jamfPro)
        XCTAssertNil(env.platform)
        XCTAssertNil(EnvironmentProfiles.resolve(
            config: try ConfigLoader.loadFromString(try config("campus")), workspace: "campus")
            .refusal(workspace: "campus"))

        // The adoption path's own writer reaches the same seam.
        try ReportEngine.initializeWorkspace(
            profile: "district", workspacesRoot: root, kind: .init(platform: true)) { _ in }
        XCTAssertNoThrow(try OnboardingFlow.writeProductBlock(
            "school_cli", profile: "district", for: "district"))
        XCTAssertEqual(try environment("district").jamfSchool, "district")
        XCTAssertNil(try environment("district").jamfPro)
    }

    func testOnboardingAddsThePlatformSlotOnlyToAConfigItWrote() throws {
        let support = root.appendingPathComponent("support", isDirectory: true)
        let flow = OnboardingFlow()
        flow.profileName = "gateway"
        try flow.createWorkspace()
        XCTAssertNil(try environment("gateway").platform)
        try flow.recordOwnPlatformSlot("gateway", appSupport: support)
        XCTAssertEqual(try environment("gateway").platform, "gateway")
        XCTAssertTrue(SharedConfigPin.platformAllowed(
            profile: "gateway", name: "gateway", appSupport: support))

        let kept = "jamf_cli:\n  profile: kept\n"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("kept"), withIntermediateDirectories: true)
        try kept.write(to: root.appendingPathComponent("kept/config.yaml"),
                       atomically: true, encoding: .utf8)
        flow.profileName = "kept"
        try flow.createWorkspace()
        try flow.recordOwnPlatformSlot("kept", appSupport: support)
        XCTAssertEqual(try config("kept"), kept)
    }

    func testScaffoldWritesTheBlockOnlyForAWorkspacesOwnConfig() async throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ws"), withIntermediateDirectories: true)
        try await Scaffold.parse(["--out", root.appendingPathComponent("ws/config.yaml").path])
            .run()
        XCTAssertEqual(try environment("ws").jamfPro, "ws")
        XCTAssertFalse(try config("ws").contains("  profile:"))

        let loose = root.appendingPathComponent("elsewhere/nested/config.yaml")
        try await Scaffold.parse(["--out", loose.path]).run()
        let text = try String(contentsOf: loose, encoding: .utf8)
        XCTAssertFalse(text.contains("profiles:"))
        XCTAssertTrue(text.contains("  profile: \"\""))
    }

    func testThePinConfirmsThePlatformSlotTheTextSets() {
        let platform = ScaffoldService.minimalConfigYAML(
            profile: "p", eas: [], workspace: .init(platform: true))
        let oauth = ScaffoldService.minimalConfigYAML(profile: "p", eas: [], workspace: .init())
        XCTAssertTrue(SharedConfigPin.keysSet(inYAML: platform).contains(.platformProfile))
        XCTAssertFalse(SharedConfigPin.keysSet(inYAML: oauth).contains(.platformProfile))
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var value: [String] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
