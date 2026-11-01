import Foundation
import XCTest
@testable import JamfReports

/// The saved `mobile-devices-list` snapshot drops lost-mode text (phone number, location,
/// message, footnote): nothing reads it and the snapshot can sync to a shared folder.
final class MobileLostModeTextTests: XCTestCase {

    private var dataDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dataDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-LostMode-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
        try super.tearDownWithError()
    }

    func testCollectedMobileListIsSavedWithoutLostModeText() throws {
        let saved = try saveAndRead(kind: MobileFleetService.deviceKind, payload: Self.record)
        let record = try XCTUnwrap(saved.first)
        let security = try XCTUnwrap(record["security"] as? [String: Any])

        for key in ReportEngine.lostModeTextKeys {
            XCTAssertNil(security[key], key)
        }
        XCTAssertEqual(security["lostModeEnabled"] as? Bool, true)
        XCTAssertEqual(security["passcodeCompliant"] as? Bool, true)
        XCTAssertEqual((record["general"] as? [String: Any])?["udid"] as? String, "UDID-1")
    }

    /// Only the mobile list loses lost-mode text.
    func testOtherKindsKeepLostModeText() throws {
        let saved = try saveAndRead(kind: "computers", payload: Self.record)
        let security = try XCTUnwrap(saved.first?["security"] as? [String: Any])
        XCTAssertEqual(security["lostModeMessage"] as? String, "Call the help desk")
    }

    /// The computers snapshot keeps the PO date and no other purchasing detail.
    func testCollectedComputersKeepOnlyThePODate() throws {
        let saved = try saveAndRead(kind: "computers", payload: Self.purchasingRecord)
        let purchasing = try XCTUnwrap(saved.first?["purchasing"] as? [String: Any])
        XCTAssertEqual(purchasing as? [String: String], ["poDate": "2022-06-01"])
        XCTAssertEqual((saved.first?["general"] as? [String: Any])?["name"] as? String, "Mac-A")
    }

    func testPurchasingOnAnotherKindIsSavedAsPrinted() throws {
        let saved = try saveAndRead(kind: "policies", payload: Self.purchasingRecord)
        let purchasing = try XCTUnwrap(saved.first?["purchasing"] as? [String: Any])
        XCTAssertEqual(purchasing["purchasePrice"] as? String, "$500")
    }

    func testComputersWithNothingToRemoveKeepTheirBytes() {
        let null = Data(#"[{"id":"1","purchasing":null}]"#.utf8)
        XCTAssertEqual(ReportEngine.keepingOnlyPODate(null), null)
        let dateOnly = Data(#"[{"id":"1","purchasing":{"poDate":"2022-06-01"}}]"#.utf8)
        XCTAssertEqual(ReportEngine.keepingOnlyPODate(dateOnly), dateOnly)
    }

    func testAPayloadThatDoesNotParseIsNotSavedWithPurchasingDetails() throws {
        XCTAssertNil(ReportEngine.keepingOnlyPODate(Data("{".utf8)))
    }

    func testPayloadWithoutTheKeysKeepsItsBytes() {
        let data = Data(#"[{"security":{"lostModeEnabled":false}}]"#.utf8)
        XCTAssertEqual(ReportEngine.droppingLostModeText(data), data)
    }

    /// A payload the strip cannot parse is not saved: the previous snapshot stays newest.
    func testUnparseablePayloadIsNotSavedAndWarns() throws {
        XCTAssertNil(ReportEngine.droppingLostModeText(Data("5".utf8)))

        let kind = MobileFleetService.deviceKind
        let lines = LineBox()
        let result = try ReportEngine.saveCollectedPayload(
            kind: kind, data: Data("5".utf8),
            outcome: ReportEngine.CollectOutcome(kind: kind, exitCode: 0),
            isPartialFailure: false, dataDir: dataDir, recordManifest: false,
            stateStore: nil, collectStart: Date(), onLine: lines.append)

        XCTAssertFalse(result.saved)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent(kind).path), "nothing may reach disk")
        XCTAssertEqual(lines.texts.filter { $0.hasPrefix("[warn] \(kind)") }.count, 1)
    }

    func testAListThatCouldNotBeStrippedNeedsAttentionAndASavedOneClearsIt() throws {
        let kind = MobileFleetService.deviceKind
        func changes(_ payload: String) throws -> [AttentionCode: AttentionChange] {
            let log = AttentionLog(profile: "p", usesAppRecord: false)
            _ = try AttentionLog.$current.withValue(log) {
                try ReportEngine.saveCollectedPayload(
                    kind: kind, data: Data(payload.utf8),
                    outcome: ReportEngine.CollectOutcome(kind: kind, exitCode: 0),
                    isPartialFailure: false, dataDir: dataDir, recordManifest: false,
                    stateStore: nil, collectStart: Date(), onLine: { _ in })
            }
            return log.changes
        }
        XCTAssertEqual(try changes("5"), [.lostModeStripFailed: .raised(
            "Mobile device list not saved: lost-mode text not removed")])
        XCTAssertEqual(try changes(Self.record), [.lostModeStripFailed: .cleared])
    }

    // MARK: - Fixtures

    private static let record = #"""
        [{"id": "7",
          "general": {"udid": "UDID-1", "managed": true},
          "security": {"lostModeEnabled": true, "passcodeCompliant": true,
                       "lostModePhoneNumber": "555-0100", "lostModeLocation": "Building 4",
                       "lostModeMessage": "Call the help desk", "lostModeFootnote": "Reward"}}]
        """#

    private static let purchasingRecord = #"""
        [{"id": "1", "general": {"name": "Mac-A"},
          "purchasing": {"poDate": "2022-06-01", "poNumber": "53-1", "purchasePrice": "$500",
                         "vendor": "Example Vendor", "warrantyDate": "2025-06-01"}}]
        """#

    private func saveAndRead(kind: String, payload: String) throws -> [[String: Any]] {
        let data = Data(payload.utf8)
        let result = try ReportEngine.saveCollectedPayload(
            kind: kind, data: data,
            outcome: ReportEngine.CollectOutcome(kind: kind, exitCode: 0),
            isPartialFailure: false, dataDir: dataDir, recordManifest: false,
            stateStore: nil, collectStart: Date(), onLine: { _ in }
        )
        XCTAssertTrue(result.saved)
        let folder = dataDir.appendingPathComponent(kind, isDirectory: true)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        return try XCTUnwrap(object as? [[String: Any]])
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

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
