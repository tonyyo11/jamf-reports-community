import XCTest
@testable import JamfReports

/// The PCC crash-prevention invariant: `PrivateCloudComputeLanguageModel` traps
/// when constructed without `com.apple.developer.private-cloud-compute`, so the app
/// must probe `PCCEntitlement.isPresent` first and NEVER construct the model when
/// it's absent. The test process carries no such entitlement, so `isPresent` must
/// be false — if this ever flips true unexpectedly, the guard is bypassed.
final class PCCEntitlementTests: XCTestCase {
    func testEntitlementAbsentInUnentitledProcess() {
        XCTAssertFalse(PCCEntitlement.isPresent)
    }

    func testEntitlementMissingAvailabilityIsNotReadyWithMessage() {
        XCTAssertFalse(ModelAvailability.pccEntitlementMissing.isReady)
        XCTAssertFalse(ModelAvailability.pccEntitlementMissing.message.isEmpty)
    }
}
