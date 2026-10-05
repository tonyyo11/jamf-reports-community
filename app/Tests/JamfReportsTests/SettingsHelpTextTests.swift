import XCTest
@testable import JamfReports

final class SettingsHelpTextTests: XCTestCase {

    /// The help names every command the engine skips, not a remembered subset: it was four when
    /// the list had grown to six.
    func testSkipExpensiveHelpNamesEveryKindTheEngineSkips() {
        let kinds = ReportEngine.expensivePerDeviceKinds
        XCTAssertEqual(kinds.count, 6)
        for skipping in [true, false] {
            let text = SettingsView.skipExpensiveSubtitle(skipping: skipping)
            for kind in kinds {
                XCTAssertTrue(text.contains(kind), "\(kind) missing (skipping: \(skipping))")
            }
            XCTAssertTrue(text.contains("\(kinds.count) per-device commands"), text)
        }
    }

    /// Each text begins with the switch's position, so the one shown with the switch off does
    /// not read as the action of the switch's "Skip" label.
    func testSkipExpensiveHelpStatesThePosition() {
        let on = SettingsView.skipExpensiveSubtitle(skipping: true)
        let off = SettingsView.skipExpensiveSubtitle(skipping: false)
        XCTAssertTrue(on.hasPrefix("On: manual refreshes skip"), on)
        XCTAssertTrue(off.hasPrefix("Off: every collect runs"), off)
        XCTAssertTrue(on.contains("Scheduled collects still run them"))
    }

    func testTheOpenSourceCardDoesNotCallTheCommandLineToolIndependent() {
        let text = SettingsView.commandLineBlurb
        XCTAssertFalse(text.contains("ships independently"))
        XCTAssertTrue(text.contains("includes its own jamf-reports command-line tool"))
        XCTAssertTrue(text.contains("jamf-cli, which is installed separately"))
    }
}
