import XCTest
@testable import JamfReports

final class GettingStartedChecklistTests: XCTestCase {

    // MARK: - All false

    func testAllFalseFivePending() {
        let checklist = GettingStartedChecklist.build(
            connected: false, collected: false,
            customized: false, scheduled: false, reported: false
        )
        XCTAssertEqual(checklist.steps.count, 5)
        XCTAssertTrue(checklist.steps.allSatisfy { !$0.done })
        XCTAssertEqual(checklist.completedCount, 0)
    }

    func testAllFalseFirstIncompleteIsConnect() {
        let checklist = GettingStartedChecklist.build(
            connected: false, collected: false,
            customized: false, scheduled: false, reported: false
        )
        XCTAssertFalse(checklist.isComplete)
        XCTAssertEqual(checklist.firstIncomplete?.kind, .connect)
    }

    // MARK: - All true

    func testAllTrueIsComplete() {
        let checklist = GettingStartedChecklist.build(
            connected: true, collected: true,
            customized: true, scheduled: true, reported: true
        )
        XCTAssertTrue(checklist.isComplete)
        XCTAssertNil(checklist.firstIncomplete)
        XCTAssertEqual(checklist.completedCount, 5)
    }

    // MARK: - Mixed

    func testConnectedAndCollectedFirstIncompleteIsCustomize() {
        let checklist = GettingStartedChecklist.build(
            connected: true, collected: true,
            customized: false, scheduled: false, reported: false
        )
        XCTAssertFalse(checklist.isComplete)
        XCTAssertEqual(checklist.firstIncomplete?.kind, .customize)
        XCTAssertEqual(checklist.completedCount, 2)
    }

    func testConnectedOnlyFirstIncompleteIsCollect() {
        let checklist = GettingStartedChecklist.build(
            connected: true, collected: false,
            customized: false, scheduled: false, reported: false
        )
        XCTAssertEqual(checklist.firstIncomplete?.kind, .collect)
    }

    func testAllExceptReportedFirstIncompleteIsReport() {
        let checklist = GettingStartedChecklist.build(
            connected: true, collected: true,
            customized: true, scheduled: true, reported: false
        )
        XCTAssertEqual(checklist.firstIncomplete?.kind, .report)
        XCTAssertEqual(checklist.completedCount, 4)
    }

    // MARK: - Step order

    func testStepOrderIsConnectCollectCustomizeScheduleReport() {
        let checklist = GettingStartedChecklist.build(
            connected: false, collected: false,
            customized: false, scheduled: false, reported: false
        )
        let kinds = checklist.steps.map(\.kind)
        XCTAssertEqual(kinds, [.connect, .collect, .customize, .schedule, .report])
    }

    // MARK: - destinationTab values are valid Tab raw values

    func testDestinationTabsAreValidTabRawValues() {
        let checklist = GettingStartedChecklist.build(
            connected: false, collected: false,
            customized: false, scheduled: false, reported: false
        )
        let validRawValues = Set(Tab.allCases.map(\.rawValue))
        for step in checklist.steps {
            XCTAssertTrue(
                validRawValues.contains(step.destinationTab),
                "\(step.kind.rawValue).destinationTab '\(step.destinationTab)' is not a valid Tab rawValue"
            )
        }
    }

    // MARK: - Specific destinationTab mapping

    func testDestinationTabMapping() {
        let checklist = GettingStartedChecklist.build(
            connected: false, collected: false,
            customized: false, scheduled: false, reported: false
        )
        let byKind = Dictionary(uniqueKeysWithValues: checklist.steps.map { ($0.kind, $0.destinationTab) })
        XCTAssertEqual(byKind[.connect], Tab.sources.rawValue)
        XCTAssertEqual(byKind[.collect], Tab.sources.rawValue)
        XCTAssertEqual(byKind[.customize], Tab.config.rawValue)
        XCTAssertEqual(byKind[.schedule], Tab.schedules.rawValue)
        XCTAssertEqual(byKind[.report], Tab.reports.rawValue)
    }

    // MARK: - ID stability

    func testStepIDMatchesKindRawValue() {
        let checklist = GettingStartedChecklist.build(
            connected: true, collected: false,
            customized: false, scheduled: false, reported: false
        )
        for step in checklist.steps {
            XCTAssertEqual(step.id, step.kind.rawValue)
        }
    }

    // MARK: - Equatable

    func testEqualChecklistsAreEqual() {
        let a = GettingStartedChecklist.build(
            connected: true, collected: true,
            customized: false, scheduled: false, reported: false
        )
        let b = GettingStartedChecklist.build(
            connected: true, collected: true,
            customized: false, scheduled: false, reported: false
        )
        XCTAssertEqual(a, b)
    }

    func testDifferentChecklistsAreNotEqual() {
        let a = GettingStartedChecklist.build(
            connected: true, collected: false,
            customized: false, scheduled: false, reported: false
        )
        let b = GettingStartedChecklist.build(
            connected: false, collected: false,
            customized: false, scheduled: false, reported: false
        )
        XCTAssertNotEqual(a, b)
    }
}
