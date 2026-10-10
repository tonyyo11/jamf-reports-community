import XCTest
@testable import JamfReports

@MainActor
final class SettingsTokenProbeTests: XCTestCase {

    @MainActor
    private final class Log {
        var probed: [String] = []
        var recorded: [String] = []
        /// What Settings renders as "checking…".
        var checking: Set<String> = []

        func setChecking(_ name: String, _ on: Bool) {
            if on { checking.insert(name) } else { checking.remove(name) }
        }
    }

    private static func status(_ name: String) -> TokenStatus {
        TokenStatus.make(profile: name, token: "token", expiresAt: nil)
    }

    func testProbesEveryProfileAndRecordsNonNilStatuses() async {
        let log = Log()
        await SettingsView.probeTokenStatuses(
            for: ["a", "b", "c"],
            probe: { name in
                log.probed.append(name)
                return name == "b" ? nil : Self.status(name)
            },
            setChecking: log.setChecking,
            onStatus: { name, _ in log.recorded.append(name) }
        )
        XCTAssertEqual(log.probed, ["a", "b", "c"])
        XCTAssertEqual(log.recorded, ["a", "c"])
    }

    /// Leaving Settings mid-probe: nothing further runs, and the cut-short result is not kept.
    func testCancellationDuringAProbeStopsTheLoopAndDropsThatResult() async {
        let log = Log()
        let task = Task { @MainActor in
            await SettingsView.probeTokenStatuses(
                for: ["a", "b", "c"],
                probe: { name in
                    log.probed.append(name)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return Self.status(name)
                },
                setChecking: log.setChecking,
                onStatus: { name, _ in log.recorded.append(name) }
            )
        }
        await task.value
        XCTAssertEqual(log.probed, ["a"])
        XCTAssertEqual(log.recorded, [])
    }

    func testAlreadyCancelledTaskProbesNothing() async {
        let log = Log()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await SettingsView.probeTokenStatuses(
                for: ["a", "b"],
                probe: { name in
                    log.probed.append(name)
                    return Self.status(name)
                },
                setChecking: log.setChecking,
                onStatus: { name, _ in log.recorded.append(name) }
            )
        }
        await task.value
        XCTAssertEqual(log.probed, [])
        XCTAssertEqual(log.recorded, [])
    }

    func testCheckingFlagIsSetWhileProbingAndClearedAfterwards() async {
        let log = Log()
        var seenDuringProbe: [Bool] = []
        await SettingsView.probeTokenStatuses(
            for: ["a", "b"],
            probe: { name in
                seenDuringProbe.append(log.checking == [name])
                return Self.status(name)
            },
            setChecking: log.setChecking,
            onStatus: { _, _ in }
        )
        XCTAssertEqual(seenDuringProbe, [true, true])
        XCTAssertEqual(log.checking, [])
    }

    /// A profile switch cancels this task and starts another that probes the same profile.
    /// The cancelled run finishing late must not clear the new run's "checking…" flag.
    func testCancelledProbeLeavesTheReplacementsCheckingFlagAlone() async {
        let log = Log()
        let task = Task { @MainActor in
            await SettingsView.probeTokenStatuses(
                for: ["a"],
                probe: { name in
                    withUnsafeCurrentTask { $0?.cancel() }
                    // The replacement task starts: it resets the set, then flags the same profile.
                    log.checking = []
                    log.setChecking(name, true)
                    return Self.status(name)
                },
                setChecking: log.setChecking,
                onStatus: { name, _ in log.recorded.append(name) }
            )
        }
        await task.value
        XCTAssertEqual(log.checking, ["a"])
        XCTAssertEqual(log.recorded, [])
    }
}
