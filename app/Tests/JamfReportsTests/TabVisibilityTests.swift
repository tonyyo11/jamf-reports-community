import Foundation
import XCTest
@testable import JamfReports

final class TabVisibilityTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultVisibilityShowsAllTabs() {
        let v = TabVisibility()
        for tab in Tab.allCases {
            XCTAssertTrue(v.isVisible(tab),
                          "Default visibility must show every tab, including \(tab.rawValue)")
        }
    }

    // MARK: - Core-tab protection

    func testCoreTabsCannotBeHiddenEvenIfPersistedRaw() {
        // Simulate a corrupted/stale @AppStorage value that names a core tab.
        let v = TabVisibility.parse("overview,settings,devices,patch,updates")

        // Core tabs stay visible despite their slugs being in raw storage.
        XCTAssertTrue(v.isVisible(.overview), "Overview is a core tab — must stay visible")
        XCTAssertTrue(v.isVisible(.settings), "Settings is a core tab — must stay visible")
        XCTAssertTrue(v.isVisible(.devices),  "Devices is a core tab — must stay visible")
        XCTAssertTrue(v.isVisible(.sources),  "Sources is a core tab — must stay visible")
        XCTAssertTrue(v.isVisible(.onboarding), "Onboarding is core — must stay visible")

        // Non-core tabs in the slug list ARE hidden.
        XCTAssertFalse(v.isVisible(.patch))
        XCTAssertFalse(v.isVisible(.updates))
    }

    func testToggleIsNoopOnCoreTabs() {
        var v = TabVisibility()
        v.toggle(.overview)
        v.toggle(.settings)
        v.toggle(.devices)
        XCTAssertTrue(v.isVisible(.overview))
        XCTAssertTrue(v.isVisible(.settings))
        XCTAssertTrue(v.isVisible(.devices))
    }

    // MARK: - Toggle round-trip

    func testToggleHidesAndUnhidesNonCoreTabs() {
        var v = TabVisibility()
        XCTAssertTrue(v.isVisible(.patch))
        v.toggle(.patch)
        XCTAssertFalse(v.isVisible(.patch))
        v.toggle(.patch)
        XCTAssertTrue(v.isVisible(.patch))
    }

    func testShowAllRestoresEveryTab() {
        var v = TabVisibility()
        v.toggle(.patch)
        v.toggle(.updates)
        v.toggle(.trends)
        XCTAssertEqual(
            [v.isVisible(.patch), v.isVisible(.updates), v.isVisible(.trends)],
            [false, false, false]
        )
        v.showAll()
        XCTAssertTrue(v.isVisible(.patch))
        XCTAssertTrue(v.isVisible(.updates))
        XCTAssertTrue(v.isVisible(.trends))
    }

    // MARK: - Persistence round-trip

    func testParseSerializeRoundTrip() {
        var v = TabVisibility()
        v.toggle(.patch)
        v.toggle(.updates)
        let raw = v.serialize()
        let restored = TabVisibility.parse(raw)
        XCTAssertFalse(restored.isVisible(.patch))
        XCTAssertFalse(restored.isVisible(.updates))
        XCTAssertTrue(restored.isVisible(.trends))
    }

    func testSerializeOutputIsSortedForStability() {
        var a = TabVisibility()
        a.toggle(.updates)
        a.toggle(.patch)
        var b = TabVisibility()
        b.toggle(.patch)
        b.toggle(.updates)
        XCTAssertEqual(a.serialize(), b.serialize(),
                       "Serialized form must not depend on toggle order")
    }

    func testParseTolerantToGarbageAndWhitespace() {
        let v = TabVisibility.parse("  patch , , updates,not-a-tab,  ")
        XCTAssertFalse(v.isVisible(.patch))
        XCTAssertFalse(v.isVisible(.updates))
        // Unknown slugs are silently dropped, not crashed on.
        XCTAssertTrue(v.isVisible(.trends))
    }

    func testEmptyStringParsesToAllVisible() {
        let v = TabVisibility.parse("")
        for tab in Tab.allCases { XCTAssertTrue(v.isVisible(tab)) }
    }
}
