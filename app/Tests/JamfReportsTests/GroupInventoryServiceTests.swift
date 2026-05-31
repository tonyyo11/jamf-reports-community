import Foundation
import XCTest
@testable import JamfReports

/// Tests for `GroupInventoryService` — decode of both snapshot shapes,
/// aggregate computation, and empty-state behavior.
///
/// `GroupInventoryService` is a `Sendable` struct with `nonisolated static`
/// load methods. No `@MainActor` needed — matches `PatchStatusService` pattern.
final class GroupInventoryServiceTests: XCTestCase {

    // MARK: - Helpers

    private func writeTmp(_ content: String, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
        try Data(content.utf8).write(to: url)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - load — advanced mobile device searches

    func testLoadAdvancedSearchesDecodes() throws {
        let json = """
        {
          "totalCount": 2,
          "results": [
            {"id": "211", "name": "iPads No Passcode",
             "criteria": [], "displayFields": [], "siteId": "-1"},
            {"id": "212", "name": "iPhones Unmanaged",
             "criteria": [], "displayFields": [], "siteId": "-1"}
          ]
        }
        """
        let url = try writeTmp(json, name: "searches")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: url, computerGroupsURL: nil, mobileGroupsURL: nil)
        XCTAssertEqual(snap.advancedSearchCount, 2)
        XCTAssertEqual(snap.advancedMobileSearches[0].name, "iPads No Passcode")
        XCTAssertEqual(snap.advancedMobileSearches[1].id, "212")
        XCTAssertTrue(snap.isDetected)
    }

    /// A successfully-decoded empty envelope means collect ran — isDetected must be true
    /// even when results is empty. Distinguishes "never collected" from "collected, zero results".
    func testLoadAdvancedSearchesEmptyEnvelopeStillDetected() throws {
        let json = #"{"totalCount": 0, "results": []}"#
        let url = try writeTmp(json, name: "searches-empty")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: url, computerGroupsURL: nil, mobileGroupsURL: nil)
        XCTAssertEqual(snap.advancedSearchCount, 0)
        XCTAssertTrue(snap.isDetected)
    }

    // MARK: - load — classic computer groups

    func testLoadClassicComputerGroupsDecodes() throws {
        let json = """
        [
          {"id": 1, "is_smart": true,  "name": "Smart Mac Group"},
          {"id": 2, "is_smart": false, "name": "Static Lab Macs"},
          {"id": 3,                    "name": "No Flag Group"}
        ]
        """
        let url = try writeTmp(json, name: "computer-groups")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        XCTAssertEqual(snap.classicComputerGroupCount, 3)
        XCTAssertEqual(snap.classicComputerSmartGroupCount, 1)
        XCTAssertEqual(
            snap.classicComputerStaticGroupCount, 2,
            "missing is_smart must count as static")
        XCTAssertTrue(snap.isDetected)
    }

    /// A successfully-decoded empty array means collect ran — isDetected must be true.
    func testLoadClassicComputerGroupsEmptyArrayStillDetected() throws {
        let url = try writeTmp("[]", name: "computer-groups-empty")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        XCTAssertEqual(snap.classicComputerGroupCount, 0)
        XCTAssertTrue(snap.isDetected)
    }

    // MARK: - load — classic mobile device groups

    func testLoadClassicMobileGroupsDecodes() throws {
        let json = """
        [
          {"id": 10, "is_smart": true,  "name": "Smart All iPads"},
          {"id": 11, "is_smart": false, "name": "Static Kiosk iPads"}
        ]
        """
        let url = try writeTmp(json, name: "mobile-groups")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: nil, mobileGroupsURL: url)
        XCTAssertEqual(snap.classicMobileGroupCount, 2)
        XCTAssertEqual(snap.classicMobileSmartGroupCount, 1)
        XCTAssertEqual(snap.classicMobileStaticGroupCount, 1)
        XCTAssertTrue(snap.isDetected)
    }

    // MARK: - load — all three sources combined

    func testLoadAllThreeSourcesCombined() throws {
        let searchesJSON = """
        {"totalCount": 1, "results": [
          {"id": "100", "name": "Test Search",
           "criteria": [], "displayFields": [], "siteId": "-1"}
        ]}
        """
        let computerJSON = #"[{"id": 5, "is_smart": true, "name": "Smart Mac Group"}]"#
        let mobileJSON = #"[{"id": 6, "is_smart": false, "name": "Static iPad Group"}]"#

        let searchesURL = try writeTmp(searchesJSON, name: "searches-all")
        let computerURL = try writeTmp(computerJSON, name: "computer-all")
        let mobileURL = try writeTmp(mobileJSON, name: "mobile-all")
        defer {
            remove(searchesURL); remove(computerURL); remove(mobileURL)
        }

        let snap = GroupInventoryService.load(
            searchesURL: searchesURL,
            computerGroupsURL: computerURL,
            mobileGroupsURL: mobileURL
        )
        XCTAssertEqual(snap.advancedSearchCount, 1)
        XCTAssertEqual(snap.classicComputerGroupCount, 1)
        XCTAssertEqual(snap.classicMobileGroupCount, 1)
        XCTAssertTrue(snap.isDetected)
        XCTAssertNotNil(snap.sourceFile)
        XCTAssertNotNil(snap.snapshotDate)
    }

    // MARK: - load — nil URLs

    func testLoadAllNilURLsReturnsEmpty() {
        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: nil, mobileGroupsURL: nil)
        XCTAssertEqual(snap, .empty)
        XCTAssertFalse(snap.isDetected)
    }

    // MARK: - Snapshot.empty

    func testEmptySnapshotHasZeroCounts() {
        let empty = GroupInventoryService.Snapshot.empty
        XCTAssertEqual(empty.advancedSearchCount, 0)
        XCTAssertEqual(empty.classicComputerGroupCount, 0)
        XCTAssertEqual(empty.classicMobileGroupCount, 0)
        XCTAssertFalse(empty.isDetected)
        XCTAssertNil(empty.sourceFile)
        XCTAssertNil(empty.snapshotDate)
    }

    /// Snapshot decoded to all-empty arrays: isDetected=true (collect ran).
    /// Snapshot.empty (no files): isDetected=false (collect never ran).
    /// The two must be distinguishable so GroupsView shows the right empty state.
    func testDecodedEmptyArraysIsDetectedVsNeverCollected() throws {
        let allEmptyJSON = #"{"totalCount": 0, "results": []}"#
        let url = try writeTmp(allEmptyJSON, name: "detected-empty")
        defer { remove(url) }

        let decoded = GroupInventoryService.load(
            searchesURL: url, computerGroupsURL: nil, mobileGroupsURL: nil)
        XCTAssertTrue(decoded.isDetected, "decoded empty result must be detected")
        XCTAssertTrue(decoded.decodedAnySource)

        let neverCollected = GroupInventoryService.Snapshot.empty
        XCTAssertFalse(neverCollected.isDetected, ".empty must not be detected")
        XCTAssertFalse(neverCollected.decodedAnySource)
    }

    // MARK: - Equatable

    func testSnapshotEquality() throws {
        let json = #"[{"id": 1, "is_smart": true, "name": "Group A"}]"#
        let url = try writeTmp(json, name: "eq-test")
        defer { remove(url) }

        let snap1 = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        let snap2 = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        XCTAssertEqual(snap1, snap2)
    }

    // MARK: - cacheSource

    func testCacheSourceIsNeverFetchedWhenSnapshotDateNil() {
        let snap = GroupInventoryService.Snapshot.empty
        XCTAssertEqual(snap.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceIsFreshForRecentSnapshot() throws {
        let json = #"[{"id": 1, "is_smart": false, "name": "G"}]"#
        let url = try writeTmp(json, name: "fresh-test")
        defer { remove(url) }

        let snap = GroupInventoryService.load(
            searchesURL: nil, computerGroupsURL: url, mobileGroupsURL: nil)
        // File was just written — snapshotDate is within the 36-hour window.
        XCTAssertEqual(snap.cacheSource, .fresh)
    }
}
