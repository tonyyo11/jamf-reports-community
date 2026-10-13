import Foundation
import XCTest
@testable import JamfReports

/// Tests opt-in feature persistence. Each test uses an isolated UserDefaults
/// suite so the user's real preferences are never touched and concurrent
/// runs don't see each other's state.
@MainActor
final class ExperimentalFeatureServiceTests: XCTestCase {

    nonisolated(unsafe) private var suiteName: String = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "experimental-features-tests-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return UserDefaults.standard
        }
        return defaults
    }

    // MARK: - Defaults

    func testAllFeaturesDisabledByDefault() {
        let service = ExperimentalFeatureService(defaults: makeDefaults())
        for feature in ExperimentalFeatureService.Feature.allCases {
            XCTAssertFalse(
                service.isEnabled(feature),
                "\(feature.rawValue) should default to off"
            )
        }
    }

    // MARK: - Round-trip

    func testEnableThenDisableRoundTrip() {
        let service = ExperimentalFeatureService(defaults: makeDefaults())

        service.setEnabled(.protect, true)
        XCTAssertTrue(service.isEnabled(.protect))

        service.setEnabled(.protect, false)
        XCTAssertFalse(service.isEnabled(.protect))
    }

    // MARK: - Persistence across instances

    func testStateSurvivesAcrossInstances() {
        let writer = ExperimentalFeatureService(defaults: makeDefaults())
        writer.setEnabled(.protect, true)

        let reader = ExperimentalFeatureService(defaults: makeDefaults())
        XCTAssertTrue(reader.isEnabled(.protect))
    }

    func testRemovingLastFeatureClearsStorageKey() {
        let defaults = makeDefaults()
        let service = ExperimentalFeatureService(defaults: defaults)

        service.setEnabled(.protect, true)
        XCTAssertNotNil(defaults.string(forKey: ExperimentalFeatureService.storageKey))

        service.setEnabled(.protect, false)
        XCTAssertNil(
            defaults.string(forKey: ExperimentalFeatureService.storageKey),
            "empty set should remove the storage key rather than store an empty string"
        )
    }

    func testStorageFormatIsTheRawValue() {
        let defaults = makeDefaults()
        let service = ExperimentalFeatureService(defaults: defaults)

        service.setEnabled(.protect, true)

        XCTAssertEqual(
            defaults.string(forKey: ExperimentalFeatureService.storageKey), "protect-deep-dive")
    }

    // MARK: - Unknown tokens in storage

    func testUnknownTokensInStorageAreIgnored() {
        let defaults = makeDefaults()
        defaults.set("bogus-feature", forKey: ExperimentalFeatureService.storageKey)

        let service = ExperimentalFeatureService(defaults: defaults)
        XCTAssertFalse(service.isEnabled(.protect))
    }

    /// The Platform API left the list; installs that stored its token keep working, and the
    /// token does not turn anything else on or survive the next save.
    func testTheGraduatedPlatformTokenIsIgnoredAndDroppedOnNextSave() {
        let defaults = makeDefaults()
        defaults.set("platform-api,protect-deep-dive", forKey: ExperimentalFeatureService.storageKey)

        let service = ExperimentalFeatureService(defaults: defaults)
        XCTAssertEqual(service.enabled, [.protect])

        service.setEnabled(.protect, false)
        XCTAssertNil(defaults.string(forKey: ExperimentalFeatureService.storageKey))
    }

    func testOnlyPreviewFeaturesRemainListed() {
        XCTAssertEqual(ExperimentalFeatureService.Feature.allCases, [.protect])
    }

    // MARK: - Feature metadata

    func testFeatureDiscussionURLsPointToCommunityCategories() {
        for feature in ExperimentalFeatureService.Feature.allCases {
            let url = feature.discussionURL
            XCTAssertNotNil(url, "\(feature.rawValue) should have a discussion URL")
            XCTAssertEqual(url?.host, "github.com")
            XCTAssertTrue(
                url?.path.contains("/discussions/categories/") ?? false,
                "\(feature.rawValue) URL should point at a discussions category"
            )
        }
    }
}
