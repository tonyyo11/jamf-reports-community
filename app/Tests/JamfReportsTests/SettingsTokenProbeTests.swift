import XCTest
@testable import JamfReports

@MainActor
final class SettingsTokenProbeTests: XCTestCase {

    @MainActor
    private final class Log {
        var probed: [String] = []
        var recorded: [String] = []
    }

    private static func status(_ name: String) -> TokenStatus {
        TokenStatus.make(profile: name, token: "token", expiresAt: nil, raw: "")
    }

    func testProbesEveryProfileAndRecordsNonNilStatuses() async {
        let log = Log()
        await SettingsView.probeTokenStatuses(
            for: ["a", "b", "c"],
            probe: { name in
                log.probed.append(name)
                return name == "b" ? nil : Self.status(name)
            },
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
                onStatus: { name, _ in log.recorded.append(name) }
            )
        }
        await task.value
        XCTAssertEqual(log.probed, [])
        XCTAssertEqual(log.recorded, [])
    }
}
