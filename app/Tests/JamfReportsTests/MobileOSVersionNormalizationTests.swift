import XCTest
@testable import JamfReports

/// Mobile OS versions are counted through `OSVersionName`, so "17.5" and "17.5.0" are one
/// release and an unmeasured version is left out (mobile spec 2).
final class MobileOSVersionNormalizationTests: XCTestCase {
    func testOneReleaseSpelledTwoWaysIsOneRow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileOS-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let rows = ["17.5", "17.5.0", "17.5.0", "Unknown", "", "18.1"].enumerated().map {
            #"{"mobileDeviceId":"\#($0.offset)","deviceType":"iOS","general":{"osVersion":"\#($0.element)"}}"#
        }
        try ReportEngine.saveSnapshot(
            data: Data("[\(rows.joined(separator: ","))]".utf8),
            kind: MobileFleetService.deviceKind, dataDir: dir)
        let snapshot = MobileFleetService.load(dataDir: dir)
        XCTAssertEqual(snapshot.osDistribution.map(\.osVersion), ["17.5", "18.1"])
        XCTAssertEqual(snapshot.osDistribution.map(\.count), [3, 1])
    }
}
