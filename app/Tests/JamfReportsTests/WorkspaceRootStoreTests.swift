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
            .appendingPathComponent(".jrc-roottest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    // MARK: - Resolution order

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

    func testRejectionMessagesAreActionable() {
        XCTAssertNotNil(WorkspaceRootStore.Validation.notWritable.message)
        XCTAssertNotNil(WorkspaceRootStore.Validation.sensitiveLocation.message)
        XCTAssertNil(WorkspaceRootStore.Validation.ok.message, "a pass has nothing to say")
    }

    // MARK: - Read-time re-validation

    /// `set()` is not the only way a root gets configured — `defaults write`
    /// and a hand-edited launchd job both reach `current()` directly, so the
    /// sensitive-location rule is re-applied on read.
    func testStoredSensitivePathIsRefusedOnRead() {
        defaults.set("\(NSString(string: "~").expandingTildeInPath)/.ssh", forKey: WorkspaceRootStore.defaultsKey)
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
    func testDisplayRootIsHomeRelativeByDefault() {
        XCTAssertEqual(WorkspaceRootStore.displayRoot, "~/Jamf-Reports")
    }

    func testDisplayPathComposesProfileAndSubpath() {
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
        setenv(WorkspaceRootStore.environmentKey, "/Volumes/TeamShare/Jamf Reports", 1)
        defer { unsetenv(WorkspaceRootStore.environmentKey) }
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
