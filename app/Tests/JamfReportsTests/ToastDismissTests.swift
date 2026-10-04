import XCTest
@testable import JamfReports

@MainActor
final class ToastDismissTests: XCTestCase {

    func testATimerClearsTheToastItWasStartedFor() {
        let store = WorkspaceStore(demoMode: true)
        let toast = Toast(message: "Report generated", style: .success)
        store.toast = toast
        store.dismissToast(ifShowing: toast.id)
        XCTAssertNil(store.toast)
    }

    /// The first toast's timer fires while a later toast is up: it must leave that one alone.
    func testATimerLeavesAToastThatReplacedItsToast() {
        let store = WorkspaceStore(demoMode: true)
        let first = Toast(message: "Report generated", style: .success)
        let second = Toast(message: "Refresh finished with warnings", style: .warning)
        store.toast = first
        store.toast = second
        store.dismissToast(ifShowing: first.id)
        XCTAssertEqual(store.toast?.id, second.id)
        store.dismissToast(ifShowing: second.id)
        XCTAssertNil(store.toast)
    }

    func testDismissingWithNoToastIsANoOp() {
        let store = WorkspaceStore(demoMode: true)
        store.dismissToast(ifShowing: UUID())
        XCTAssertNil(store.toast)
    }

    func testAToastStaysUpForFourSeconds() {
        XCTAssertEqual(Toast.displaySeconds, 4)
    }
}
