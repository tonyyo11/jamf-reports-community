import AppKit
import Testing
@testable import JamfReports

/// The sidebar is a fixed 232 pt and its labels are one line, so a long translation is cut off
/// with "…" (seen in the 2.12.0-rc1 VM pass). The page layout test does not reach the sidebar.
struct LocalizationSidebarWidthTests {
    /// 232 sidebar - 0.5 hairline - 2×8 list inset - 2×10 row inset - 16 icon - 9 + 9 stack
    /// spacing - 4 spacer - 15 legacy scroller (a Mac with a mouse), in `Sidebar.navItem`.
    static let textWidth: CGFloat = 142.5
    /// The row's badge (mono 10 pt, two digits, 12 pt inset) and the spacing before it.
    static let badgeWidth: CGFloat = 35
    /// `Sidebar.navItem` lets a label shrink to 0.9 before it truncates.
    static let minimumScale: CGFloat = 0.9
    static let badgedTabs: Set<Tab> = [.trends, .reports, .schedules]

    @MainActor
    @Test func everySidebarLabelFitsInEveryLanguage() {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let values = Dictionary(
            LocalizationCatalogTests.catalog.map { ($0.key, $0.units) },
            uniquingKeysWith: { first, _ in first }
        )
        var tooWide: [String] = []
        for tab in Tab.allCases {
            let key = Localization.english { tab.label }
            let budget = (Self.textWidth - (Self.badgedTabs.contains(tab) ? Self.badgeWidth : 0))
                / Self.minimumScale
            var texts = [("en", key)]
            for language in LocalizationCatalogTests.languages {
                if let value = values[key]?[language]?.first?.value { texts.append((language, value)) }
            }
            for (language, text) in texts {
                let width = (text as NSString).size(withAttributes: [.font: font]).width
                if width > budget {
                    tooWide.append("\(language) \"\(text)\" \(Int(width.rounded())) > \(Int(budget))")
                }
            }
        }
        #expect(tooWide.isEmpty, "\(tooWide.count): \(tooWide)")
    }
}
