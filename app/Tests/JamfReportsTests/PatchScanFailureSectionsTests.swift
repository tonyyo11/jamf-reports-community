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
        try rows(data.map(ReportEngine.PatchFailurePayload.rows) ?? .unreadable,
                 file: file, line: line)
    }

    private func rows(_ payload: ReportEngine.PatchFailurePayload, file: StaticString = #filePath,
                      line: UInt = #line) throws -> [[String: Any]] {
        guard case .rows(let unwrapped) = payload else {
            XCTFail("expected rows, got \(payload)", file: file, line: line)
            return []
        }
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

    /// A stream with only the compliance section has no device section: never the compliance
    /// rows, and not a clean zero either, which against an earlier scan would read as every
    /// failure clearing at once.
    func testComplianceOnlyStreamHasNoDeviceSection() {
        XCTAssertEqual(ReportEngine.patchDeviceFailurePayload(from: Data(compliance.utf8)),
                       .noDeviceSection)
    }

    /// Policy rows are a different shape and must not stand in for devices.
    func testPolicySectionWithoutDeviceSectionHasNoDeviceSection() {
        let stream = Data((compliance + policies).utf8)
        XCTAssertEqual(ReportEngine.patchDeviceFailurePayload(from: stream), .noDeviceSection)
    }

    /// Section order is not the selector — shape is. If upstream reorders or
    /// renames the headings, selection must still land on the device rows.
    func testSelectionDoesNotDependOnSectionOrder() throws {
        let stream = Data((compliance + devices + policies).utf8)
        let picked = try rows(ReportEngine.patchDeviceFailurePayload(from: stream))
        XCTAssertEqual(picked[0]["device_id"] as? String, "123")
    }

    // MARK: - jamf-cli 1.29: one document of labelled sections

    /// From 1.29 the command prints one array of `{section, data, fetch_error}`
    /// objects instead of the heading stream. Same rows, different envelope.
    private func envelope(devices: String, policyError: String = "",
                          deviceError: String = "") -> Data {
        Data("""
        [
          {"section": "title_compliance", "data": [{"title": "Firefox", "id": "1"}]},
          {"section": "policy_failures", "data": [], "fetch_error": "\(policyError)"},
          {"section": "device_failures", "data": \(devices), "fetch_error": "\(deviceError)"}
        ]
        """.utf8)
    }

    func testEnvelopeSelectsTheDeviceSection() throws {
        let stream = envelope(devices: """
        [{"policy": "Firefox 130.0", "policy_id": "42", "device": "mac-001", "device_id": "123"}]
        """)
        let picked = try rows(ReportEngine.patchDeviceFailurePayload(from: stream))
        XCTAssertEqual(picked.count, 1)
        let row = try XCTUnwrap(picked.first, "no device rows selected")
        XCTAssertEqual(row["device_id"] as? String, "123",
                       "must be the device rows, not the section objects or the compliance rows")
    }

    /// Empty device data with no fetch error is the ordinary healthy tenant on
    /// 1.29 — a real zero.
    func testEnvelopeWithNoDeviceRowsIsAnEmptyAnswer() throws {
        let picked = try rows(ReportEngine.patchDeviceFailurePayload(
            from: envelope(devices: "[]")))
        XCTAssertTrue(picked.isEmpty)
    }

    /// Go encodes a nil slice as null and drops it under `omitempty`, so a
    /// device section with null or absent data is the same zero as `[]` — not
    /// output to call unreadable. Data of any other type still is.
    func testEnvelopeWithNullOrMissingDeviceDataIsAnEmptyAnswer() throws {
        let nullData = try rows(ReportEngine.patchDeviceFailurePayload(
            from: envelope(devices: "null")))
        XCTAssertTrue(nullData.isEmpty, "data: null is no failures")

        let missing = Data("""
        [
          {"section": "title_compliance", "data": [{"title": "Firefox", "id": "1"}]},
          {"section": "policy_failures", "data": [], "fetch_error": ""},
          {"section": "device_failures", "fetch_error": ""}
        ]
        """.utf8)
        let missingData = try rows(ReportEngine.patchDeviceFailurePayload(from: missing))
        XCTAssertTrue(missingData.isEmpty, "a device section without data is no failures")

        XCTAssertEqual(ReportEngine.patchDeviceFailurePayload(from: envelope(devices: "\"none\"")),
                       .noDeviceSection, "data that is neither rows nor null is not an answer")
    }

    /// A section jamf-cli could not fetch is empty AND says so. That is not a
    /// clean zero: nil makes the caller record the kind as not landed, and
    /// `patchFetchError` tells it which section failed and why.
    func testEnvelopeFetchErrorIsNotACleanZero() throws {
        let deviceFailure = envelope(devices: "[]", deviceError: "request failed (HTTP 503)")
        XCTAssertEqual(ReportEngine.patchDeviceFailurePayload(from: deviceFailure), .noDeviceSection)
        let found = try XCTUnwrap(ReportEngine.patchFetchError(in: deviceFailure))
        XCTAssertEqual(found.section, "device_failures")
        XCTAssertEqual(found.error, "request failed (HTTP 503)")

        let policyFailure = envelope(devices: "[]", policyError: "request failed (HTTP 401)")
        XCTAssertEqual(ReportEngine.patchDeviceFailurePayload(from: policyFailure), .noDeviceSection,
            "device rows depend on policy rows upstream, so a policy fetch error is not zero either")
        XCTAssertEqual(ReportEngine.patchFetchError(in: policyFailure)?.section, "policy_failures")
        XCTAssertNil(ReportEngine.patchFetchError(in: envelope(devices: "[]")))
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
        XCTAssertEqual(ReportEngine.patchDeviceFailurePayload(from: cobraHelp), .unreadable,
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
        XCTAssertEqual(ReportEngine.patchDeviceFailurePayload(from: truncated), .unreadable)
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

    // MARK: - The captured NFR failure

    /// A real failing patch policy (NFR, jamf-cli 1.38.0, values replaced): the device rows
    /// are kept, the policy section is not, and `attempt` arrives as text.
    func testCapturedFailureSavesItsDeviceRow() throws {
        let url = TestFixtures.dir("patch")
            .appendingPathComponent("patch-scan-failures-captured.json")
        let payload = ReportEngine.patchDeviceFailurePayload(from: try Data(contentsOf: url))
        guard case .rows(let data) = payload else { return XCTFail("got \(payload)") }
        let decoded = try JSONDecoder().decode([PatchFailureRow].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.attempt, 2)
        XCTAssertEqual(decoded.first?.deviceId, "101")
        XCTAssertEqual(decoded.first?.policyId, "11")
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
