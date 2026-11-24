import Foundation
import XCTest
@testable import JamfReports

/// First-launch onboarding's Start over: back to the chooser, removing only the workspace folders
/// and jamf-cli profiles that run created.
@MainActor
final class OnboardingStartOverTests: XCTestCase {

    private nonisolated(unsafe) var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-start-over-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        MainActor.assumeIsolated {
            OnboardingFlow.pendingProductPath = nil
            OnboardingFlow.pendingProConnectionType = nil
        }
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    /// Removes rather than trashes, through the same path checks, so a test run never fills the
    /// Trash.
    private static let removeInPlace: OnboardingFlow.WorkspaceTrasher = {
        try ProfileService.trashLocalWorkspace(profile: $0) {
            try FileManager.default.removeItem(at: $0)
        }
    }

    private final class Removed: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    private func makeFlow(
        existing: Set<String>? = [],
        removed: Removed = Removed(),
        failing: Set<String> = []
    ) throws -> OnboardingFlow {
        let flow = OnboardingFlow(
            installationProbe: { nil },
            profileLister: { existing },
            profileRemover: { name in
                if failing.contains(name) { return "could not remove \(name)" }
                removed.add(name)
                return nil
            },
            workspaceTrasher: Self.removeInPlace
        )
        flow.connectionStore = ConnectionStore(
            url: tempRoot.appendingPathComponent("connections.json"))
        return flow
    }

    private func workspace(_ profile: String) -> URL {
        tempRoot.appendingPathComponent(profile, isDirectory: true)
    }

    // MARK: - What a run records

    func testCreateWorkspaceRecordsAFolderItMade() throws {
        let flow = try makeFlow()
        flow.profileName = "prod-platform"
        try flow.createWorkspace()
        try flow.createWorkspace()

        XCTAssertEqual(flow.createdWorkspaces, ["prod-platform"])
        XCTAssertTrue(flow.startOverRemovesSomething)
    }

    /// Leaving the Setup tab keeps a run that saved something, or is still saving; a fresh
    /// run is dropped as before.
    func testARunWithWorkOrACommandRunningIsParkedWhenItsTabIsLeft() throws {
        let flow = try makeFlow()
        XCTAssertFalse(flow.parksWhenLeft)
        flow.isRegisteringProfile = true
        XCTAssertTrue(flow.parksWhenLeft, "a profile may be saved after the tab is gone")
        flow.isRegisteringProfile = false
        flow.noteCreatedProfile("acme")
        XCTAssertTrue(flow.parksWhenLeft)
    }

    func testCreateWorkspaceLeavesAFolderThatExistedUnrecorded() throws {
        try FileManager.default.createDirectory(
            at: workspace("acme"), withIntermediateDirectories: true)
        let flow = try makeFlow()
        flow.profileName = "acme"
        try flow.createWorkspace()

        XCTAssertEqual(flow.createdWorkspaces, [])
        XCTAssertFalse(flow.startOverRemovesSomething)
    }

    func testAProfileJamfCLIAlreadyHadIsNotNew() async throws {
        let flow = try makeFlow(existing: ["acme"])
        let acmeIsNew = await flow.isNewProfile("acme")
        let otherIsNew = await flow.isNewProfile("other")
        XCTAssertFalse(acmeIsNew)
        XCTAssertTrue(otherIsNew)

        flow.noteCreatedProfile("other")
        flow.noteCreatedProfile("other")
        XCTAssertEqual(flow.createdProfiles, ["other"])
    }

    func testAListingThatCannotBeReadMakesNoProfileNew() async throws {
        let flow = try makeFlow(existing: nil)
        let isNew = await flow.isNewProfile("acme")
        XCTAssertFalse(isNew)
    }

    func testStartOverRemovesNothingWhenTheListingFailedBeforeTheProfileWasAdded() async throws {
        let removed = Removed()
        let flow = try makeFlow(existing: nil, removed: removed)
        // What the register step does: record the name only when the profile was new.
        if await flow.isNewProfile("acme") { flow.noteCreatedProfile("acme") }

        XCTAssertFalse(flow.startOverRemovesSomething)
        let problems = await flow.startOver()

        XCTAssertEqual(problems, [])
        XCTAssertEqual(removed.all, [])
    }

    // MARK: - Start over

    func testStartOverWithNothingCreatedClearsTheChooserHandoffAndSecrets() async throws {
        let flow = try makeFlow()
        OnboardingFlow.pendingProductPath = .school
        OnboardingFlow.pendingProConnectionType = .platformGateway
        flow.platformClientSecret = Data("secret".utf8)

        let problems = await flow.startOver()

        XCTAssertEqual(problems, [])
        XCTAssertNil(OnboardingFlow.pendingProductPath)
        XCTAssertNil(OnboardingFlow.pendingProConnectionType)
        XCTAssertTrue(flow.platformClientSecret.isEmpty)
    }

    func testStartOverRemovesTheProfileItsConnectionRecordAndTheFolder() async throws {
        let removed = Removed()
        let flow = try makeFlow(removed: removed)
        flow.profileName = "prod-platform"
        try flow.createWorkspace()
        flow.noteCreatedProfile("prod-platform")
        try flow.connectionStore.recordMember(
            profile: "prod-platform", scopeID: "env-1", product: .pro, region: .us,
            level: .environment)

        let problems = await flow.startOver()

        XCTAssertEqual(problems, [])
        XCTAssertEqual(removed.all, ["prod-platform"])
        XCTAssertEqual(flow.connectionStore.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace("prod-platform").path))
        XCTAssertFalse(flow.startOverRemovesSomething)
    }

    func testAProfileThatCouldNotBeRemovedStaysListedAndIsReported() async throws {
        let flow = try makeFlow(failing: ["stuck"])
        flow.profileName = "stuck"
        try flow.createWorkspace()
        flow.noteCreatedProfile("stuck")

        let problems = await flow.startOver()

        XCTAssertEqual(problems, ["could not remove stuck"])
        XCTAssertEqual(flow.createdProfiles, ["stuck"])
        XCTAssertEqual(flow.createdWorkspaces, [], "the folder still goes")
        XCTAssertTrue(flow.startOverRemovesSomething, "a second Start over retries the profile")
    }

    func testTheConfirmationNamesWhatGoes() throws {
        let flow = try makeFlow()
        flow.createdWorkspaces = ["prod-school"]
        flow.createdProfiles = ["prod-school"]

        let message = flow.startOverMessage
        XCTAssertTrue(message.contains(
            "the workspace folder \(WorkspaceRootStore.displayPath(profile: "prod-school"))"))
        XCTAssertTrue(message.contains("the jamf-cli profile prod-school"))
        XCTAssertTrue(message.contains("Trash"))
    }

    // MARK: - Path checks

    func testTrashRefusesAWorkspaceFolderThatLinksOutOfTheRoot() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: workspace("linked"), withDestinationURL: outside)

        var trashed: [URL] = []
        XCTAssertThrowsError(try ProfileService.trashLocalWorkspace(profile: "linked") {
            trashed.append($0)
        })
        XCTAssertEqual(trashed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
