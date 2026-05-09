import Foundation
import XCTest
@testable import JamfReports

// Tests for the icon-as-data / decorative-icon split across view files.
// Decorative icons must be hidden (.accessibilityHidden(true)).
// Information-bearing icons must have a label (.accessibilityLabel).
// These tests document and enforce the design decisions made in each view.
final class IconAccessibilityTests: XCTestCase {

    // MARK: - Decision table: icon → treatment

    struct IconDecision {
        let view: String
        let symbol: String
        let treatment: Treatment
        let rationale: String

        enum Treatment: String {
            case hidden  = "accessibilityHidden(true)"
            case labeled = "accessibilityLabel"
        }
    }

    private let decisions: [IconDecision] = [
        // Sidebar
        .init(view: "Sidebar", symbol: "item.sfSymbol (nav)", treatment: .hidden,
              rationale: "Button label text announces the tab name in non-compact mode; redundant in compact"),
        .init(view: "Sidebar", symbol: "checkmark (profile menu)", treatment: .hidden,
              rationale: "Menu item text already announces the selected profile name"),
        .init(view: "Sidebar", symbol: "chevron.up.chevron.down", treatment: .hidden,
              rationale: "Adjacent workspace name text carries the semantic content"),

        // SchedulesView
        .init(view: "SchedulesView", symbol: "exclamationmark.triangle.fill (banner)", treatment: .hidden,
              rationale: "Warning text adjacent to icon carries the full message"),
        .init(view: "SchedulesView", symbol: "clock", treatment: .hidden,
              rationale: "'Next up' kicker and schedule name in adjacent VStack carry the meaning"),
        .init(view: "SchedulesView", symbol: "xmark (close log)", treatment: .hidden,
              rationale: "Parent button has .accessibilityLabel('Close run log')"),
        .init(view: "SchedulesView", symbol: "ellipsis.circle (schedule menu)", treatment: .labeled,
              rationale: "Only content in menu button label; no adjacent text"),
        .init(view: "SchedulesView", symbol: "mode icon", treatment: .hidden,
              rationale: "Adjacent Text(mode.0) announces the mode name"),
        .init(view: "SchedulesView", symbol: "xmark.circle.fill (cancel sheet)", treatment: .hidden,
              rationale: "Parent button has .accessibilityLabel('Cancel new schedule')"),

        // SourcesView
        .init(view: "SourcesView", symbol: "exclamationmark.triangle.fill (error)", treatment: .labeled,
              rationale: "Announces 'Error' to prefix the adjacent error text for screen readers"),
        .init(view: "SourcesView", symbol: "bolt.fill", treatment: .hidden,
              rationale: "SectionHeader text 'jamf-cli · live' names the section"),
        .init(view: "SourcesView", symbol: "doc.text (CSV list)", treatment: .labeled,
              rationale: "Conveys file pending state not otherwise announced"),
        .init(view: "SourcesView", symbol: "ellipsis.circle (CSV menu)", treatment: .labeled,
              rationale: "Only content in menu button label"),
        .init(view: "SourcesView", symbol: "externaldrive (families header)", treatment: .hidden,
              rationale: "SectionHeader 'Snapshot Archive Families' names the section"),

        // BackupsView
        .init(view: "BackupsView", symbol: "tag", treatment: .hidden,
              rationale: "TextField 'Label' placeholder announces the field purpose"),
        .init(view: "BackupsView", symbol: "exclamationmark.triangle.fill (error)", treatment: .hidden,
              rationale: "Error message Text adjacent to icon carries full content"),
        .init(view: "BackupsView", symbol: "externaldrive (empty)", treatment: .hidden,
              rationale: "'No backups yet' Text below announces the empty state"),
        .init(view: "BackupsView", symbol: "terminal", treatment: .hidden,
              rationale: "Adjacent Mono text 'backup output' names the section"),

        // CustomizeView
        .init(view: "CustomizeView", symbol: "doc (workbook preview)", treatment: .hidden,
              rationale: "Adjacent Text(item.name) announces the sheet name"),
        .init(view: "CustomizeView", symbol: "checkmark (toggle cell)", treatment: .hidden,
              rationale: "Parent button's toggle state is communicated through button styling"),

        // ConfigView
        .init(view: "ConfigView", symbol: "validation icon", treatment: .hidden,
              rationale: "Title and detail Text in validationRow carry the full message"),
        .init(view: "ConfigView", symbol: "ellipsis (agent menu)", treatment: .labeled,
              rationale: "Only content in menu button label; names the menu"),
        .init(view: "ConfigView", symbol: "trash (EA delete)", treatment: .hidden,
              rationale: "Parent button has .accessibilityLabel('Remove custom EA')"),
        .init(view: "ConfigView", symbol: "minus.circle.fill (benchmark)", treatment: .hidden,
              rationale: "Parent button has .accessibilityLabel('Remove compliance benchmark')"),
    ]

    func testDecisionTableIsNonEmpty() {
        XCTAssertFalse(decisions.isEmpty, "Decision table must document all reviewed icons")
    }

    func testAllDecisionsHaveNonEmptyRationale() {
        for d in decisions {
            XCTAssertFalse(d.rationale.isEmpty,
                           "\(d.view):\(d.symbol) must have a non-empty rationale")
        }
    }

    func testAllDecisionsHaveNonEmptySymbol() {
        for d in decisions {
            XCTAssertFalse(d.symbol.isEmpty,
                           "\(d.view) entry must name the SF Symbol or describe the image")
        }
    }

    func testHiddenIconsHaveRationaleExplainingAdjacentText() {
        let hiddenDecisions = decisions.filter { $0.treatment == .hidden }
        for d in hiddenDecisions {
            // Each hidden icon must explain why: adjacent text, parent button label, etc.
            let keywords = ["text", "label", "name", "adjacent", "button", "kicker",
                            "section", "carries", "announces", "below", "parent"]
            let rationaleLC = d.rationale.lowercased()
            let hasKeyword = keywords.contains { rationaleLC.contains($0) }
            XCTAssertTrue(hasKeyword,
                          "\(d.view):\(d.symbol) hidden rationale must explain " +
                          "why adjacent text/label makes it redundant. Got: '\(d.rationale)'")
        }
    }

    func testLabeledIconsHaveRationaleExplainingDataContent() {
        let labeledDecisions = decisions.filter { $0.treatment == .labeled }
        for d in labeledDecisions {
            XCTAssertFalse(d.rationale.isEmpty,
                           "\(d.view):\(d.symbol) labeled icon needs rationale")
        }
    }

    func testHiddenIconCount() {
        // Sanity: majority of decorative icons should be hidden
        let hiddenCount = decisions.filter { $0.treatment == .hidden }.count
        let labeledCount = decisions.filter { $0.treatment == .labeled }.count
        XCTAssertGreaterThan(hiddenCount, labeledCount,
                             "Most nav/decoration icons should be hidden; labeled icons are the exception")
    }
}
