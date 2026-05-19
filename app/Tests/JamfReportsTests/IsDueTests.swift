import XCTest
@testable import JamfReports

/// PR-22 T-4: `isDue` is the core scheduling decision — given the
/// last successful fetch timestamp, a cadence, and a clock, return
/// whether to fetch now. All edge cases pinned here.
final class IsDueTests: XCTestCase {

    private let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)
    private let oneDay: Int = 86_400

    // MARK: - Never-fetched

    func testNeverFetchedIsAlwaysDue() {
        XCTAssertTrue(
            CadenceResolver.isDue(
                lastRun: nil,
                cadence: .seconds(oneDay),
                now: referenceNow
            ),
            "A report that has never been fetched must always be due"
        )
    }

    func testNeverFetchedIsDueEvenForNeverCadence() {
        // If cadence is .never, the report is never due — the .never
        // takes precedence over the "never fetched" condition.
        XCTAssertFalse(
            CadenceResolver.isDue(
                lastRun: nil,
                cadence: .never,
                now: referenceNow
            ),
            "Even a never-fetched report is not due when cadence == .never"
        )
    }

    // MARK: - Cadence math

    func testFreshIsNotDue() {
        let lastRun = referenceNow.addingTimeInterval(-Double(oneDay - 1))
        XCTAssertFalse(
            CadenceResolver.isDue(
                lastRun: lastRun,
                cadence: .seconds(oneDay),
                now: referenceNow
            ),
            "Report fetched 1 s before cadence elapsed must not be due"
        )
    }

    func testExactlyDue() {
        let lastRun = referenceNow.addingTimeInterval(-Double(oneDay))
        XCTAssertTrue(
            CadenceResolver.isDue(
                lastRun: lastRun,
                cadence: .seconds(oneDay),
                now: referenceNow
            ),
            "Report fetched exactly cadence ago must be due (elapsed >= cadence)"
        )
    }

    func testOverdue() {
        let lastRun = referenceNow.addingTimeInterval(-Double(oneDay * 3))
        XCTAssertTrue(
            CadenceResolver.isDue(
                lastRun: lastRun,
                cadence: .seconds(oneDay),
                now: referenceNow
            ),
            "Report fetched 3 days ago at daily cadence must be due"
        )
    }

    // MARK: - Never cadence

    func testNeverCadenceMeansNeverDue() {
        // Vary lastRun across "ancient", "just now", "future" and assert
        // .never always returns false.
        let cases: [Date?] = [
            nil,
            referenceNow.addingTimeInterval(-Double(oneDay * 365)),
            referenceNow,
            referenceNow.addingTimeInterval(Double(oneDay)),  // hypothetical future
        ]
        for lastRun in cases {
            XCTAssertFalse(
                CadenceResolver.isDue(
                    lastRun: lastRun,
                    cadence: .never,
                    now: referenceNow
                ),
                "cadence: .never must always return false (lastRun: \(String(describing: lastRun)))"
            )
        }
    }

    // MARK: - Clock injection

    /// `now` is injectable so tests don't depend on real time. Production
    /// callers omit the parameter and get `Date()`.
    func testDefaultClockIsCurrentTime() {
        // Indirect: a fetched-just-now report should not be due at the
        // default clock.
        let cadence = Cadence.seconds(oneDay)
        let recent = Date().addingTimeInterval(-60)  // 1 minute ago
        XCTAssertFalse(
            CadenceResolver.isDue(lastRun: recent, cadence: cadence),
            "Default clock should be current time; 1-min-old fetch must not be due at daily cadence"
        )
    }

    // MARK: - Cadence equality

    /// `Cadence` is Hashable so it can live in `[String: Cadence]`
    /// per-report tables.
    func testCadenceHashableContract() {
        let a: Cadence = .seconds(3600)
        let b: Cadence = .seconds(3600)
        let c: Cadence = .seconds(7200)
        let n: Cadence = .never

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, n)

        var seen: Set<Cadence> = []
        seen.insert(a)
        seen.insert(b)
        seen.insert(c)
        seen.insert(n)
        XCTAssertEqual(seen.count, 3, "{a, b} dedupe; c and n are distinct")
    }
}
