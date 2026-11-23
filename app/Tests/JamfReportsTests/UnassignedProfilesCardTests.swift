import XCTest
@testable import JamfReports

final class UnassignedProfilesCardTests: XCTestCase {
    private func row(
        url: String, auth: String = "oauth2", use: AddSheetPlan.UnassignedProfile.Use = .newWorkspace
    ) -> AddSheetPlan.UnassignedProfile {
        AddSheetPlan.UnassignedProfile(
            name: "acme", product: .pro, url: url, use: use, authMethod: auth)
    }

    func testSubtitleNamesProductAuthMethodAndHost() {
        let text = UnassignedProfilesCardText.subtitle(
            for: row(url: "https://acme.jamfcloud.com"))
        XCTAssertTrue(text.contains("Jamf Pro"))
        XCTAssertTrue(text.contains("oauth2"))
        XCTAssertTrue(text.contains("acme.jamfcloud.com"))
        XCTAssertFalse(text.contains("https://"))
    }

    func testSubtitleLeavesOutAnEmptyUrlAndAuthMethod() {
        let text = UnassignedProfilesCardText.subtitle(for: row(url: "", auth: ""))
        XCTAssertEqual(text, "Jamf Pro")
    }

    func testSubtitleKeepsAnUnparseableUrlAsStored() {
        let text = UnassignedProfilesCardText.subtitle(for: row(url: "jamf.internal"))
        XCTAssertTrue(text.contains("jamf.internal"))
    }
}
