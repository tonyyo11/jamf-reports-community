import Foundation
import XCTest
@testable import JamfReports

/// `EAParseHealthService` diagnoses typed EA parse health and EA coverage drift.
/// Parse semantics mirror the engine's typed handlers; skeletons must be PII-safe.
final class EAParseHealthServiceTests: XCTestCase {

    private typealias Service = EAParseHealthService

    // MARK: - percentage

    func testPercentageAcceptsTolerantForms() {
        let health = Service.assess(
            column: "Disk Used",
            values: ["0", "100", " 55 ", "12.5%", "  99% ", "0.0"],
            type: .percentage
        )
        XCTAssertEqual(health.nonEmpty, 6)
        XCTAssertEqual(health.parseable, 6)
        XCTAssertEqual(health.parseRate, 1.0)
        XCTAssertTrue(health.topUnparseable.isEmpty)
    }

    func testPercentageRejectsOutOfRangeAndNonNumeric() {
        let health = Service.assess(
            column: "Disk Used",
            values: ["101", "-1", "abc", "50", "200%"],
            type: .percentage
        )
        XCTAssertEqual(health.nonEmpty, 5)
        XCTAssertEqual(health.parseable, 1, "only 50 lands in 0...100")
    }

    // MARK: - version

    func testVersionAcceptsDottedNumericIsh() {
        let health = Service.assess(
            column: "App Version",
            values: ["15", "15.7.3", "1.2.3-beta", "130.0"],
            type: .version
        )
        XCTAssertEqual(health.parseable, 4)
    }

    func testVersionRejectsNonNumericLead() {
        let health = Service.assess(
            column: "App Version",
            values: ["not a version", "v1.2", ".5", "3.0"],
            type: .version
        )
        // "v1.2" and "not a version" and ".5" fail the ^\d prefix; "3.0" passes.
        XCTAssertEqual(health.parseable, 1)
    }

    // MARK: - date (engine formats)

    func testDateParsesEngineFormats() {
        let health = Service.assess(
            column: "Cert Expiry",
            values: [
                "2026-07-02",
                "2026-07-02 13:45:00",
                "07/02/2026",
                "2026-07-02T13:45:00Z",
            ],
            type: .date
        )
        XCTAssertEqual(health.parseable, 4)
    }

    func testDateRejectsUnknownFormat() {
        // Note: ICU coerces month names through numeric patterns ("July 2 2026"
        // parses under MM/dd/yyyy), so use strings no engine format accepts.
        let health = Service.assess(
            column: "Cert Expiry",
            values: ["N/A", "2026-07-02", "yesterday"],
            type: .date
        )
        XCTAssertEqual(health.parseable, 1)
        XCTAssertEqual(health.topUnparseable.count, 2)
    }

    // MARK: - boolean / text (no parse-failure mode)

    func testBooleanNonEmptyAlwaysParseable() {
        let health = Service.assess(
            column: "FileVault",
            values: ["Encrypted", "Not Encrypted", "gibberish", "", "  "],
            type: .boolean
        )
        XCTAssertEqual(health.totalRows, 5)
        XCTAssertEqual(health.nonEmpty, 3)
        XCTAssertEqual(health.parseable, 3, "boolean has no parse failure — parseable == nonEmpty")
        XCTAssertTrue(health.topUnparseable.isEmpty)
    }

    func testTextNonEmptyAlwaysParseable() {
        let health = Service.assess(
            column: "Notes",
            values: ["anything", "at all", ""],
            type: .text
        )
        XCTAssertEqual(health.parseable, health.nonEmpty)
        XCTAssertEqual(health.parseable, 2)
    }

    // MARK: - parseRate nil when nonEmpty == 0

    func testParseRateNilWhenAllBlank() {
        let health = Service.assess(column: "Empty", values: ["", "  ", "\t"], type: .percentage)
        XCTAssertEqual(health.nonEmpty, 0)
        XCTAssertNil(health.parseRate)
    }

    // MARK: - assessIntCount

    func testIntCountWithoutBound() {
        let health = Service.assessIntCount(
            column: "mSCP Failures",
            values: ["0", "3", "42", "-1", "x", "999"],
            maxValid: nil
        )
        XCTAssertEqual(health.nonEmpty, 6)
        XCTAssertEqual(health.parseable, 4, "-1 (negative) and x (non-int) fail")
    }

    func testIntCountWithBoundRejectsAboveMax() {
        let health = Service.assessIntCount(
            column: "mSCP Failures",
            values: ["0", "50", "51", "100"],
            maxValid: 50
        )
        XCTAssertEqual(health.parseable, 2, "51 and 100 exceed the rule-count bound of 50")
    }

    func testIntCountBoundIsInclusive() {
        let health = Service.assessIntCount(column: "c", values: ["50"], maxValid: 50)
        XCTAssertEqual(health.parseable, 1)
    }

    func testIntCountAcceptsWholeDoublesLikeBanding() {
        // The banding lens (intValue) tolerates whole doubles ("2.0" → 2); a
        // fractional or negative value stays unparseable.
        let health = Service.assessIntCount(
            column: "mSCP Failures",
            values: ["3", "2.0", "4.5", "-1"],
            maxValid: nil
        )
        XCTAssertEqual(health.nonEmpty, 4)
        XCTAssertEqual(health.parseable, 2, "3 and 2.0 parse; 4.5 fractional and -1 negative fail")
    }

    // MARK: - skeleton PII property

    func testSkeletonNeverLeaksInputCharacters() {
        let inputs = ["Not Applicable (M1)", "C02SECRET1234", "user@corp.example", "ABC-123.4"]
        for input in inputs {
            let skel = Service.skeleton(input)
            // "x"/"9" are the mask characters, so an input "x" or "9"
            // legitimately appears in the output — exclude them from the check.
            for ch in input where (ch.isLetter || ch.isNumber) && ch != "x" && ch != "9" {
                XCTAssertFalse(
                    skel.contains(ch),
                    "skeleton '\(skel)' must not contain input char '\(ch)' from '\(input)'"
                )
            }
        }
    }

    func testSkeletonShape() {
        XCTAssertEqual(Service.skeleton("Not Applicable (M1)"), "xxx xxxxxxxxxx (x9)")
        XCTAssertEqual(Service.skeleton("v1.2-beta"), "x9.9-xxxx")
    }

    func testSkeletonTruncatesAt40Chars() {
        let long = String(repeating: "a", count: 60)
        let skel = Service.skeleton(long)
        XCTAssertTrue(skel.hasSuffix("…"))
        XCTAssertEqual(skel.count, 41, "40 skeleton chars + the … suffix")
    }

    // MARK: - topUnparseable ordering + cap

    func testTopUnparseableOrderingAndCap() {
        // date type: build values whose skeletons group and count differently.
        // "aa" (x2 → skeleton "xx") appears 3×, "bbb" (→ "xxx") 2×, "1" (→ "9") 1×,
        // plus two more distinct skeletons so we exceed the cap of 3.
        let vals = ["aa", "aa", "aa", "bbb", "bbb", "1", "(x)", "[y]"]
        let health = Service.assess(column: "d", values: vals, type: .date)
        XCTAssertEqual(health.topUnparseable.count, 3, "capped at 3")
        XCTAssertEqual(health.topUnparseable[0].skeleton, "xx")
        XCTAssertEqual(health.topUnparseable[0].count, 3)
        XCTAssertEqual(health.topUnparseable[1].skeleton, "xxx")
        XCTAssertEqual(health.topUnparseable[1].count, 2)
        // The remaining count-1 skeletons tie; only one survives the top-3 cut.
        XCTAssertEqual(health.topUnparseable[2].count, 1)
    }

    // MARK: - coverageDrift

    func testCoverageDriftAcrossTwoDays() throws {
        let dir = try makeTempDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Older day: FileVault on both devices (100%), Gatekeeper on one (50%).
        try writeSnapshot(
            in: dir, name: "ea-results_20260601T080000.json",
            rows: [
                ("Mac1", "FileVault", "Encrypted"),
                ("Mac2", "FileVault", "Encrypted"),
                ("Mac1", "Gatekeeper", "Enabled"),
                ("Mac2", "Gatekeeper", ""),
            ]
        )
        // Newer day: FileVault drops to one device (50%); Gatekeeper is GONE;
        // a NEW "mSCP Failures" EA appears on both (present only in newer file).
        try writeSnapshot(
            in: dir, name: "ea-results_20260602T080000.json",
            rows: [
                ("Mac1", "FileVault", "Encrypted"),
                ("Mac2", "FileVault", ""),
                ("Mac1", "mSCP Failures", "3"),
                ("Mac2", "mSCP Failures", "5"),
            ]
        )

        let drift = Service.coverageDrift(dataDir: dir)
        let byName = Dictionary(uniqueKeysWithValues: drift.map { ($0.eaName, $0) })

        // FileVault: 100% → 50%, delta −50pp.
        let fv = try XCTUnwrap(byName["FileVault"])
        XCTAssertEqual(fv.previousPct, 100, accuracy: 0.001)
        XCTAssertEqual(fv.currentPct, 50, accuracy: 0.001)
        XCTAssertEqual(fv.deltaPP, -50, accuracy: 0.001)

        // Gatekeeper: present only in the older file → current 0%, delta −50pp.
        let gk = try XCTUnwrap(byName["Gatekeeper"])
        XCTAssertEqual(gk.previousPct, 50, accuracy: 0.001)
        XCTAssertEqual(gk.currentPct, 0, accuracy: 0.001)

        // mSCP Failures: absent in the older file → previous 0%, current 100%.
        let mscp = try XCTUnwrap(byName["mSCP Failures"])
        XCTAssertEqual(mscp.previousPct, 0, accuracy: 0.001)
        XCTAssertEqual(mscp.currentPct, 100, accuracy: 0.001)

        // Sorted ascending by deltaPP — biggest drops first.
        let deltas = drift.map { $0.deltaPP }
        XCTAssertEqual(deltas, deltas.sorted())
        XCTAssertEqual(try XCTUnwrap(drift.first).deltaPP, -50, accuracy: 0.001)
    }

    func testCoverageDriftFewerThanTwoDaysReturnsEmpty() throws {
        let dir = try makeTempDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two files, SAME calendar day → only one distinct day → [].
        try writeSnapshot(
            in: dir, name: "ea-results_20260601T080000.json",
            rows: [("Mac1", "FileVault", "Encrypted")]
        )
        try writeSnapshot(
            in: dir, name: "ea-results_20260601T200000.json",
            rows: [("Mac1", "FileVault", "Encrypted")]
        )

        XCTAssertEqual(Service.coverageDrift(dataDir: dir), [])
    }

    func testCoverageDriftMissingDirectoryReturnsEmpty() {
        let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertEqual(Service.coverageDrift(dataDir: dir), [])
    }

    // MARK: - fixtures

    private func makeTempDataDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ea-parse-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("ea-results", isDirectory: true),
            withIntermediateDirectories: true
        )
        return base
    }

    /// Write a bare `[EAResultRow]` array using the `device`/`ea_name`/`value` shape.
    private func writeSnapshot(
        in dataDir: URL,
        name: String,
        rows: [(device: String, ea: String, value: String)]
    ) throws {
        let objs = rows.map { row -> String in
            #"{"device":"\#(row.device)","ea_name":"\#(row.ea)","value":"\#(row.value)"}"#
        }
        let json = "[" + objs.joined(separator: ",") + "]"
        let url = dataDir
            .appendingPathComponent("ea-results", isDirectory: true)
            .appendingPathComponent(name)
        try json.data(using: .utf8)!.write(to: url)
    }
}
