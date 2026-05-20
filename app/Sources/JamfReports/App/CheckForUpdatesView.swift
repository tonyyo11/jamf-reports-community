import SwiftUI

/// "Check for Updates…" menu item.
///
/// The app has no built-in auto-updater — signed, notarized builds are
/// published on GitHub Releases. This opens that page in the default browser
/// so the user can download the latest version.
struct CheckForUpdatesView: View {
    @Environment(\.openURL) private var openURL

    private static let releasesURL = URL(
        string: "https://github.com/tonyyo11/jamf-reports-community/releases"
    )!

    var body: some View {
        Button("Check for Updates on GitHub…") {
            openURL(Self.releasesURL)
        }
    }
}
