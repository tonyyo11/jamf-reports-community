import XCTest
import SwiftUI
@testable import JamfReports

@MainActor
final class PageScaffoldTests: XCTestCase {
    func testScaffoldComposesContent() {
        let scaffold = PageScaffold {
            Text("Header")
            Text("Body")
        }
        _ = scaffold.body
        XCTAssertNotNil(scaffold)
    }

    func testScaffoldAcceptsCustomSpacing() {
        let scaffold = PageScaffold(spacing: 14) {
            Text("Body")
        }
        _ = scaffold.body
        XCTAssertNotNil(scaffold)
    }

    func testMinSupportedWidthIsStable() {
        XCTAssertEqual(PageScaffold<EmptyView>.minSupportedWidth, 640)
    }
}
