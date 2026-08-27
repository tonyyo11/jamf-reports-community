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
