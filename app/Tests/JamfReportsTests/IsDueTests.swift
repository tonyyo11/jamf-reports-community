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
        // One second short of the cadence less its one-hour tolerance.
        let lastRun = referenceNow.addingTimeInterval(-Double(oneDay - 3_600 - 1))
        XCTAssertFalse(
            CadenceResolver.isDue(
                lastRun: lastRun,
                cadence: .seconds(oneDay),
                now: referenceNow
            ),
            "Report fetched 1 s before cadence less tolerance must not be due"
        )
    }

    func testAnHourEarlyIsDue() {
        let lastRun = referenceNow.addingTimeInterval(-Double(oneDay - 3_600))
        XCTAssertTrue(
            CadenceResolver.isDue(
                lastRun: lastRun,
                cadence: .seconds(oneDay),
                now: referenceNow
            ),
            "Report fetched cadence less the one-hour tolerance ago must be due"
        )
    }

    // MARK: - Tolerance (#207 G1)

    /// A weekly scan stamped at 07:00:30 last week, with this week's tick waking
    /// at 07:00:10, is 20 s short of the cadence. Without a tolerance it read
    /// "not due" and the scan waited another week.
    func testWeeklyScanStartingEarlierThanLastWeekIsDue() {
        let lastRun = referenceNow.addingTimeInterval(-Double(604_800 - 20))
        XCTAssertTrue(
            CadenceResolver.isDue(lastRun: lastRun, cadence: .seconds(604_800), now: referenceNow)
        )
    }

    /// The 48-hour inventory tier on a daily schedule: two seconds short on
    /// the second day used to push it to the third.
    func testInventoryTierOnADailyScheduleIsDueOnTheSecondDay() {
        let lastRun = referenceNow.addingTimeInterval(-Double(172_800 - 2))
        XCTAssertTrue(
            CadenceResolver.isDue(lastRun: lastRun, cadence: .seconds(172_800), now: referenceNow)
        )
    }

    /// A day into the weekly cadence is still not due: the tolerance is an
    /// hour, not a fraction of the week.
    func testToleranceIsAnHourForTheShippingTiers() {
        XCTAssertEqual(CadenceResolver.dueTolerance(for: 43_200), 3_600)
        XCTAssertEqual(CadenceResolver.dueTolerance(for: 172_800), 3_600)
        XCTAssertEqual(CadenceResolver.dueTolerance(for: 604_800), 3_600)
        let dayEarly = referenceNow.addingTimeInterval(-Double(604_800 - oneDay))
        XCTAssertFalse(
            CadenceResolver.isDue(lastRun: dayEarly, cadence: .seconds(604_800), now: referenceNow)
        )
    }

    /// A short cadence gets a tenth of its interval, so it is never due at once.
    func testToleranceIsATenthOfAShortInterval() {
        XCTAssertEqual(CadenceResolver.dueTolerance(for: 60), 6)
        let cadence = Cadence.seconds(60)
        XCTAssertFalse(CadenceResolver.isDue(
            lastRun: referenceNow.addingTimeInterval(-53), cadence: cadence, now: referenceNow
        ))
        XCTAssertTrue(CadenceResolver.isDue(
            lastRun: referenceNow.addingTimeInterval(-54), cadence: cadence, now: referenceNow
        ))
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
