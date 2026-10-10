import XCTest
@testable import JamfReports

/// Resolution and validation of the configurable workspace root.
///
/// Uses an isolated `UserDefaults` suite so a developer's real preference can
/// never influence the result, and temp directories so nothing touches a real
/// workspace.
final class WorkspaceRootStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "jrc.rootstore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // Home-relative, NOT temporaryDirectory: the system temp dir resolves to
        // /private/var/folders, which isSensitiveAbsolutePath denies by design —
        // every validation here would come back .sensitiveLocation and prove
        // nothing about the rules under test.
        scratch = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("jrc-roottest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    // MARK: - Resolution order

    /// A test that sets no root never reaches the real `~/Jamf-Reports` or the developer's
    /// chosen root: with the standard preferences, a test process gets a folder of its own,
    /// the same one for the whole run.
    func testATestProcessThatSetsNoRootGetsAFolderOfItsOwn() {
        let keys = ["JRC_TEST_WORKSPACES_ROOT", WorkspaceRootStore.environmentKey]
        let saved = keys.map { ProcessInfo.processInfo.environment[$0] }
        keys.forEach { unsetenv($0) }
        defer {
            for (key, value) in zip(keys, saved) { if let value { setenv(key, value, 1) } }
        }

        let root = WorkspaceRootStore.current()
        XCTAssertNotEqual(root.path, WorkspaceRootStore.defaultRoot.path)
        XCTAssertTrue(root.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      root.path)
        XCTAssertEqual(WorkspaceRootStore.current().path, root.path)
        XCTAssertEqual(ProfileService.workspacesRoot().path, root.path)
    }

    /// A `JRC_WORKSPACES_ROOT` exported in the developer's shell for the included CLI must not
    /// steer a test run onto their real workspaces: under XCTest the test root wins.
    func testATestProcessIgnoresTheHeadlessRootVariable() {
        let real = scratch.appendingPathComponent("real-root")
        let root = WorkspaceRootStore.current(
            environment: [WorkspaceRootStore.environmentKey: real.path])
        XCTAssertNotEqual(root.path, real.path)
        XCTAssertTrue(root.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      root.path)
    }

    func testDefaultsToHomeWhenNothingIsConfigured() {
        let root = WorkspaceRootStore.current(defaults: defaults, environment: [:])
        XCTAssertEqual(root.path, WorkspaceRootStore.defaultRoot.path)
    }

    func testStoredPreferenceIsUsed() throws {
        try WorkspaceRootStore.set(scratch, defaults: defaults)
        XCTAssertEqual(
            WorkspaceRootStore.current(defaults: defaults, environment: [:])
                .resolvingSymlinksInPath().path,
            scratch.resolvingSymlinksInPath().path
        )
    }

    /// The environment override is what a LaunchAgent and the included CLI use,
    /// so a headless run never depends on the GUI's preferences being readable.
    func testEnvironmentOverridesTheStoredPreference() throws {
        try WorkspaceRootStore.set(scratch, defaults: defaults)
        let other = scratch.appendingPathComponent("elsewhere")
        let root = WorkspaceRootStore.current(
            defaults: defaults,
            environment: [WorkspaceRootStore.environmentKey: other.path]
        )
        XCTAssertEqual(root.path, other.path)
    }

    func testEmptyEnvironmentValueIsIgnored() throws {
        try WorkspaceRootStore.set(scratch, defaults: defaults)
        let root = WorkspaceRootStore.current(
            defaults: defaults,
            environment: [WorkspaceRootStore.environmentKey: ""]
        )
        XCTAssertEqual(root.resolvingSymlinksInPath().path, scratch.resolvingSymlinksInPath().path)
    }

    func testClearingRestoresTheDefault() throws {
        try WorkspaceRootStore.set(scratch, defaults: defaults)
        try WorkspaceRootStore.set(nil, defaults: defaults)
        XCTAssertEqual(
            WorkspaceRootStore.current(defaults: defaults, environment: [:]).path,
            WorkspaceRootStore.defaultRoot.path
        )
        XCTAssertFalse(WorkspaceRootStore.isCustomised(defaults: defaults))
    }

    /// A share that has unmounted must NOT silently fall back to `~/Jamf-Reports`:
    /// that would start a second, empty history beside the real one and look
    /// like total data loss. The path stays as configured and the Config Doctor
    /// explains why nothing can be read.
    func testUnreachableRootIsNotSilentlyReplacedWithTheDefault() throws {
        try WorkspaceRootStore.set(scratch, defaults: defaults)
        try FileManager.default.removeItem(at: scratch)
        let root = WorkspaceRootStore.current(defaults: defaults, environment: [:])
        XCTAssertEqual(root.resolvingSymlinksInPath().path, scratch.resolvingSymlinksInPath().path)
        XCTAssertEqual(WorkspaceRootStore.validate(root), .missing)
    }

    // MARK: - Validation

    func testExistingWritableDirectoryIsOK() {
        XCTAssertEqual(WorkspaceRootStore.validate(scratch), .ok)
    }

    func testMissingDirectoryIsUsableAndCreatedOnSet() throws {
        let fresh = scratch.appendingPathComponent("new-root", isDirectory: true)
        XCTAssertEqual(WorkspaceRootStore.validate(fresh), .missing)
        XCTAssertTrue(WorkspaceRootStore.validate(fresh).isUsable)

        try WorkspaceRootStore.set(fresh, defaults: defaults)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fresh.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testFileIsRejected() throws {
        let file = scratch.appendingPathComponent("not-a-folder.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(WorkspaceRootStore.validate(file), .notADirectory)
        XCTAssertThrowsError(try WorkspaceRootStore.set(file, defaults: defaults))
    }

    /// Fleet inventory and run logs must never be aimed at a system directory
    /// or a credential store, whatever the operator types.
    func testSensitiveLocationsAreRejected() {
        let home = NSString(string: "~").expandingTildeInPath
        for path in ["/etc", "/System/Library", "\(home)/.ssh", "\(home)/Library/Preferences"] {
            XCTAssertEqual(
                WorkspaceRootStore.validate(URL(fileURLWithPath: path)),
                .sensitiveLocation,
                "\(path) should be refused as a workspace root"
            )
        }
    }

    /// The carve-out that makes the whole feature possible: every modern sync
    /// provider mounts under `~/Library/CloudStorage`, which the sensitive-path
    /// rule otherwise denies wholesale along with the rest of `~/Library`.
    func testCloudStorageMountsAreNotTreatedAsSensitive() {
        let home = NSString(string: "~").expandingTildeInPath
        let onedrive = URL(
            fileURLWithPath: "\(home)/Library/CloudStorage/OneDrive-Contoso/Team/Jamf Reports"
        )
        XCTAssertNotEqual(WorkspaceRootStore.validate(onedrive), .sensitiveLocation)
    }

    // MARK: - Ownership

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func makeRoot(_ name: String, mode: Int) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try chmod(url, mode)
        return url
    }

    func testAPrivateOwnedFolderPasses() throws {
        XCTAssertEqual(WorkspaceRootStore.validate(try makeRoot("private", mode: 0o700)), .ok)
    }

    func testAFolderOtherAccountsCanWriteIsRejected() throws {
        for (name, mode) in [("group", 0o775), ("world", 0o707), ("both", 0o777)] {
            let root = try makeRoot(name, mode: mode)
            XCTAssertEqual(WorkspaceRootStore.validate(root), .groupOrWorldWritable, name)
            XCTAssertThrowsError(try WorkspaceRootStore.set(root, defaults: defaults), name)
        }
    }

    func testAFolderWithAnACLIsRejected() throws {
        let root = try makeRoot("acl", mode: 0o700)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow list,search,readattr", root.path]
        try chmod.run()
        chmod.waitUntilExit()
        try XCTSkipIf(chmod.terminationStatus != 0, "this volume does not take ACLs")
        XCTAssertEqual(WorkspaceRootStore.validate(root), .hasACL)
    }

    /// A folder this test cannot make belong to someone else, so the predicate takes the uid.
    func testAFolderAnotherAccountOwnsIsRejected() throws {
        let root = try makeRoot("owned", mode: 0o700)
        XCTAssertNil(WorkspaceRootStore.ownershipProblem(atPath: root.path))
        XCTAssertEqual(
            WorkspaceRootStore.ownershipProblem(atPath: root.path, uid: getuid() &+ 1),
            .notOwned)
    }

    /// Network and File Provider mounts map owners and modes in ways that say nothing here.
    func testMountedAndProviderFoldersSkipTheOwnershipChecks() {
        XCTAssertTrue(WorkspaceRootStore.skipsOwnershipChecks("/Volumes/Team/Jamf-Reports"))
        XCTAssertTrue(WorkspaceRootStore.skipsOwnershipChecks(
            "/Users/a/Library/CloudStorage/OneDrive-Contoso/Jamf-Reports"))
        XCTAssertTrue(WorkspaceRootStore.skipsOwnershipChecks("/volumes/Team/Jamf-Reports"))
        XCTAssertTrue(WorkspaceRootStore.skipsOwnershipChecks(
            "/Users/a/library/cloudstorage/OneDrive-Contoso/Jamf-Reports"))
        XCTAssertFalse(WorkspaceRootStore.skipsOwnershipChecks("/Users/a/Documents/Jamf-Reports"))
        XCTAssertFalse(WorkspaceRootStore.skipsOwnershipChecks("/Users/a/Volumes/x"))
    }

    /// A stored root that now fails is still the root, so nothing is read from a second,
    /// empty one; the Doctor row explains it.
    func testAStoredRootThatFailsOwnershipIsStillReturnedOnRead() throws {
        let root = try makeRoot("stored", mode: 0o775)
        defaults.set(root.path, forKey: WorkspaceRootStore.defaultsKey)
        XCTAssertEqual(
            WorkspaceRootStore.current(defaults: defaults, environment: [:])
                .resolvingSymlinksInPath().path,
            root.resolvingSymlinksInPath().path)
    }

    func testRejectionMessagesAreActionable() {
        XCTAssertNotNil(WorkspaceRootStore.Validation.notWritable.message)
        XCTAssertNotNil(WorkspaceRootStore.Validation.sensitiveLocation.message)
        XCTAssertNotNil(WorkspaceRootStore.Validation.notOwned.message)
        XCTAssertNotNil(WorkspaceRootStore.Validation.groupOrWorldWritable.message)
        XCTAssertTrue(WorkspaceRootStore.Validation.hasACL.message?.contains("Documents") == true,
                      "the message says a macOS home subfolder can carry the ACL")
        XCTAssertNil(WorkspaceRootStore.Validation.ok.message, "a pass has nothing to say")
    }

    // MARK: - Read-time re-validation

    /// `set()` is not the only way a root gets configured — `defaults write`
    /// and a hand-edited launchd job both reach `current()` directly, so the
    /// sensitive-location rule is re-applied on read.
    func testStoredSensitivePathIsRefusedOnRead() {
        defaults.set(
            "\(NSString(string: "~").expandingTildeInPath)/.ssh",
            forKey: WorkspaceRootStore.defaultsKey
        )
        XCTAssertEqual(
            WorkspaceRootStore.current(defaults: defaults, environment: [:]).path,
            WorkspaceRootStore.defaultRoot.path
        )
    }

    func testSensitiveEnvironmentOverrideIsRefusedOnRead() {
        XCTAssertEqual(
            WorkspaceRootStore.current(
                defaults: defaults,
                environment: [WorkspaceRootStore.environmentKey: "/etc"]
            ).path,
            WorkspaceRootStore.defaultRoot.path
        )
    }

    /// The counterpart that must NOT happen: an unreachable root is the normal
    /// state of an unmounted share and stays as configured, so the app never
    /// silently starts a second empty history beside the real one.
    func testUnreachableRootIsStillReturnedOnRead() {
        let gone = scratch.appendingPathComponent("not-mounted-yet")
        defaults.set(gone.path, forKey: WorkspaceRootStore.defaultsKey)
        XCTAssertEqual(
            WorkspaceRootStore.current(defaults: defaults, environment: [:]).path,
            gone.path
        )
    }

    // MARK: - Display path

    /// Every screen that tells the operator where a file lives routes through
    /// these. Ten views used to hardcode `~/Jamf-Reports/<profile>/…`, which
    /// names a path that stops existing the moment the root moves.
    /// A root under the home folder, set through the test variable: a test process that
    /// sets none gets a temporary folder.
    private func withDefaultRootInEnvironment(_ body: () -> Void) {
        setenv("JRC_TEST_WORKSPACES_ROOT", WorkspaceRootStore.defaultRoot.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        body()
    }

    func testDisplayRootIsHomeRelativeByDefault() {
        withDefaultRootInEnvironment {
            XCTAssertEqual(WorkspaceRootStore.displayRoot, "~/Jamf-Reports")
        }
    }

    func testDisplayPathComposesProfileAndSubpath() {
        withDefaultRootInEnvironment(displayPathComposesProfileAndSubpath)
    }

    private func displayPathComposesProfileAndSubpath() {
        XCTAssertEqual(
            WorkspaceRootStore.displayPath(profile: "prod", subpath: "config.yaml"),
            "~/Jamf-Reports/prod/config.yaml"
        )
        XCTAssertEqual(
            WorkspaceRootStore.displayPath(profile: "prod"),
            "~/Jamf-Reports/prod"
        )
    }

    /// A root outside the home directory has no `~` form and must print in
    /// full — abbreviating it would name the wrong folder.
    func testDisplayRootPrintsNonHomePathsInFull() {
        setenv("JRC_TEST_WORKSPACES_ROOT", "/Volumes/TeamShare/Jamf Reports", 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        XCTAssertEqual(WorkspaceRootStore.displayRoot, "/Volumes/TeamShare/Jamf Reports")
    }

    // MARK: - Customised flag

    func testDefaultRootIsNotReportedAsCustomised() throws {
        try WorkspaceRootStore.set(WorkspaceRootStore.defaultRoot, defaults: defaults)
        XCTAssertFalse(
            WorkspaceRootStore.isCustomised(defaults: defaults),
            "explicitly choosing the default path is still the default layout"
        )
    }

    func testMovedRootIsReportedAsCustomised() throws {
        try WorkspaceRootStore.set(scratch, defaults: defaults)
        XCTAssertTrue(WorkspaceRootStore.isCustomised(defaults: defaults))
    }
}
