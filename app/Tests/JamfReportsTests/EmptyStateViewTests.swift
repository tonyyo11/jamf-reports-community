import XCTest
import SwiftUI
@testable import JamfReports

@MainActor
final class EmptyStateViewTests: XCTestCase {

    func testEmptyStateViewBasicInitialization() {
        let emptyState = EmptyStateView(
            title: "Test Title",
            message: "Test Message"
        )

        // If this instantiates without throwing, the basic API works
        XCTAssertNotNil(emptyState)
    }

    func testEmptyStateViewWithIcon() {
        let emptyState = EmptyStateView(
            systemImage: "doc.badge.plus",
            title: "Test Title",
            message: "Test Message"
        )

        // If this instantiates without throwing, the icon API works
        XCTAssertNotNil(emptyState)
    }

    func testEmptyStateViewWithAction() {
        var actionCalled = false
        let action = EmptyStateAction(
            label: "Test Action",
            icon: "house"
        ) {
            actionCalled = true
        }

        let emptyState = EmptyStateView(
            title: "Test Title",
            message: "Test Message",
            primaryAction: action
        )

        // Verify the action was created properly
        XCTAssertNotNil(emptyState)
        XCTAssertEqual(action.label, "Test Action")
        XCTAssertEqual(action.icon, "house")

        // Test that action can be called
        action.action()
        XCTAssertTrue(actionCalled)
    }

    func testEmptyStateActionBasicInitialization() {
        var called = false

        let action = EmptyStateAction(label: "Test") {
            called = true
        }

        XCTAssertEqual(action.label, "Test")
        XCTAssertNil(action.icon)

        action.action()
        XCTAssertTrue(called)
    }
}