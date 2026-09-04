import XCTest
@testable import JamfReports

/// What a scheduled run reports about config health.
///
/// The point of this signal: a run collects happily against broken column
/// mappings, exits 0, and Run History shows a clean run — so the config rots
/// invisibly. These pin what does and does not reach the log.
final class ScheduledRunConfigHealthTests: XCTestCase {

    private func report(_ rows: [DoctorRow]) -> DoctorReport { DoctorReport(rows: rows) }

    private func row(_ severity: DoctorSeverity, id: String, hint: String? = nil) -> DoctorRow {
        DoctorRow(
            id: id, severity: severity, title: "Title \(id)",
            detail: "Detail \(id)", hint: hint
        )
    }

    func testCleanConfigReportsNothing() {
        let count = ScheduledRunSignals.recordConfigHealth(
            profile: "p", recorder: nil,
            report: report([row(.pass, id: "a"), row(.pass, id: "b")])
        )
        XCTAssertEqual(count, 0)
    }

    /// Warnings deliberately stay out. Surfacing them here would make almost
    /// every run look broken, which is how an operator learns to ignore the
    /// signal entirely.
    func testWarningsAndSuggestionsAreNotReported() {
        let count = ScheduledRunSignals.recordConfigHealth(
            profile: "p", recorder: nil,
            report: report([
                row(.warn, id: "w1"), row(.warn, id: "w2"), row(.suggest, id: "s1"),
            ])
        )
        XCTAssertEqual(count, 0, "only genuine failures belong in a run log")
    }

    func testFailuresAreCounted() {
        let count = ScheduledRunSignals.recordConfigHealth(
            profile: "p", recorder: nil,
            report: report([
                row(.fail, id: "f1", hint: "fix me"),
                row(.warn, id: "w1"),
                row(.fail, id: "f2"),
            ])
        )
        XCTAssertEqual(count, 2)
    }
}
