import XCTest
@testable import JamfReports

final class StateFileStoreAdvisoryTests: XCTestCase {

    private var dir: URL!
    private var store: StateFileStore!
    private let kind = "certificate-authority"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = StateFileStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func fail(
        _ kind: String, _ cause: FailureCause.Kind, exit: Int32, at date: Date? = nil
    ) {
        store.record(
            .failed(exitCode: exit), report: kind, at: date ?? now,
            cause: FailureCause(kind: cause, names: [], hint: nil, exitCode: exit))
    }

    func testAMissingPermissionIsAdvisoryOnlyUntilTheKindLands() {
        fail(kind, .missingPermission, exit: 5)
        XCTAssertTrue(store.isAdvisory(kind: kind))
        store.record(.landed, report: kind, at: now)
        fail(kind, .missingPermission, exit: 5)
        XCTAssertFalse(store.isAdvisory(kind: kind), "it landed once, so a refusal is a failure")
    }

    func testNotConfiguredIsAdvisoryBeforeAndAfterALanding() {
        fail(kind, .notConfiguredOnServer, exit: 4)
        XCTAssertTrue(store.isAdvisory(kind: kind))
        store.record(.landed, report: kind, at: now)
        fail(kind, .notConfiguredOnServer, exit: 4)
        XCTAssertTrue(store.isAdvisory(kind: kind))
    }

    func testOtherCausesAndOtherKindsAreNeverAdvisory() {
        fail(kind, .other, exit: 1)
        XCTAssertFalse(store.isAdvisory(kind: kind))
        fail("computers", .missingPermission, exit: 5)
        XCTAssertFalse(store.isAdvisory(kind: "computers"))
        XCTAssertFalse(store.isAdvisory(kind: "overview"), "no record at all")
    }

    func testTheHoldIsAWeekAfterTheFailureAndOnlyForAnAdvisoryKind() {
        fail(kind, .missingPermission, exit: 5)
        XCTAssertEqual(store.advisoryHoldUntil(report: kind, now: now),
                       now.addingTimeInterval(7 * 86_400))
        fail("computers", .missingPermission, exit: 5)
        XCTAssertNil(store.advisoryHoldUntil(report: "computers", now: now))
    }

    func testAppInstallersIsQuietOnlyUntilItsFirstLanding() {
        let kind = "app-installers-deployments"
        fail(kind, .notConfiguredOnServer, exit: 4)
        XCTAssertTrue(store.isAdvisory(kind: kind))
        XCTAssertNotNil(store.advisoryHoldUntil(report: kind, now: now))
        store.record(.landed, report: kind, at: now)
        fail(kind, .notConfiguredOnServer, exit: 4)
        XCTAssertFalse(store.isAdvisory(kind: kind), "it answered once, so a 404 is a fault")
    }

    func testAMissingPermissionIsNotAdvisoryForAppInstallers() {
        fail("app-installers-deployments", .missingPermission, exit: 5)
        XCTAssertFalse(store.isAdvisory(kind: "app-installers-deployments"),
                       "Read Mac Applications is already required by app-status")
        fail("patch-policies", .notConfiguredOnServer, exit: 4)
        XCTAssertFalse(store.isAdvisory(kind: "patch-policies"))
    }

    func testAFutureStampHoldsNothing() {
        fail(kind, .missingPermission, exit: 5, at: now.addingTimeInterval(86_400))
        XCTAssertNil(store.advisoryHoldUntil(report: kind, now: now))
    }
}
