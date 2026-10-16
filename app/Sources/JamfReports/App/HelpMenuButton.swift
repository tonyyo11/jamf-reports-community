import SwiftUI

/// "Jamf Reports Help" in the Help menu. The bundle has no Help Book, so the system item
/// only said help was unavailable; the user guide is the project wiki (#292).
struct HelpMenuButton: View {
    @Environment(\.openURL) private var openURL

    static let wikiURL = URL(
        string: "https://github.com/tonyyo11/jamf-reports-community/wiki"
    )!

    var body: some View {
        Button("Jamf Reports Help") {
            openURL(Self.wikiURL)
        }
        .keyboardShortcut("?", modifiers: .command)
    }
}
