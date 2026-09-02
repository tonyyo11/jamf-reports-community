import XCTest
@testable import JamfReports

/// Regressions for three production crashes on a 2.7.0 shared workspace
/// (build 720, macOS 27). All three share a shape: an API that TRAPS or RAISES
/// on input that real tenants and real sync providers actually produce.
final class CrashRegressionTests: XCTestCase {

    // MARK: - Duplicate extension-attribute names

    /// `Dictionary(uniqueKeysWithValues:)` traps on a duplicate key. EA display
    /// names come from the server and are not unique, so a tenant with two EAs
    /// sharing a name took down the whole process — including every headless
    /// scheduled run, once the Config Doctor started running on them.
    ///
    /// Same defect class as PatchReleaseDateService's duplicate title_id.
    func testDuplicateEANamesDoNotTrap() throws {
        let snapshot = try loadSnapshot(
            definitions: """
            [{"id":"1","name":"Compliance Status"},
             {"id":"2","name":"Compliance Status"},
             {"id":"3","name":"FileVault"}]
            """,
            results: """
            [{"device":"mac-1","ea_name":"Compliance Status","value":"Pass"},
             {"device":"mac-2","ea_name":"FileVault","value":"Encrypted"}]
            """
        )
        XCTAssertEqual(snapshot.coverage.count, 2, "one row per distinct EA name")
        XCTAssertTrue(
            snapshot.coverage.contains { $0.eaName == "Compliance Status" },
            "the duplicated EA must still be reported, not dropped"
        )
    }

    /// First definition wins — the coverage row has to resolve to *a* stable id
    /// rather than flipping between duplicates run to run.
    func testDuplicateEANameResolvesToTheFirstDefinition() throws {
        let snapshot = try loadSnapshot(
            definitions: """
            [{"id":"first","name":"Dup"},{"id":"second","name":"Dup"}]
            """,
            results: """
            [{"device":"mac-1","ea_name":"Dup","value":"x"}]
            """
        )
        XCTAssertEqual(snapshot.coverage.first?.definitionId, "first")
    }

    /// Drives the real `load` path — a fabricated in-memory fixture would not
    /// prove the decoder reaches the same code the crash came from.
    private func loadSnapshot(definitions: String, results: String) throws
        -> ExtensionAttributeService.Snapshot {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jrc-eatest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let defsURL = dir.appendingPathComponent("computer-extension-attributes.json")
        let resURL = dir.appendingPathComponent("ea-results_20260827T120000.json")
        try definitions.write(to: defsURL, atomically: true, encoding: .utf8)
        try results.write(to: resURL, atomically: true, encoding: .utf8)

        return try XCTUnwrap(
            ExtensionAttributeService.load(resultsURL: resURL, definitionsURL: defsURL)
        )
    }

    // MARK: - Duplicate CSV header columns

    /// `Dictionary(uniqueKeysWithValues:)` over normalized headers traps when a
    /// messy export carries both `Serial Number` and `serial_number` — they
    /// normalize to the same key. A duplicate column is a bad export, not a
    /// reason to take down the Devices screen. Driven through the real `load`
    /// so the trap is pinned at the site that crashed, not at the helper.
    func testDuplicateCSVHeaderColumnsDoNotTrap() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-dupheader-\(UUID().uuidString)", isDirectory: true)
        let profile = "dupheader"
        let inbox = root.appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("csv-inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        // No filename date stamp, so the export reads as current via mtime and
        // the age bound cannot quietly drop the fixture.
        try """
        Computer Name,Serial Number,serial_number,Last Check-in
        Mac-1,FIRSTCOL,SECONDCOL,2026-09-01
        """.write(to: inbox.appendingPathComponent("inventory.csv"),
                  atomically: true, encoding: .utf8)

        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(snapshot.devices.count, 1, "a duplicate column must not lose the device")
        XCTAssertEqual(snapshot.devices.first?.serial, "FIRSTCOL",
                       "the first matching column wins; the duplicate is ignored")
    }

    // MARK: - Log writes that fail

    /// `FileHandle.write(_:)` bridges to `-[NSFileHandle writeData:]`, which
    /// RAISES an Objective-C exception Swift cannot catch — an uncatchable
    /// abort. Local disk almost never fails that write; a sync provider does.
    /// A dropped log line must never cost the collect that produced it.
    func testFailedLogWriteIsDroppedNotFatal() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jrc-logwrite-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forWritingTo: url)
        try handle.close()   // stands in for a handle the provider invalidated

        var warned = false
        ScheduledRunRecorder.appendOrDrop(
            Data("line".utf8), to: handle, label: "test", warned: &warned
        )
        XCTAssertTrue(warned, "the failure must be reported once, not swallowed silently")

        // And only once, however many lines follow.
        ScheduledRunRecorder.appendOrDrop(
            Data("another".utf8), to: handle, label: "test", warned: &warned
        )
        XCTAssertTrue(warned)
    }

    /// `LaunchAgentWriter.write` is static, so its warn-once latch is
    /// process-wide. Keying it by label is what keeps a second schedule's
    /// failure from being swallowed in a long-lived GUI session.
    func testRunLogWriteFailureIsReportedOncePerLabel() throws {
        LaunchAgentWriter.resetWriteFailureWarnings()
        addTeardownBlock { LaunchAgentWriter.resetWriteFailureWarnings() }

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jrc-agentlog-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.close()   // stands in for a handle the provider invalidated

        let first = "\(LaunchAgentWriter.labelPrefix).acme.daily"
        let second = "\(LaunchAgentWriter.labelPrefix).acme.weekly"

        XCTAssertFalse(LaunchAgentWriter.hasWarnedWriteFailure(for: first))
        LaunchAgentWriter.appendRunLog(Data("line".utf8), to: handle, label: first)
        XCTAssertTrue(LaunchAgentWriter.hasWarnedWriteFailure(for: first),
                      "the first failure must be reported, not swallowed")

        // A process-global latch would leave this schedule silent.
        XCTAssertFalse(LaunchAgentWriter.hasWarnedWriteFailure(for: second))
        LaunchAgentWriter.appendRunLog(Data("line".utf8), to: handle, label: second)
        XCTAssertTrue(LaunchAgentWriter.hasWarnedWriteFailure(for: second))
    }

    func testSuccessfulLogWriteDoesNotWarn() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jrc-logwrite-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var warned = false
        ScheduledRunRecorder.appendOrDrop(
            Data("hello\n".utf8), to: handle, label: "test", warned: &warned
        )
        XCTAssertFalse(warned)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello\n")
    }
}
