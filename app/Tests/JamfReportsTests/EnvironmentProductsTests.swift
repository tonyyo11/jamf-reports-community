import XCTest
@testable import JamfReports

final class EnvironmentProductsTests: XCTestCase {
    private typealias P = EnvironmentProducts.Product

    private func tabs(_ products: EnvironmentProducts) -> Set<Tab> {
        let visibility = TabVisibility().limited(to: products)
        return Set(Tab.allCases.filter { visibility.isVisible($0) })
    }

    private func env(_ products: P..., composition: EnvironmentComposition = .unknown)
        -> EnvironmentProducts {
        EnvironmentProducts(products: Set(products), composition: composition)
    }

    func testFromReadsEverySlot() {
        let block = EnvironmentProfiles(
            jamfPro: "a", platform: "b", jamfSchool: nil, protect: "c", securityCloud: "d",
            source: .profilesBlock)
        let products = EnvironmentProducts.from(
            block, composition: .mixed, legacyPlatformAuth: false)
        XCTAssertEqual(products.products, [.jamfPro, .platform, .protect, .securityCloud])
        XCTAssertEqual(products.composition, .mixed)
        let school = EnvironmentProducts.from(
            EnvironmentProfiles(jamfSchool: "s", source: .profilesBlock),
            composition: .unknown, legacyPlatformAuth: false)
        XCTAssertTrue(school.isSchool)
    }

    func testLegacyPlatformAuthAppliesOnlyWithoutAProfilesBlock() {
        let legacy = EnvironmentProfiles(jamfPro: "a")
        XCTAssertTrue(EnvironmentProducts.from(
            legacy, composition: .unknown, legacyPlatformAuth: true).has(.platform))
        XCTAssertFalse(EnvironmentProducts.from(
            legacy, composition: .unknown, legacyPlatformAuth: false).has(.platform))
        let block = EnvironmentProfiles(jamfPro: "a", source: .profilesBlock)
        XCTAssertFalse(EnvironmentProducts.from(
            block, composition: .unknown, legacyPlatformAuth: true).has(.platform))
    }

    func testProtectOnlyAndSchoolFlags() {
        XCTAssertTrue(env(.protect).isProtectOnly)
        XCTAssertFalse(env(.protect, .jamfPro).isProtectOnly)
        XCTAssertFalse(env(.protect, .jamfSchool).isProtectOnly)
        XCTAssertFalse(env(.jamfSchool, .jamfPro).isSchool)
    }

    func testProTabsFollowPlatformProtectAndComposition() {
        let pro = tabs(env(.jamfPro))
        XCTAssertFalse(pro.contains(.schoolDevices))
        XCTAssertFalse(pro.contains(.complianceBenchmarks))
        XCTAssertFalse(pro.contains(.protectDashboard))
        XCTAssertTrue(pro.contains(.mobileFleet))
        XCTAssertTrue(tabs(env(.jamfPro, .platform)).contains(.complianceBenchmarks))
        XCTAssertTrue(tabs(env(.jamfPro, .protect)).contains(.protectDashboard))
        XCTAssertFalse(tabs(env(.jamfPro, composition: .macsOnly)).contains(.mobileFleet))
        XCTAssertTrue(tabs(env(.jamfPro, composition: .mixed)).contains(.mobileFleet))
    }

    func testSchoolTabs() {
        XCTAssertEqual(tabs(env(.jamfSchool)), Tab.schoolTabs)
        XCTAssertEqual(
            tabs(env(.jamfSchool, .protect)),
            Tab.schoolTabs.union([.protectDashboard, .backups]), "Protect is backed up alone")
    }

    func testProtectOnlyTabs() {
        XCTAssertEqual(tabs(env(.protect)), [
            .overview, .protectDashboard, .trends, .reports, .schedules, .runs, .config, .sources,
            .settings, .onboarding,
        ])
    }

    func testDemoKeepsEveryTabButSchoolDevices() {
        XCTAssertEqual(
            tabs(.demo), Set(Tab.allCases).subtracting([.schoolDevices]))
    }

    func testConfigTabsFollowTheProducts() {
        typealias C = ConfigView.ConfigTab
        XCTAssertFalse(C.offered(env(.jamfPro)).contains(.platform))
        XCTAssertTrue(C.offered(env(.jamfPro, .platform)).contains(.platform))
        XCTAssertEqual(C.offered(env(.protect)), [.thresholds, .output, .fromFile])
        XCTAssertEqual(C.offered(env(.jamfSchool)), [.thresholds, .output, .fromFile])
    }
}
