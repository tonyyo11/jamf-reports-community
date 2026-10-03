import XCTest
@testable import JamfReports

@MainActor
final class SettingsAIPanelCopyTests: XCTestCase {

    /// There is one model and it runs on this Mac, so the panel's intro must say
    /// so and must not offer a second place the data could go.
    func testIntroSaysTheModelRunsOnThisMacAndNothingLeavesIt() {
        let intro = SettingsView.aiInsightsBlurb
        XCTAssertTrue(intro.contains("runs on this Mac"), intro)
        XCTAssertTrue(intro.contains("nothing leaves it"), intro)
    }

    /// The insight card is on five screens, not only Overview.
    func testIntroNamesEveryScreenWithAnInsightCard() {
        let intro = SettingsView.aiInsightsBlurb
        for screen in ["Overview", "Trends", "Audit", "Security Posture", "Compliance Posture"] {
            XCTAssertTrue(intro.contains(screen), "intro does not name \(screen): \(intro)")
        }
    }

    func testIntroDoesNotMentionAnOffDeviceModel() {
        let intro = SettingsView.aiInsightsBlurb.lowercased()
        for word in ["private cloud", "external", "provider", "opt in"] {
            XCTAssertFalse(intro.contains(word), "intro still mentions \(word)")
        }
    }
}
