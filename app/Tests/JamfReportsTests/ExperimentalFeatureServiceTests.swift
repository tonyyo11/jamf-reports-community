import Foundation
import XCTest
@testable import JamfReports

/// Tests opt-in feature persistence. Each test uses an isolated UserDefaults
/// suite so the user's real preferences are never touched and concurrent
/// runs don't see each other's state.
@MainActor
final class ExperimentalFeatureServiceTests: XCTestCase {

    private var suiteName: String = ""

    override func setUp() {
        super.setUp()
        suiteName = "experimental-features-tests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
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

        service.setEnabled(.platformAPI, true)
        XCTAssertTrue(service.isEnabled(.platformAPI))
        XCTAssertFalse(service.isEnabled(.protect))

        service.setEnabled(.platformAPI, false)
        XCTAssertFalse(service.isEnabled(.platformAPI))
    }

    func testEnablingMultipleFeaturesStoresBoth() {
        let service = ExperimentalFeatureService(defaults: makeDefaults())

        service.setEnabled(.platformAPI, true)
        service.setEnabled(.protect, true)

        XCTAssertTrue(service.isEnabled(.platformAPI))
        XCTAssertTrue(service.isEnabled(.protect))
    }

    // MARK: - Persistence across instances

    func testStateSurvivesAcrossInstances() {
        let writer = ExperimentalFeatureService(defaults: makeDefaults())
        writer.setEnabled(.protect, true)

        let reader = ExperimentalFeatureService(defaults: makeDefaults())
        XCTAssertTrue(reader.isEnabled(.protect))
        XCTAssertFalse(reader.isEnabled(.platformAPI))
    }

    func testRemovingLastFeatureClearsStorageKey() {
        let defaults = makeDefaults()
        let service = ExperimentalFeatureService(defaults: defaults)

        service.setEnabled(.platformAPI, true)
        XCTAssertNotNil(defaults.string(forKey: ExperimentalFeatureService.storageKey))

        service.setEnabled(.platformAPI, false)
        XCTAssertNil(
            defaults.string(forKey: ExperimentalFeatureService.storageKey),
            "empty set should remove the storage key rather than store an empty string"
        )
    }

    func testStorageFormatIsCommaSeparatedAndSorted() {
        let defaults = makeDefaults()
        let service = ExperimentalFeatureService(defaults: defaults)

        service.setEnabled(.protect, true)
        service.setEnabled(.platformAPI, true)

        let stored = defaults.string(forKey: ExperimentalFeatureService.storageKey)
        XCTAssertEqual(stored, "platform-api,protect-deep-dive")
    }

    // MARK: - Unknown tokens in storage

    func testUnknownTokensInStorageAreIgnored() {
        let defaults = makeDefaults()
        defaults.set("platform-api,bogus-feature", forKey: ExperimentalFeatureService.storageKey)

        let service = ExperimentalFeatureService(defaults: defaults)
        XCTAssertTrue(service.isEnabled(.platformAPI))
        XCTAssertFalse(service.isEnabled(.protect))
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
