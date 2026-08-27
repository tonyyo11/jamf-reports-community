import Foundation
import XCTest
@testable import JamfReports

final class ModelAvailabilityTests: XCTestCase {

    func testOnlyAvailableIsReady() {
        XCTAssertTrue(ModelAvailability.available.isReady)
        XCTAssertFalse(ModelAvailability.requiresMacOS27.isReady)
        XCTAssertFalse(ModelAvailability.disabledByConfig.isReady)
        XCTAssertFalse(ModelAvailability.deviceNotEligible.isReady)
        XCTAssertFalse(ModelAvailability.appleIntelligenceNotEnabled.isReady)
        XCTAssertFalse(ModelAvailability.modelNotReady.isReady)
        XCTAssertFalse(ModelAvailability.unknown("x").isReady)
    }

    func testEveryCaseHasANonEmptyMessage() {
        let cases: [ModelAvailability] = [
            .available, .requiresMacOS27, .disabledByConfig, .deviceNotEligible,
            .appleIntelligenceNotEnabled, .modelNotReady,
            .unknown("detail"),
        ]
        for state in cases {
            XCTAssertFalse(state.message.isEmpty, "\(state) must render a message")
        }
    }

    func testRequiresMacOS27MessageMentionsMacOS27() {
        XCTAssertTrue(ModelAvailability.requiresMacOS27.message.contains("macOS 27"))
    }

    func testUnknownMessageCarriesTheDetail() {
        XCTAssertTrue(ModelAvailability.unknown("boom").message.contains("boom"))
    }

    /// On the default toolchain (Swift < 6.4) and any host below macOS 27,
    /// `current(for:)` must always resolve to `.requiresMacOS27` for every tier.
    /// Under Xcode 27 on macOS 27 hardware this maps live model availability
    /// instead — verified manually by Tony, not reachable here.
    func testCurrentIsRequiresMacOS27OnDefaultToolchain() {
        #if canImport(FoundationModels) && compiler(>=6.4)
        // The FM-gated branch compiles; on macOS < 27 it still returns
        // .requiresMacOS27 via the runtime #available check.
        if #unavailable(macOS 27) {
            XCTAssertEqual(ModelAvailability.current(for: AIConfig(tier: "on_device")), .requiresMacOS27)
        }
        #else
        XCTAssertEqual(ModelAvailability.current(for: AIConfig(tier: "on_device")), .requiresMacOS27)
        XCTAssertEqual(ModelAvailability.current(for: AIConfig(tier: "external")), .requiresMacOS27)
        #endif
    }

    /// `platformSupported` is the config-free mirror of the check above — it
    /// must agree with whatever `current(for:)` collapses to on this
    /// toolchain/host, since it's what views use to decide whether to
    /// instantiate an AI surface at all (macOS 26 hosts must hide entirely).
    func testPlatformSupportedMatchesDefaultToolchainBehavior() {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #unavailable(macOS 27) {
            XCTAssertFalse(ModelAvailability.platformSupported)
        }
        #else
        XCTAssertFalse(ModelAvailability.platformSupported)
        #endif
    }
}
