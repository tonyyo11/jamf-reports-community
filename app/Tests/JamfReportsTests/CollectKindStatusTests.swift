import XCTest
@testable import JamfReports

/// Feature A (EPIC #182 #5): per-kind status list accumulated by
/// `ExistingCLISetupFlow.ingest`.
@MainActor
final class CollectKindStatusTests: XCTestCase {

    // MARK: - Basic outcome parsing

    func testOkLineAddsKindWithOkOutcome() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        flow.ingest("[ok] computers: 18342 bytes")
        XCTAssertEqual(flow.kindStatuses.count, 1)
        XCTAssertEqual(flow.kindStatuses[0].kind, "computers")
        XCTAssertEqual(flow.kindStatuses[0].outcome, .ok)
    }

    func testWarnLineAddsKindWithWarnOutcome() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        flow.ingest("[warn] update-device-failures: exit 1 — using cached")
        XCTAssertEqual(flow.kindStatuses.count, 1)
        XCTAssertEqual(flow.kindStatuses[0].kind, "update-device-failures")
        XCTAssertEqual(flow.kindStatuses[0].outcome, .warn)
    }

    func testSkipLineAddsKindWithSkipOutcome() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        flow.ingest("[skip] profile-status: tier scan not selected")
        XCTAssertEqual(flow.kindStatuses.count, 1)
        XCTAssertEqual(flow.kindStatuses[0].kind, "profile-status")
        XCTAssertEqual(flow.kindStatuses[0].outcome, .skip)
    }

    // MARK: - Order preserved, last-wins for repeated kind

    func testInsertionOrderIsPreserved() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        flow.ingest("[ok] computers: 100 bytes")
        flow.ingest("[ok] mobile-devices: 200 bytes")
        flow.ingest("[skip] patch-device-failures: skipped")
        XCTAssertEqual(flow.kindStatuses.map(\.kind), ["computers", "mobile-devices", "patch-device-failures"])
    }

    func testLaterOutcomeForSameKindOverridesPriorOutcome() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        // Simulate a retry scenario: ok → ok (no-op reassignment still counts as update)
        flow.ingest("[ok] computers: 100 bytes")
        flow.ingest("[warn] computers: retry fallback")
        XCTAssertEqual(flow.kindStatuses.count, 1, "same kind must not produce a second entry")
        XCTAssertEqual(flow.kindStatuses[0].outcome, .warn, "last outcome wins")
        XCTAssertEqual(flow.kindStatuses[0].kind, "computers")
    }

    func testLateOverridePreservesInsertionPosition() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        flow.ingest("[ok] computers: 100 bytes")
        flow.ingest("[ok] policies: 200 bytes")
        flow.ingest("[warn] computers: retry fallback")
        // computers was first; it stays at index 0 after being overridden
        XCTAssertEqual(flow.kindStatuses[0].kind, "computers")
        XCTAssertEqual(flow.kindStatuses[0].outcome, .warn)
        XCTAssertEqual(flow.kindStatuses[1].kind, "policies")
    }

    // MARK: - Info lines are not added to kindStatuses

    func testInfoLineDoesNotAppearInKindStatuses() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        flow.ingest("[info] collecting computers for alpha")
        XCTAssertTrue(flow.kindStatuses.isEmpty, "[info] lines update currentKind only")
        XCTAssertEqual(flow.progress.currentKind, "computers")
    }

    // MARK: - Existing counters still work alongside the per-kind list

    func testExistingCountersUnaffected() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        flow.ingest("[ok] computers: 100 bytes")
        flow.ingest("[warn] policies: exit 1")
        flow.ingest("[skip] patch-device-failures: tier")
        XCTAssertEqual(flow.progress.collected, 1)
        XCTAssertEqual(flow.progress.failed, 1)
        XCTAssertEqual(flow.progress.skipped, 1)
    }

    // MARK: - kindStatuses resets per profile in run loop

    func testKindStatusesClearBetweenProfiles() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha", "beta"])

        await flow.run(
            initialize: { _ in 0 },
            collect: { name, onLine in
                if name == "alpha" {
                    onLine(CLIBridge.LogLine(timestamp: Date(), level: .ok,
                                   text: "[ok] computers: 100 bytes"))
                    await Task.yield()
                } else {
                    onLine(CLIBridge.LogLine(timestamp: Date(), level: .ok,
                                   text: "[ok] policies: 200 bytes"))
                    await Task.yield()
                }
                return 0
            }
        )

        // After the run, kindStatuses reflects the LAST profile collected ("beta").
        XCTAssertEqual(flow.kindStatuses.map(\.kind), ["policies"])
    }

    // MARK: - Identifiable id

    func testKindStatusIdIsKindString() {
        let entry = ExistingCLISetupFlow.CollectKindStatus(kind: "computers", outcome: .ok)
        XCTAssertEqual(entry.id, "computers")
    }
}
