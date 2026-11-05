import XCTest
@testable import JamfReports

@MainActor
final class WorkspaceMergeModelTests: XCTestCase {
    private func profile(
        _ name: String, auth: String = "oauth2", product: JamfCLIProduct = .pro
    ) -> JamfCLIProfile {
        JamfCLIProfile(name: name, url: "https://\(name).example.com", schedules: 0,
                       status: .idle, authMethod: auth, product: product)
    }

    private func list(
        target: String = "Acme", slot: String? = nil, _ profiles: [JamfCLIProfile]
    ) -> [String] {
        WorkspaceMergeCandidates.list(
            target: target, targetPlatformSlot: slot, profiles: profiles, hasWorkspace: { _ in true })
    }

    func testCandidatesOfferAPlatformWorkspaceForAnOAuthTarget() {
        let all = [profile("Acme"), profile("Acme-P", auth: "platform"), profile("Other")]
        XCTAssertEqual(list(all), ["Acme-P"])
        XCTAssertEqual(list(slot: "Acme-P", all), ["Acme-P"])
    }

    func testCandidatesAreEmptyForPlatformSchoolAndOtherSlotTargets() {
        let platform = profile("Acme-P", auth: "platform")
        XCTAssertEqual(list(target: "Acme-P", [profile("Acme"), platform]), [])
        XCTAssertEqual(list(target: "Sch", [profile("Sch", auth: "apikey", product: .school),
                                            platform]), [])
        XCTAssertEqual(list(slot: "Elsewhere", [profile("Acme"), platform]), [])
    }

    func testCandidatesNeedAFolder() {
        let all = [profile("Acme"), profile("Acme-P", auth: "platform")]
        XCTAssertEqual(WorkspaceMergeCandidates.list(
            target: "Acme", targetPlatformSlot: nil, profiles: all, hasWorkspace: { _ in false }), [])
    }

    private final class Spy: @unchecked Sendable {
        var verdict: PlatformHostCheck.Verdict = .same
        var planned = 0
        var ran: [WorkspaceMergeJournal] = []
        var runError: Error?
        var onDisk: WorkspaceMergeJournal?
    }

    private let plan = WorkspaceMergePlan(
        source: "Acme-P", target: "Acme", stamp: "20261105-120000",
        mergedFolder: "/tmp/_merged/Acme-P-20261105-120000", steps: [
            .init(area: .config, action: .tail(.moveSource), source: "a", target: "b", archive: nil),
            .init(area: .config, action: .tail(.moveSource), source: "a", target: "b", archive: nil),
        ], differingConfigKeys: [], outsideSourceFolder: [])

    private func model(_ spy: Spy) -> WorkspaceMergeModel {
        let plan = plan
        return WorkspaceMergeModel(target: "Acme", deps: .init(
            hostVerdict: { _, _ in spy.verdict },
            makePlan: { _, _ in spy.planned += 1; return plan },
            run: { journal, progress in
                spy.ran.append(journal)
                progress(1, 2)
                if let error = spy.runError { throw error }
            },
            pending: { _ in spy.onDisk }))
    }

    func testDifferentAndUnknownRefuseWithoutPlanning() async {
        let spy = Spy()
        spy.verdict = .different(jamfPro: "a.example.com", platform: "b.example.com")
        let different = model(spy)
        await different.choose(source: "Acme-P")
        guard case .refused(let text) = different.phase else { return XCTFail("not refused") }
        XCTAssertTrue(text.contains("a.example.com") && text.contains("b.example.com"))
        spy.verdict = .unknown
        let unknown = model(spy)
        await unknown.choose(source: "Acme-P")
        guard case .refused(let more) = unknown.phase else { return XCTFail("not refused") }
        XCTAssertTrue(more.contains("Add sheet"))
        XCTAssertEqual(spy.planned, 0)
    }

    func testSameBecomesReady() async {
        let spy = Spy()
        let model = model(spy)
        await model.choose(source: "Acme-P")
        XCTAssertEqual(model.phase, .ready(plan))
    }

    func testMergeFinishesAndAFailureKeepsItsMessage() async {
        let spy = Spy()
        let done = model(spy)
        await done.choose(source: "Acme-P")
        await done.merge()
        XCTAssertEqual(done.phase, .finished(mergedFolder: plan.mergedFolder))
        XCTAssertEqual(spy.ran.first?.done, 0)

        let stepError = WorkspaceMergeExecutor.RunError.step(index: 2, reason: "disk full")
        spy.runError = stepError
        let failed = model(spy)
        await failed.choose(source: "Acme-P")
        await failed.merge()
        XCTAssertEqual(failed.phase, .failed(
            ConfigSchema.fullDisplayText(stepError.localizedDescription).text))
    }

    /// Refused before a write: there is no journal, so the sheet does not offer Resume.
    func testRefusalsBeforeAnyWriteAreRefused() async {
        let errors: [Error] = [
            CLIBridgeError.tickLockHeld,
            WorkspaceMergeExecutor.RunError.peerClaim(workspace: "Acme", host: "mac"),
            WorkspaceMergeExecutor.RunError.pendingMerge(source: "Old"),
        ]
        for error in errors {
            let spy = Spy()
            spy.runError = error
            let model = model(spy)
            await model.choose(source: "Acme-P")
            await model.merge()
            XCTAssertEqual(model.phase, .refused(
                ConfigSchema.fullDisplayText(error.localizedDescription).text), "\(error)")
        }
    }

    func testResumeRunsTheJournalOnDiskNow() async {
        let spy = Spy()
        let fresh = WorkspaceMergeJournal(plan: plan, done: 3)
        spy.onDisk = fresh
        let model = model(spy)
        await model.resume()
        XCTAssertEqual(spy.ran, [fresh])
        XCTAssertEqual(model.phase, .finished(mergedFolder: plan.mergedFolder))
    }

    func testResumeWithNoJournalFails() async {
        let spy = Spy()
        let model = model(spy)
        await model.resume()
        XCTAssertTrue(spy.ran.isEmpty)
        guard case .failed = model.phase else { return XCTFail("not failed") }
    }
}
