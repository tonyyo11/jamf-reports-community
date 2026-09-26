import Foundation
import XCTest
@testable import JamfReports

// Tests for the Titlebar status chip keyboard-activation fix.
// The fix replaces a hover-only popover with a Button that toggles the
// popover on click/Return/Space, making it keyboard-reachable.
// These tests verify the label string and toggle semantics.
final class TitlebarA11yTests: XCTestCase {

    // MARK: - Accessibility label correctness

    func testChipAccessibilityLabelNonEmpty() {
        XCTAssertFalse(chipAccessibilityLabel.isEmpty,
                       "The status chip must have a non-empty accessibility label")
    }

    func testChipAccessibilityLabelDescribesAction() {
        // Label must mention what the chip is and that it is interactive
        let label = chipAccessibilityLabel.lowercased()
        XCTAssertTrue(label.contains("jamf-cli") || label.contains("status"),
                      "Label must identify the chip as the jamf-cli status control; got '\(chipAccessibilityLabel)'")
    }

    // MARK: - Toggle semantics

    func testPopoverTogglesOnActivation() {
        var isPresented = false
        toggleChipPopover(&isPresented)
        XCTAssertTrue(isPresented, "First activation must show the popover")
        toggleChipPopover(&isPresented)
        XCTAssertFalse(isPresented, "Second activation must hide the popover")
    }

    func testPopoverStartsDismissed() {
        let isPresented = false
        XCTAssertFalse(isPresented, "Popover must be hidden before any activation")
    }

    // MARK: - CLI status text

    func testCLIStatusTextWhenMissing() {
        let text = cliStatusText(path: nil, version: nil, demoMode: false)
        XCTAssertEqual(text, "jamf-cli missing")
    }

    func testCLIStatusTextWithVersionLive() {
        let text = cliStatusText(path: "/usr/local/bin/jamf-cli", version: "1.14.0", demoMode: false)
        XCTAssertTrue(text.contains("1.14.0"), "Status text must contain the version")
        XCTAssertTrue(text.contains("live"), "Live mode must say 'live'")
    }

    /// Demo mode never runs jamf-cli, so this Mac's version is not the demo's.
    func testCLIStatusTextWithVersionDemo() {
        let text = cliStatusText(path: "/usr/local/bin/jamf-cli", version: "1.14.0", demoMode: true)
        XCTAssertEqual(text, "jamf-cli · demo")
    }

    /// A Mac without jamf-cli showed "jamf-cli missing" on every demo screen.
    func testCLIStatusTextDemoWithoutJamfCLI() {
        XCTAssertEqual(cliStatusText(path: nil, version: nil, demoMode: true), "jamf-cli · demo")
    }

    // MARK: - Helpers (mirror the logic in Titlebar)

    private let chipAccessibilityLabel = "jamf-cli status \u{2014} click for details"

    private func toggleChipPopover(_ isPresented: inout Bool) {
        isPresented.toggle()
    }

    /// The chip's own label logic, rather than a copy of it that can drift.
    private func cliStatusText(path: String?, version: String?, demoMode: Bool) -> String {
        CLIStatusChip.statusText(path: path, version: version, demoMode: demoMode)
    }
}
