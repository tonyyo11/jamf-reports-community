import XCTest
import SwiftUI
@testable import JamfReports

/// Tests for ExtensionAttributeService and ExtensionAttributesView. Validates
/// EA coverage calculation, value distribution aggregation (top-N + tail
/// bucket), and view instantiation in both demo and non-demo modes.
@MainActor
final class ExtensionAttributeServiceTests: XCTestCase {

    func testExtensionAttributesViewInstantiatesInDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = true

        _ = ExtensionAttributesView().environment(workspace)
    }

    func testExtensionAttributesViewInstantiatesOutsideDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = false

        _ = ExtensionAttributesView().environment(workspace)
    }

    // MARK: - Service decode parity

    /// Confirms EA results decode properly and coverage is calculated correctly.
    /// Tests with 5 devices and 3 EAs with mixed populated/empty values.
    func testServiceDecodesEAResultsAndCalculatesCoverage() throws {
        let resultsJSON = """
        [
          {"computer_id": "1", "computer_name": "Device-001", "serial": "C1", "ea_id": "10", "ea_name": "FileVault Status", "value": "Encrypted"},
          {"computer_id": "2", "computer_name": "Device-002", "serial": "C2", "ea_id": "10", "ea_name": "FileVault Status", "value": "Not Encrypted"},
          {"computer_id": "3", "computer_name": "Device-003", "serial": "C3", "ea_id": "10", "ea_name": "FileVault Status", "value": "Encrypted"},
          {"computer_id": "4", "computer_name": "Device-004", "serial": "C4", "ea_id": "10", "ea_name": "FileVault Status", "value": null},
          {"computer_id": "5", "computer_name": "Device-005", "serial": "C5", "ea_id": "10", "ea_name": "FileVault Status", "value": ""},
          {"computer_id": "1", "computer_name": "Device-001", "serial": "C1", "ea_id": "11", "ea_name": "Office Version", "value": "16.91"},
          {"computer_id": "2", "computer_name": "Device-002", "serial": "C2", "ea_id": "11", "ea_name": "Office Version", "value": "16.90"},
          {"computer_id": "3", "computer_name": "Device-003", "serial": "C3", "ea_id": "11", "ea_name": "Office Version", "value": null},
          {"computer_id": "1", "computer_name": "Device-001", "serial": "C1", "ea_id": "12", "ea_name": "Empty EA", "value": null},
          {"computer_id": "2", "computer_name": "Device-002", "serial": "C2", "ea_id": "12", "ea_name": "Empty EA", "value": ""},
          {"computer_id": "3", "computer_name": "Device-003", "serial": "C3", "ea_id": "12", "ea_name": "Empty EA", "value": null}
        ]
        """

        let definitionsJSON = """
        [
          {"id": "10", "name": "FileVault Status", "dataType": "STRING", "description": "FV status", "inputType": "SCRIPT", "enabled": true},
          {"id": "11", "name": "Office Version", "dataType": "STRING", "description": "Office version", "inputType": "SCRIPT", "enabled": true},
          {"id": "12", "name": "Empty EA", "dataType": "STRING", "description": "Test EA", "inputType": "SCRIPT", "enabled": false}
        ]
        """

        let resultsURL = writeTempFile(content: resultsJSON, suffix: "ea-results.json")
        let definitionsURL = writeTempFile(content: definitionsJSON, suffix: "ea-definitions.json")
        defer {
            try? FileManager.default.removeItem(at: resultsURL)
            try? FileManager.default.removeItem(at: definitionsURL)
        }

        let snapshot = try XCTUnwrap(
            ExtensionAttributeService.load(resultsURL: resultsURL, definitionsURL: definitionsURL)
        )

        XCTAssertEqual(snapshot.totalDevices, 5, "Should identify 5 unique devices")
        XCTAssertEqual(snapshot.totalEAs, 3, "Should identify 3 unique EAs")
        XCTAssertEqual(snapshot.totalRowCount, 11, "totalRowCount tracks the raw decoded row count")
        XCTAssertEqual(snapshot.definitions.count, 3, "Should load 3 definitions")

        let coverageByName = Dictionary(uniqueKeysWithValues:
            snapshot.coverage.map { ($0.eaName, ($0.populatedDevices, $0.totalDevices)) }
        )

        XCTAssertEqual(coverageByName["FileVault Status"]?.0, 3, "FileVault should have 3 populated devices")
        XCTAssertEqual(coverageByName["FileVault Status"]?.1, 5, "FileVault should have 5 total devices")
        XCTAssertEqual(coverageByName["Office Version"]?.0, 2, "Office should have 2 populated devices")
        XCTAssertEqual(coverageByName["Office Version"]?.1, 5, "Office should have 5 total devices")
        XCTAssertEqual(coverageByName["Empty EA"]?.0, 0, "Empty EA should have 0 populated devices")
        XCTAssertEqual(coverageByName["Empty EA"]?.1, 5, "Empty EA should have 5 total devices")

        // Coverage is sorted worst-first (lowest populated devices first)
        XCTAssertEqual(snapshot.coverage.first?.eaName, "Empty EA", "Empty EA should be first (worst coverage)")
        XCTAssertEqual(snapshot.coverage.last?.eaName, "FileVault Status", "FileVault should be last (best coverage)")
    }

    /// Prod ea-results carry only `{definition_id, device, ea_name, value}` — no
    /// computer_id/serial. Device counting must use the identity fallback chain,
    /// or the whole view renders "0 devices" (regression: prod 2026-07-02).
    func testCoverageCountsDevicesFromDeviceKeyOnlyRows() throws {
        let resultsJSON = """
        [
          {"definition_id": "10", "device": "mac-001", "ea_name": "FileVault Status", "value": "Encrypted"},
          {"definition_id": "10", "device": "mac-002", "ea_name": "FileVault Status", "value": "Not Encrypted"},
          {"definition_id": "10", "device": "mac-003", "ea_name": "FileVault Status", "value": null},
          {"definition_id": "11", "device": "mac-001", "ea_name": "Office Version", "value": "16.91"}
        ]
        """
        let resultsURL = writeTempFile(content: resultsJSON, suffix: "ea-results.json")
        defer { try? FileManager.default.removeItem(at: resultsURL) }

        let snapshot = try XCTUnwrap(
            ExtensionAttributeService.load(resultsURL: resultsURL, definitionsURL: nil)
        )

        XCTAssertEqual(snapshot.totalDevices, 3, "device-key rows must count into the universe")
        let coverageByName = Dictionary(uniqueKeysWithValues:
            snapshot.coverage.map { ($0.eaName, ($0.populatedDevices, $0.totalDevices)) }
        )
        XCTAssertEqual(coverageByName["FileVault Status"]?.0, 2)
        XCTAssertEqual(coverageByName["FileVault Status"]?.1, 3)
        XCTAssertEqual(coverageByName["Office Version"]?.0, 1)
    }

    /// Tests that when definitions exist but no results are loaded, totalEAs
    /// comes from definitions count.
    func testDefinitionsOnlySnapshot() throws {
        let definitionsJSON = """
        [
          {"id": "10", "name": "Test EA 1", "dataType": "STRING", "description": "Test", "inputType": "SCRIPT", "enabled": true},
          {"id": "11", "name": "Test EA 2", "dataType": "BOOLEAN", "description": "Test", "inputType": "SCRIPT", "enabled": true}
        ]
        """

        let definitionsURL = writeTempFile(content: definitionsJSON, suffix: "ea-definitions.json")
        defer { try? FileManager.default.removeItem(at: definitionsURL) }

        let snapshot = try XCTUnwrap(
            ExtensionAttributeService.load(resultsURL: nil, definitionsURL: definitionsURL)
        )

        XCTAssertEqual(snapshot.totalDevices, 0, "No results, so no devices")
        XCTAssertEqual(snapshot.totalEAs, 2, "Should count from definitions")
        XCTAssertEqual(snapshot.totalRowCount, 0, "No results means zero rows")
        XCTAssertEqual(snapshot.definitions.count, 2)
        XCTAssertTrue(snapshot.coverage.isEmpty, "No results, so no coverage")
        XCTAssertTrue(snapshot.valueDistributions.isEmpty, "No results, so no distributions")
    }

    /// Tests value distribution with case normalization and grouping.
    /// Same EA with values ["YES", "yes", "Yes", "NO"] should group into
    /// 2 distinct values ("yes"=3, "no"=1) due to lowercase+trim.
    func testValueDistributionGroupsByNormalizedValues() throws {
        let resultsJSON = """
        [
          {"computer_id": "1", "computer_name": "Device-001", "serial": "C1", "ea_id": "10", "ea_name": "Test Boolean", "value": "YES"},
          {"computer_id": "2", "computer_name": "Device-002", "serial": "C2", "ea_id": "10", "ea_name": "Test Boolean", "value": "yes"},
          {"computer_id": "3", "computer_name": "Device-003", "serial": "C3", "ea_id": "10", "ea_name": "Test Boolean", "value": "Yes"},
          {"computer_id": "4", "computer_name": "Device-004", "serial": "C4", "ea_id": "10", "ea_name": "Test Boolean", "value": "NO"}
        ]
        """

        let resultsURL = writeTempFile(content: resultsJSON, suffix: "ea-results.json")
        defer { try? FileManager.default.removeItem(at: resultsURL) }

        let snapshot = try XCTUnwrap(
            ExtensionAttributeService.load(resultsURL: resultsURL, definitionsURL: nil)
        )

        XCTAssertEqual(snapshot.valueDistributions.count, 1)
        let distribution = try XCTUnwrap(snapshot.valueDistributions.first)
        XCTAssertEqual(distribution.eaName, "Test Boolean")

        let valuesByCount = Dictionary(uniqueKeysWithValues:
            distribution.top.map { ($0.value, $0.count) }
        )

        XCTAssertEqual(valuesByCount["yes"], 3, "YES/yes/Yes should normalize to 'yes' with count 3")
        XCTAssertEqual(valuesByCount["no"], 1, "NO should normalize to 'no' with count 1")
        XCTAssertEqual(distribution.top.count, 2, "Should have exactly 2 distinct values")
        XCTAssertEqual(distribution.otherCount, 0, "Two values fit under topValueLimit; no tail bucket")
        XCTAssertEqual(distribution.distinctValueCount, 2)

        // Values are sorted by count DESC (yes=3, no=1)
        XCTAssertEqual(distribution.top.first?.value, "yes")
        XCTAssertEqual(distribution.top.first?.count, 3)
    }

    /// Tests that empty/null values are excluded from populated count and
    /// value distributions.
    func testEmptyValuesExcludedFromPopulatedCount() throws {
        let resultsJSON = """
        [
          {"computer_id": "1", "computer_name": "Device-001", "serial": "C1", "ea_id": "10", "ea_name": "Mixed EA", "value": "Valid"},
          {"computer_id": "2", "computer_name": "Device-002", "serial": "C2", "ea_id": "10", "ea_name": "Mixed EA", "value": null},
          {"computer_id": "3", "computer_name": "Device-003", "serial": "C3", "ea_id": "10", "ea_name": "Mixed EA", "value": ""},
          {"computer_id": "4", "computer_name": "Device-004", "serial": "C4", "ea_id": "10", "ea_name": "Mixed EA", "value": "null"},
          {"computer_id": "5", "computer_name": "Device-005", "serial": "C5", "ea_id": "10", "ea_name": "Mixed EA", "value": "Valid2"}
        ]
        """

        let resultsURL = writeTempFile(content: resultsJSON, suffix: "ea-results.json")
        defer { try? FileManager.default.removeItem(at: resultsURL) }

        let snapshot = try XCTUnwrap(
            ExtensionAttributeService.load(resultsURL: resultsURL, definitionsURL: nil)
        )

        XCTAssertEqual(snapshot.totalDevices, 5)
        let coverage = try XCTUnwrap(snapshot.coverage.first)
        XCTAssertEqual(coverage.eaName, "Mixed EA")
        XCTAssertEqual(coverage.populatedDevices, 2, "Only 'Valid' and 'Valid2' should count as populated")
        XCTAssertEqual(coverage.totalDevices, 5)

        // Value distribution only includes the 2 valid values
        let distribution = try XCTUnwrap(snapshot.valueDistributions.first)
        XCTAssertEqual(distribution.top.count, 2)
        XCTAssertEqual(distribution.otherCount, 0)

        let values = Set(distribution.top.map { $0.value })
        XCTAssertTrue(values.contains("valid"))
        XCTAssertTrue(values.contains("valid2"))
        XCTAssertFalse(values.contains("null"))
        XCTAssertFalse(values.contains(""))
    }

    /// Tests that empty input returns .empty without crash.
    func testEmptyInputReturnsEmpty() throws {
        let snapshot = ExtensionAttributeService.load(resultsURL: nil, definitionsURL: nil)
        XCTAssertNil(snapshot, "Empty input should return nil")

        let emptyResultsURL = writeTempFile(content: "[]", suffix: "empty-results.json")
        let emptyDefinitionsURL = writeTempFile(content: "[]", suffix: "empty-definitions.json")
        defer {
            try? FileManager.default.removeItem(at: emptyResultsURL)
            try? FileManager.default.removeItem(at: emptyDefinitionsURL)
        }

        let emptySnapshot = try XCTUnwrap(
            ExtensionAttributeService.load(resultsURL: emptyResultsURL, definitionsURL: emptyDefinitionsURL)
        )
        XCTAssertEqual(
            emptySnapshot,
            .empty.with(
                sourceFile: emptySnapshot.sourceFile,
                snapshotDate: emptySnapshot.snapshotDate,
                sourceDates: emptySnapshot.sourceDates
            ),
            "Empty arrays preserve the .empty contract (file-derived metadata carries over)"
        )
        XCTAssertEqual(Set(emptySnapshot.sourceDates.keys),
                       ["ea-results", "computer-extension-attributes"],
                       "on-disk files report freshness dates even with empty content")
        XCTAssertEqual(emptySnapshot.totalDevices, 0)
        XCTAssertEqual(emptySnapshot.totalEAs, 0)
        XCTAssertEqual(emptySnapshot.totalRowCount, 0)
        XCTAssertTrue(emptySnapshot.coverage.isEmpty)
        XCTAssertTrue(emptySnapshot.definitions.isEmpty)
        XCTAssertTrue(emptySnapshot.valueDistributions.isEmpty)
    }

    // MARK: - Top-N + tail bucket aggregation

    /// Synthesizes a 1,000-row fixture with one EA having 30 distinct values
    /// across mixed counts. Asserts:
    ///   1. `top` is capped at `ExtensionAttributeService.topValueLimit` (20)
    ///   2. `top` is sorted strictly descending by count
    ///   3. `otherCount` equals the sum of counts for excluded values
    ///   4. `distinctValueCount` equals the total distinct values
    ///   5. `totalRowCount` matches the input size
    func testTopValuesCappedWithTailBucket() throws {
        // 30 distinct values with descending counts: value-00=30, value-01=29, ..., value-29=1
        // Total rows = 30+29+...+1 = 465. We pad with another EA's rows so totalRowCount=1000.
        var rowsJSON: [String] = []
        var globalDeviceCounter = 1

        for valueIdx in 0..<30 {
            let count = 30 - valueIdx
            for _ in 0..<count {
                let deviceID = globalDeviceCounter
                globalDeviceCounter += 1
                let json = """
                {"computer_id": "\(deviceID)", "computer_name": "D\(deviceID)", "serial": "S\(deviceID)", "ea_id": "100", "ea_name": "Big EA", "value": "value-\(String(format: "%02d", valueIdx))"}
                """
                rowsJSON.append(json)
            }
        }
        // 465 rows so far; pad with a second EA up to 1000 rows
        let primaryRowCount = rowsJSON.count
        let padRowCount = 1000 - primaryRowCount
        for i in 0..<padRowCount {
            let deviceID = 10_000 + i
            let json = """
            {"computer_id": "\(deviceID)", "computer_name": "P\(deviceID)", "serial": "PS\(deviceID)", "ea_id": "200", "ea_name": "Padding EA", "value": "pad-\(i % 5)"}
            """
            rowsJSON.append(json)
        }

        let resultsJSON = "[" + rowsJSON.joined(separator: ",\n") + "]"
        let resultsURL = writeTempFile(content: resultsJSON, suffix: "1000row-results.json")
        defer { try? FileManager.default.removeItem(at: resultsURL) }

        let snapshot = try XCTUnwrap(
            ExtensionAttributeService.load(resultsURL: resultsURL, definitionsURL: nil)
        )

        XCTAssertEqual(snapshot.totalRowCount, 1000, "Should round-trip the 1000-row input size")

        let bigEA = try XCTUnwrap(
            snapshot.valueDistributions.first(where: { $0.eaName == "Big EA" })
        )

        // 1. Cap honored
        XCTAssertEqual(bigEA.top.count, ExtensionAttributeService.topValueLimit,
                       "top must be capped at topValueLimit (\(ExtensionAttributeService.topValueLimit))")

        // 2. Sort order strictly descending by count
        let counts = bigEA.top.map(\.count)
        XCTAssertEqual(counts, counts.sorted(by: >),
                       "top must be sorted descending by count")

        // 3. distinctValueCount equals all 30 distinct values
        XCTAssertEqual(bigEA.distinctValueCount, 30,
                       "distinctValueCount tracks pre-trim distinct count")

        // 4. otherCount equals sum of counts for values 20..29 → 10+9+...+1 = 55
        let expectedOther = (1...10).reduce(0, +)
        XCTAssertEqual(bigEA.otherCount, expectedOther,
                       "otherCount must equal sum of counts beyond topValueLimit")

        // 5. Sum invariant: top counts + otherCount = total populated values (= 465 for Big EA)
        let topSum = bigEA.top.reduce(0) { $0 + $1.count }
        XCTAssertEqual(topSum + bigEA.otherCount, 465,
                       "top + otherCount must equal total populated rows for this EA")

        // 6. The single highest-count value should be value-00 with count 30
        XCTAssertEqual(bigEA.top.first?.value, "value-00")
        XCTAssertEqual(bigEA.top.first?.count, 30)
    }

    /// Confirms all EAs get a distribution (not just the top-10 covered ones).
    /// This fixes a previous selection dead-end where picking a low-coverage
    /// EA in the view rendered nothing.
    func testEveryEAGetsAValueDistribution() throws {
        let resultsJSON = """
        [
          {"computer_id": "1", "computer_name": "D1", "serial": "S1", "ea_id": "10", "ea_name": "EA-A", "value": "alpha"},
          {"computer_id": "2", "computer_name": "D2", "serial": "S2", "ea_id": "11", "ea_name": "EA-B", "value": "beta"},
          {"computer_id": "3", "computer_name": "D3", "serial": "S3", "ea_id": "12", "ea_name": "EA-C", "value": "gamma"},
          {"computer_id": "4", "computer_name": "D4", "serial": "S4", "ea_id": "13", "ea_name": "EA-D", "value": "delta"}
        ]
        """
        let resultsURL = writeTempFile(content: resultsJSON, suffix: "every-ea.json")
        defer { try? FileManager.default.removeItem(at: resultsURL) }

        let snapshot = try XCTUnwrap(
            ExtensionAttributeService.load(resultsURL: resultsURL, definitionsURL: nil)
        )
        XCTAssertEqual(snapshot.valueDistributions.count, 4,
                       "Every EA with populated values must have a distribution entry")
    }

    // MARK: - CacheSource tests

    func testCacheSourceNil() throws {
        let snapshot = ExtensionAttributeService.Snapshot.empty
        XCTAssertEqual(snapshot.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceFresh() throws {
        let freshDate = Date().addingTimeInterval(-1800) // 30 minutes ago
        let snapshot = ExtensionAttributeService.Snapshot(
            definitions: [],
            coverage: [],
            totalDevices: 0,
            totalEAs: 0,
            totalRowCount: 0,
            valueDistributions: [],
            sourceFile: nil,
            snapshotDate: freshDate
        )
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceStale() throws {
        let staleDate = Date().addingTimeInterval(-2 * 24 * 3600) // 2 days ago
        let snapshot = ExtensionAttributeService.Snapshot(
            definitions: [],
            coverage: [],
            totalDevices: 0,
            totalEAs: 0,
            totalRowCount: 0,
            valueDistributions: [],
            sourceFile: nil,
            snapshotDate: staleDate
        )
        XCTAssertEqual(snapshot.cacheSource, .stale(at: staleDate))
    }

    // MARK: - sourceDates (freshness chip row)

    func testSourceDatesPopulatedForBothKinds() throws {
        let resultsJSON = """
        [{"computer_id": "1", "computer_name": "D1", "serial": "S1", "ea_id": "10", "ea_name": "EA-A", "value": "alpha"}]
        """
        let definitionsJSON = "[]"
        let resultsURL = writeTempFile(content: resultsJSON, suffix: "sourcedates-results.json")
        let definitionsURL = writeTempFile(content: definitionsJSON, suffix: "sourcedates-defs.json")
        defer {
            try? FileManager.default.removeItem(at: resultsURL)
            try? FileManager.default.removeItem(at: definitionsURL)
        }

        let snapshot = try XCTUnwrap(
            ExtensionAttributeService.load(resultsURL: resultsURL, definitionsURL: definitionsURL)
        )

        XCTAssertNotNil(snapshot.sourceDates["ea-results"])
        XCTAssertNotNil(snapshot.sourceDates["computer-extension-attributes"])
    }

    func testSourceDatesEmptyWhenDataDirMissing() {
        let snapshot = ExtensionAttributeService.load(profile: "no-such-profile-\(UUID().uuidString)")
        XCTAssertTrue(snapshot.sourceDates.isEmpty)
    }

    // MARK: - Test utilities

    private func writeTempFile(content: String, suffix: String) -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ea-test-\(UUID().uuidString)-\(suffix)")
        do {
            try Data(content.utf8).write(to: tmp)
        } catch {
            XCTFail("Could not write temp fixture: \(error)")
        }
        return tmp
    }
}

// MARK: - Snapshot test helpers

private extension ExtensionAttributeService.Snapshot {
    /// Returns a copy of `.empty` with the file-derived metadata swapped in
    /// (`sourceFile` / `snapshotDate` / `sourceDates`). Used by
    /// `testEmptyInputReturnsEmpty` to compare the structural empty contract:
    /// files that EXIST on disk still report their freshness dates even when
    /// their content is empty — that's what the "never" chip keys off.
    func with(
        sourceFile: URL?, snapshotDate: Date?, sourceDates: [String: Date] = [:]
    ) -> ExtensionAttributeService.Snapshot {
        ExtensionAttributeService.Snapshot(
            definitions: definitions,
            coverage: coverage,
            totalDevices: totalDevices,
            totalEAs: totalEAs,
            totalRowCount: totalRowCount,
            valueDistributions: valueDistributions,
            sourceFile: sourceFile,
            snapshotDate: snapshotDate,
            sourceDates: sourceDates
        )
    }
}
