import Darwin
import XCTest
@testable import JamfReports

/// Peak memory the change counts add to a collect, on a large synthetic workspace. Runs only
/// with `JRC_B2_MEMORY_DATA_DIR` set to a data folder holding `computers` snapshots of two days.
final class FleetChangeMemoryTests: XCTestCase {

    private func peakMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576  // bytes on macOS
    }

    func testPeakMemoryOfTheChangeCounts() throws {
        guard let path = ProcessInfo.processInfo.environment["JRC_B2_MEMORY_DATA_DIR"] else {
            throw XCTSkip("set JRC_B2_MEMORY_DATA_DIR to measure")
        }
        let dataDir = URL(fileURLWithPath: path, isDirectory: true)
        let newest = try XCTUnwrap(TrendStore.datedSnapshots(of: "computers", in: dataDir).last)
        let payload = try Data(contentsOf: newest.url)
        let before = peakMB()
        let snapshot = try XCTUnwrap(ComputerDates.decodeComputerSnapshot(payload))
        let afterLanded = peakMB()
        let changes = ReportEngine.computerChanges(
            landed: .init(stamp: "x", date: newest.date, snapshot: snapshot),
            dataDir: dataDir, rule: StaleRule(days: 30), policy: SecurityControlPolicy())
        let afterBaseline = peakMB()
        print(String(format: "B2 memory: payload %.0f MB, %d Macs; peak %.0f MB before, "
                     + "%.0f MB after the landed decode, %.0f MB after the baseline; joined %@",
                     Double(payload.count) / 1_048_576, snapshot.rows.count, before,
                     afterLanded, afterBaseline, "\(changes?.joined.map(String.init) ?? "nil")"))
    }
}
