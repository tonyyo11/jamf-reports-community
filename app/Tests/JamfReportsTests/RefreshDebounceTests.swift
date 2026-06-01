import XCTest
@testable import JamfReports

final class RefreshDebounceTests: XCTestCase {

    // MARK: - First call always fires

    func testFirstCallFires() {
        var debouncer = RefreshDebouncer(interval: 2.0)
        let t0 = Date()
        XCTAssertTrue(debouncer.shouldFire(now: t0))
    }

    func testFirstCallSetsLastFired() {
        var debouncer = RefreshDebouncer(interval: 2.0)
        let t0 = Date()
        _ = debouncer.shouldFire(now: t0)
        XCTAssertEqual(debouncer.lastFired, t0)
    }

    // MARK: - Second call within interval is suppressed

    func testCallWithinIntervalDoesNotFire() {
        var debouncer = RefreshDebouncer(interval: 2.0)
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1.9)
        _ = debouncer.shouldFire(now: t0)
        XCTAssertFalse(debouncer.shouldFire(now: t1))
    }

    func testCallWithinIntervalDoesNotUpdateLastFired() {
        var debouncer = RefreshDebouncer(interval: 2.0)
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1.9)
        _ = debouncer.shouldFire(now: t0)
        _ = debouncer.shouldFire(now: t1)
        XCTAssertEqual(debouncer.lastFired, t0)
    }

    // MARK: - Call at exactly the interval boundary fires

    func testCallAtExactIntervalFires() {
        var debouncer = RefreshDebouncer(interval: 2.0)
        let t0 = Date()
        let t1 = t0.addingTimeInterval(2.0)
        _ = debouncer.shouldFire(now: t0)
        XCTAssertTrue(debouncer.shouldFire(now: t1))
    }

    // MARK: - Call after interval fires and advances lastFired

    func testCallAfterIntervalFires() {
        var debouncer = RefreshDebouncer(interval: 2.0)
        let t0 = Date()
        let t2 = t0.addingTimeInterval(2.5)
        _ = debouncer.shouldFire(now: t0)
        XCTAssertTrue(debouncer.shouldFire(now: t2))
    }

    func testCallAfterIntervalAdvancesLastFired() {
        var debouncer = RefreshDebouncer(interval: 2.0)
        let t0 = Date()
        let t2 = t0.addingTimeInterval(2.5)
        _ = debouncer.shouldFire(now: t0)
        _ = debouncer.shouldFire(now: t2)
        XCTAssertEqual(debouncer.lastFired, t2)
    }

    // MARK: - Injectable now is used for determinism (no wall-clock dependency)

    func testInjectableNowIsDeterministic() {
        var debouncer = RefreshDebouncer(interval: 2.0)
        let fixed = Date(timeIntervalSince1970: 0)
        // Two calls with the same injected timestamp — the second must be within the interval.
        _ = debouncer.shouldFire(now: fixed)
        XCTAssertFalse(debouncer.shouldFire(now: fixed))
    }

    // MARK: - Initial state has no lastFired

    func testInitialLastFiredIsNil() {
        let debouncer = RefreshDebouncer(interval: 2.0)
        XCTAssertNil(debouncer.lastFired)
    }
}
