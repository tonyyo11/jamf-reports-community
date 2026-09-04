import XCTest
@testable import JamfReports

/// `pro report patch-status --scan-failures --output json` prints up to three
/// `── section ──` blocks on stdout instead of one document. Its sibling
/// `update-status --scan-failures` guards structured output and returns one
/// object with named keys, so this is an omission in one command rather than a
/// convention — which is why only `patch-device-failures` is treated specially.
///
/// Shapes verified against jamf-cli v1.27.0 source and a real production
/// snapshot carrying all three sections (133 compliance / 18 policy / 30 device
/// rows).
final class PatchScanFailureSectionsTests: XCTestCase {

    private let compliance = """
    ── Patch Title Compliance ──
    [
      {"title": "Firefox", "id": "1", "on_latest": 100, "on_other": 20,
       "total": 120, "latest": "130.0", "compliance_pct": "83%"}
    ]
    """

    private let policies = """

    ── Patch Policies With Failures (2) ──
    [
      {"policy": "Firefox 130.0", "failed": 3, "pending": 1, "deferred": 0,
       "completed": 8, "failure_rate": "25%"}
    ]
    """

    private let devices = """

    ── Devices With Patch Failures (2) ──
    [
      {"policy": "Firefox 130.0", "policy_id": "42", "device": "mac-001",
       "device_id": "123", "attempt": 3, "last_action": "Retrying",
       "os_version": "15.7.3"}
    ]
    """

    private func rows(_ data: Data?, file: StaticString = #filePath,
                      line: UInt = #line) throws -> [[String: Any]] {
        let unwrapped = try XCTUnwrap(data, "expected a payload", file: file, line: line)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: unwrapped) as? [[String: Any]],
            "payload was not an array of objects", file: file, line: line)
    }

    // MARK: - Section selection

    /// The whole point: with all three sections present, the device rows are the
    /// ones this kind holds — not the compliance rows that lead the stream.
    func testSelectsTheDeviceSectionFromAFullStream() throws {
        let stream = Data((compliance + policies + devices).utf8)
        let picked = try rows(ReportEngine.patchDeviceFailurePayload(from: stream))
        XCTAssertEqual(picked.count, 1)
        XCTAssertEqual(picked[0]["device_id"] as? String, "123",
                       "must select the device-failure section, not compliance or policies")
    }

    /// A tenant with no patch policy failures emits only the compliance section.
    /// Filing those rows under patch-device-failures is the specific bug this
    /// replaces: they decode as the wrong type and the sheet reads as broken
    /// rather than empty.
    func testComplianceOnlyStreamYieldsNoFailuresRatherThanComplianceRows() throws {
        let picked = try rows(ReportEngine.patchDeviceFailurePayload(from: Data(compliance.utf8)))
        XCTAssertTrue(picked.isEmpty,
                      "no device section means no failures — never the compliance rows")
    }

    /// Policies can have failures while no per-device rows come back. Still no
    /// device failures, and still not the policy rows.
    func testPolicySectionWithoutDeviceSectionYieldsNoFailures() throws {
        let stream = Data((compliance + policies).utf8)
        let picked = try rows(ReportEngine.patchDeviceFailurePayload(from: stream))
        XCTAssertTrue(picked.isEmpty,
                      "policy rows are a different shape and must not stand in for devices")
    }

    /// Section order is not the selector — shape is. If upstream reorders or
    /// renames the headings, selection must still land on the device rows.
    func testSelectionDoesNotDependOnSectionOrder() throws {
        let stream = Data((compliance + devices + policies).utf8)
        let picked = try rows(ReportEngine.patchDeviceFailurePayload(from: stream))
        XCTAssertEqual(picked[0]["device_id"] as? String, "123")
    }

    // MARK: - The guard this must not weaken

    /// Genuinely unusable output must still return nil so the caller records a
    /// failure. Returning an empty array here would report a renamed command as
    /// "no failures" — the silent success the guard exists to prevent.
    func testUnparseableOutputIsRejectedRatherThanReportedAsZeroFailures() {
        let cobraHelp = Data("""
        Generate operational reports from Jamf Pro data

        Usage:
          jamf-cli pro report [command]
        """.utf8)
        XCTAssertNil(ReportEngine.patchDeviceFailurePayload(from: cobraHelp),
                     "help text must not be recorded as a clean zero-failure result")
    }

    /// A truncated section is not valid JSON and must not be salvaged into a
    /// partial answer.
    func testTruncatedSectionIsRejected() {
        let truncated = Data("""
        ── Devices With Patch Failures (2) ──
        [
          {"policy": "Firefox", "device_id": "123",
        """.utf8)
        XCTAssertNil(ReportEngine.patchDeviceFailurePayload(from: truncated))
    }

    // MARK: - Only this kind is treated specially

    /// update-status --scan-failures returns one object with error_devices and
    /// failed_plans as named keys, so it must keep the generic path. Pinning
    /// this stops the special case being widened on the assumption that both
    /// commands misbehave.
    func testUpdateDeviceFailuresIsNotTreatedAsSectioned() {
        XCTAssertFalse(ReportEngine.sectionedCollectKinds.contains("update-device-failures"))
        XCTAssertEqual(ReportEngine.sectionedCollectKinds, ["patch-device-failures"])
    }

    // MARK: - Saying which shape produced the zero

    /// A stream with several sections and no device rows is indistinguishable
    /// from an upstream rename of `device_id` unless the run says so. The `[]`
    /// result is unchanged — this is a line in the log, not a new failure.
    func testMultiSectionStreamWithoutDeviceRowsWarns() throws {
        let collector = LineCollector()
        let stream = Data((compliance + policies).utf8)

        let picked = try rows(
            ReportEngine.patchDeviceFailurePayload(from: stream, onLine: collector.append)
        )

        XCTAssertTrue(picked.isEmpty, "the warning must not change the result")
        XCTAssertEqual(collector.texts.count, 1, "got: \(collector.texts)")
        let line = try XCTUnwrap(collector.texts.first)
        XCTAssertTrue(line.hasPrefix("[warn] patch-device-failures: 2 sections parsed, "),
                      "the count is the diagnostic — got: \(line)")
        XCTAssertTrue(line.contains("none carried device rows — treating as no failures"),
                      "got: \(line)")
    }

    /// The ordinary healthy tenant emits ONE section (compliance) and no
    /// devices. Warning there would fire on nearly every run and train the
    /// operator to ignore the line that matters.
    func testSingleSectionStreamDoesNotWarn() throws {
        let collector = LineCollector()
        _ = ReportEngine.patchDeviceFailurePayload(
            from: Data(compliance.utf8), onLine: collector.append
        )
        XCTAssertTrue(collector.texts.isEmpty, "got: \(collector.texts)")
    }

    /// Finding the device section is the success case — no warning either.
    func testFullStreamWithDeviceRowsDoesNotWarn() throws {
        let collector = LineCollector()
        _ = ReportEngine.patchDeviceFailurePayload(
            from: Data((compliance + policies + devices).utf8), onLine: collector.append
        )
        XCTAssertTrue(collector.texts.isEmpty, "got: \(collector.texts)")
    }

    /// The generic salvage keeps working for everything else: a single document
    /// behind a decorative prefix is still forgiven.
    func testGenericPrefixSalvageStillWorksForOtherKinds() throws {
        let prefixed = Data("── Something ──\n[{\"id\": 1}]".utf8)
        let picked = try rows(ReportEngine.jsonPayload(from: prefixed))
        XCTAssertEqual(picked.count, 1)
    }

    /// But the generic salvage must still refuse a multi-section stream, since
    /// it cannot know which section was wanted.
    func testGenericSalvageRefusesAMultiSectionStream() {
        let stream = Data((compliance + policies + devices).utf8)
        XCTAssertNil(ReportEngine.jsonPayload(from: stream),
                     "the generic path must not silently return the first of several sections")
    }
}

/// Thread-safe collector for streamed log-line text — `onLine` is `@Sendable`,
/// so a plainly captured `var` is not.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    /// Usable directly as an `onLine` handler.
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in
            self.lock.lock(); defer { self.lock.unlock() }
            self.lines.append(line.text)
        }
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
