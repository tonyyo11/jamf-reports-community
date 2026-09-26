import Testing
@testable import JamfReports

/// The Config tab strip falls back to `shortLabel` when the full labels do not fit,
/// so every short label must still name its tab and tell it apart from the others.
struct ConfigTabLabelTests {

    @Test func everyShortLabelIsNonEmpty() {
        for tab in ConfigView.ConfigTab.allCases {
            #expect(!tab.shortLabel.trimmingCharacters(in: .whitespaces).isEmpty, "\(tab)")
        }
    }

    @Test func shortLabelsAreDistinct() {
        let labels = ConfigView.ConfigTab.allCases.map(\.shortLabel)
        #expect(Set(labels).count == labels.count)
    }

    @Test func noShortLabelIsLongerThanItsFullLabel() {
        for tab in ConfigView.ConfigTab.allCases {
            #expect(tab.shortLabel.count <= tab.label.count, "\(tab)")
        }
    }
}
