import Foundation
import XCTest
@testable import JamfReports

/// Direct test coverage for `DeviceLookupIndex` (BACKLOG: PR-2 Codex review).
///
/// Covers the five behaviors not exercised by view-level tests:
/// 1. **Newest-JSON selection** when multiple snapshots exist (mtime wins).
/// 2. **`.partial` filtering** — partial-export files are excluded from the index.
/// 3. **Envelope vs bare-array decoding** — both shapes round-trip.
/// 4. **Resolve priority** — id → serial → name (substring), de-duped.
/// 5. **Kind filtering** — `.computer` vs `.mobile` filters at resolve time.
///
/// Tests are `#if DEBUG`-gated because they rely on `JRC_TEST_WORKSPACES_ROOT`
/// (which is itself `#if DEBUG`-gated in `ProfileService.workspacesRoot()`).
@MainActor
final class DeviceLookupIndexTests: XCTestCase {

    #if DEBUG

    nonisolated(unsafe) private var testRoot: URL!
    nonisolated(unsafe) private var workspacesRoot: URL!
    nonisolated(unsafe) private var workspace: URL!
    nonisolated(unsafe) private var dataDir: URL!
    private let profileSlug = "lookup-index-test"

    override func setUpWithError() throws {
        try super.setUpWithError()
        testRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DeviceLookupIndex-\(UUID().uuidString)", isDirectory: true)
        workspacesRoot = testRoot.appendingPathComponent("Jamf-Reports", isDirectory: true)
        workspace = workspacesRoot.appendingPathComponent(profileSlug, isDirectory: true)
        dataDir = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let root = testRoot {
            try? FileManager.default.removeItem(at: root)
        }
        testRoot = nil
        workspacesRoot = nil
        workspace = nil
        dataDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture helpers

    /// Write a JSON file (any encodable value) into `<dataDir>/<subdir>/<filename>`.
    /// Returns the URL so the test can backdate its mtime to test newest-wins.
    @discardableResult
    private func writeSnapshot(
        subdir: String,
        filename: String,
        json: Any
    ) throws -> URL {
        let dir = dataDir.appendingPathComponent(subdir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: url)
        return url
    }

    /// Backdate a file's mtime so the "newest" comparison is deterministic.
    private func setModificationDate(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Newest-JSON selection

    func testNewestJSONWinsWhenMultipleSnapshotsExist() throws {
        // Older snapshot has only one device, newer has two. The index must
        // pick the newer file and surface both devices.
        let older = try writeSnapshot(
            subdir: "computers-list",
            filename: "computers-list_2026-01-01.json",
            json: [
                ["id": "10", "general": ["name": "Old-Mac"],
                 "hardware": ["serialNumber": "OLD0001"]]
            ]
        )
        let newer = try writeSnapshot(
            subdir: "computers-list",
            filename: "computers-list_2026-05-01.json",
            json: [
                ["id": "20", "general": ["name": "New-Mac-A"],
                 "hardware": ["serialNumber": "NEW0001"]],
                ["id": "21", "general": ["name": "New-Mac-B"],
                 "hardware": ["serialNumber": "NEW0002"]]
            ]
        )
        try setModificationDate(older, Date(timeIntervalSince1970: 1_700_000_000))
        try setModificationDate(newer, Date(timeIntervalSince1970: 1_750_000_000))

        let index = DeviceLookupIndex()
        index.load(profile: profileSlug)

        let ids = Set(index.candidates.map(\.id))
        XCTAssertEqual(ids, ["20", "21"],
                       "Newest snapshot's devices must be the only ones indexed; got \(ids)")
        XCTAssertNil(index.lastError, "No error expected when newest snapshot decodes cleanly")
    }

    // MARK: - `.partial` filtering

    func testPartialFilesAreExcludedFromIndex() throws {
        // A `.partial.json` file must be ignored even when it's the newest.
        // The good file (older mtime) is the only one the index should see.
        let good = try writeSnapshot(
            subdir: "computers-list",
            filename: "computers-list.json",
            json: [
                ["id": "30", "general": ["name": "Good-Mac"],
                 "hardware": ["serialNumber": "GOOD0001"]]
            ]
        )
        let partial = try writeSnapshot(
            subdir: "computers-list",
            filename: "computers-list_2026-05-15.partial.json",
            json: [
                ["id": "99", "general": ["name": "Partial-Mac"],
                 "hardware": ["serialNumber": "BAD0001"]]
            ]
        )
        // Make the partial NEWER — to prove it's filtered by name, not by date.
        try setModificationDate(good, Date(timeIntervalSince1970: 1_700_000_000))
        try setModificationDate(partial, Date(timeIntervalSince1970: 1_750_000_000))

        let index = DeviceLookupIndex()
        index.load(profile: profileSlug)

        let ids = Set(index.candidates.map(\.id))
        XCTAssertEqual(ids, ["30"],
                       "Partial files must be excluded; got \(ids)")
        XCTAssertFalse(ids.contains("99"),
                       "Partial-file device 99 leaked into the index")
    }

    // MARK: - Envelope vs bare-array decoding

    func testBareArrayDecodes() throws {
        try writeSnapshot(
            subdir: "computers-list",
            filename: "computers-list.json",
            json: [
                ["id": "1", "general": ["name": "Bare-Array-Mac"],
                 "hardware": ["serialNumber": "BARE0001"]]
            ]
        )
        let index = DeviceLookupIndex()
        index.load(profile: profileSlug)
        XCTAssertEqual(index.candidates.count, 1)
        XCTAssertEqual(index.candidates.first?.name, "Bare-Array-Mac")
    }

    func testEnvelopeShapeDecodes() throws {
        // {"results": [...]} envelope must work just like a bare array.
        try writeSnapshot(
            subdir: "computers-list",
            filename: "computers-list.json",
            json: [
                "results": [
                    ["id": "2", "general": ["name": "Enveloped-Mac"],
                     "hardware": ["serialNumber": "ENV0001"]]
                ]
            ]
        )
        let index = DeviceLookupIndex()
        index.load(profile: profileSlug)
        XCTAssertEqual(index.candidates.count, 1)
        XCTAssertEqual(index.candidates.first?.name, "Enveloped-Mac")
    }

    // MARK: - resolve() priority (id → serial → name)

    func testResolvePrioritisesIDOverSerialAndName() throws {
        try writeSnapshot(
            subdir: "computers-list",
            filename: "computers-list.json",
            json: [
                ["id": "ABC", "general": ["name": "ABC-named-Mac"],
                 "hardware": ["serialNumber": "OTHER123"]],
                ["id": "100", "general": ["name": "Mac with ABC in name"],
                 "hardware": ["serialNumber": "ABC"]]
            ]
        )
        let index = DeviceLookupIndex()
        index.load(profile: profileSlug)

        // "ABC" matches the id of the first device exactly, the serial of the
        // second device exactly, AND the name of the second device as a substring.
        // Priority is id → serial → name; first device should come first.
        let results = index.resolve("ABC")
        XCTAssertEqual(results.count, 2, "Both devices should match across the three priority tiers")
        XCTAssertEqual(results[0].id, "ABC",
                       "Exact-id match must win the first slot")
        XCTAssertEqual(results[1].id, "100",
                       "Serial match comes before name substring; serial-matched device must be second")
    }

    func testResolveIsCaseInsensitiveForSerialAndName() throws {
        try writeSnapshot(
            subdir: "computers-list",
            filename: "computers-list.json",
            json: [
                ["id": "1", "general": ["name": "MIXED-Case-Mac"],
                 "hardware": ["serialNumber": "AbCdEf"]]
            ]
        )
        let index = DeviceLookupIndex()
        index.load(profile: profileSlug)

        XCTAssertEqual(index.resolve("abcdef").count, 1,
                       "Serial match must be case-insensitive")
        XCTAssertEqual(index.resolve("mixed").count, 1,
                       "Name substring match must be case-insensitive")
    }

    func testResolveEmptyTermReturnsEmpty() throws {
        try writeSnapshot(
            subdir: "computers-list",
            filename: "computers-list.json",
            json: [
                ["id": "1", "general": ["name": "Some-Mac"],
                 "hardware": ["serialNumber": "X"]]
            ]
        )
        let index = DeviceLookupIndex()
        index.load(profile: profileSlug)
        XCTAssertEqual(index.resolve("").count, 0)
        XCTAssertEqual(index.resolve("   ").count, 0,
                       "Whitespace-only term must trim to empty and return no results")
    }

    // MARK: - Kind filtering

    func testResolveFiltersByKindWhenSpecified() throws {
        try writeSnapshot(
            subdir: "computers-list",
            filename: "computers-list.json",
            json: [
                ["id": "1", "general": ["name": "Shared-Name"],
                 "hardware": ["serialNumber": "MAC0001"]]
            ]
        )
        try writeSnapshot(
            subdir: "mobile-devices-list",
            filename: "mobile-devices-list.json",
            json: [
                ["mobileDeviceId": "1", "general": ["displayName": "Shared-Name"],
                 "hardware": ["serialNumber": "MOB0001"]]
            ]
        )
        let index = DeviceLookupIndex()
        index.load(profile: profileSlug)

        // Without kind filter — both devices match the name "Shared-Name".
        XCTAssertEqual(index.resolve("Shared-Name").count, 2,
                       "Without kind filter both kinds match")

        // Kind=.computer — mobile must be excluded.
        let computers = index.resolve("Shared-Name", kind: .computer)
        XCTAssertEqual(computers.count, 1)
        XCTAssertEqual(computers.first?.kind, .computer)

        // Kind=.mobile — computer must be excluded.
        let mobiles = index.resolve("Shared-Name", kind: .mobile)
        XCTAssertEqual(mobiles.count, 1)
        XCTAssertEqual(mobiles.first?.kind, .mobile)
    }

    func testMobileParserFallsBackToIDForIdWhenMobileDeviceIdAbsent() throws {
        // Mobile parser tries `mobileDeviceId` first, then top-level `id`. The
        // name fall-back chain is general.displayName → general.name →
        // dict.displayName → rawID — it does NOT consult top-level `name`,
        // so a record like `{"id": "42", "name": "X"}` gets indexed with
        // name=="42". The serial fall-back is hardware.serialNumber →
        // dict.serialNumber.
        try writeSnapshot(
            subdir: "mobile-devices-list",
            filename: "mobile-devices-list.json",
            json: [
                ["id": "42", "displayName": "Flat-iPad",
                 "serialNumber": "FLAT0001"]
            ]
        )
        let index = DeviceLookupIndex()
        index.load(profile: profileSlug)
        XCTAssertEqual(index.candidates.count, 1)
        XCTAssertEqual(index.candidates.first?.kind, .mobile)
        XCTAssertEqual(index.candidates.first?.id, "42",
                       "id fall-back to top-level `id` when mobileDeviceId absent")
        XCTAssertEqual(index.candidates.first?.name, "Flat-iPad",
                       "name resolves from top-level displayName")
        XCTAssertEqual(index.candidates.first?.serial, "FLAT0001",
                       "serial resolves from top-level serialNumber")
    }

    // MARK: - Error surface

    func testInvalidProfileSlugProducesErrorMessage() {
        let index = DeviceLookupIndex()
        // Dotted slugs are rejected by ProfileService.isValid.
        index.load(profile: "bad.profile")
        XCTAssertTrue(index.candidates.isEmpty)
        XCTAssertNotNil(index.lastError)
        XCTAssertTrue(
            index.lastError?.contains("Workspace not found") == true,
            "Expected 'Workspace not found' error; got: \(index.lastError ?? "nil")"
        )
    }

    func testEmptyDataDirProducesActionableMessage() {
        // Workspace exists (created in setUp) but no JSON snapshots yet.
        let index = DeviceLookupIndex()
        index.load(profile: profileSlug)
        XCTAssertTrue(index.candidates.isEmpty)
        XCTAssertEqual(
            index.lastError,
            "No cached inventory found. Run a collect to populate the index."
        )
    }

    #endif // DEBUG
}
