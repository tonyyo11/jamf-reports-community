import XCTest
@testable import JamfReports

/// The collect-then-generate flow and the AI narrative: the narrative reads the snapshots, so
/// it must be asked for after the collect has refreshed them, and only if the collect worked.
/// `runCollectThenGenerate` is the injected core of `CLIBridge.collectThenGenerate`, the way
/// `runGenerateAll` is for `generateAll`, so no jamf-cli runs here.
@MainActor
final class CollectThenGenerateNarrativeTests: XCTestCase {

    private struct Boom: Error {}

    /// The flow holds the tick lock; keep it off the real one.
    private func holdingATemporaryLock() { _ = useTemporaryTickLock() }

    private final class Events {
        var log: [String] = []
    }

    func testNarrativeIsAskedForAfterTheCollectAndHandedToGenerate() async throws {
        holdingATemporaryLock()
        let events = Events()
        let exit = try await CLIBridge.runCollectThenGenerate(
            collect: { events.log.append("collect"); return 0 },
            narrative: { events.log.append("narrative"); return "Fleet is healthy." },
            generate: { events.log.append("generate: \($0 ?? "nil")"); return 0 }
        )
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(events.log, ["collect", "narrative", "generate: Fleet is healthy."])
    }

    func testNarrativeIsNotAskedForWhenTheCollectFails() async throws {
        holdingATemporaryLock()
        let events = Events()
        let exit = try await CLIBridge.runCollectThenGenerate(
            collect: { events.log.append("collect"); return CLIBridge.exitCodeUnauthorized },
            narrative: { events.log.append("narrative"); return "unused" },
            generate: { events.log.append("generate: \($0 ?? "nil")"); return 0 }
        )
        XCTAssertEqual(exit, CLIBridge.exitCodeUnauthorized)
        XCTAssertEqual(events.log, ["collect"])
    }

    func testNarrativeIsNotAskedForWhenTheCollectThrows() async {
        holdingATemporaryLock()
        let events = Events()
        do {
            _ = try await CLIBridge.runCollectThenGenerate(
                collect: { events.log.append("collect"); throw Boom() },
                narrative: { events.log.append("narrative"); return "unused" },
                generate: { events.log.append("generate: \($0 ?? "nil")"); return 0 }
            )
            XCTFail("the collect's error must reach the caller")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertEqual(events.log, ["collect"])
    }

    /// AI off, no data, a timeout: `makeForGUIGenerate` answers nil and the report goes ahead.
    func testAMissingNarrativeStillGenerates() async throws {
        holdingATemporaryLock()
        let events = Events()
        let exit = try await CLIBridge.runCollectThenGenerate(
            collect: { events.log.append("collect"); return 0 },
            narrative: { events.log.append("narrative"); return nil },
            generate: { events.log.append("generate: \($0 ?? "nil")"); return 7 }
        )
        XCTAssertEqual(exit, 7, "generate's own exit code is the flow's")
        XCTAssertEqual(events.log, ["collect", "narrative", "generate: nil"])
    }

    /// The callers that never ask for a narrative (the scheduler, the Trends button).
    func testNoNarrativeSourceGeneratesWithNil() async throws {
        holdingATemporaryLock()
        let events = Events()
        let exit = try await CLIBridge.runCollectThenGenerate(
            collect: { events.log.append("collect"); return 0 },
            narrative: nil,
            generate: { events.log.append("generate: \($0 ?? "nil")"); return 0 }
        )
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(events.log, ["collect", "generate: nil"])
    }
}
