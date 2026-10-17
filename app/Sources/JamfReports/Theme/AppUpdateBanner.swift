import AppKit
import SwiftUI

/// The app-wide strip that reports a newer stable release. It links to the release page and
/// never downloads anything; Skip this version hides it until a later release.
struct AppUpdateBanner: View {
    let model: AppUpdateModel

    var body: some View {
        if let release = model.bannerRelease {
            InlineBanner(
                icon: "arrow.down.circle",
                tone: .info,
                action: InlineBannerAction(
                    label: "View release", icon: "arrow.up.right.square",
                    help: "Open the release notes on GitHub. Nothing is downloaded."
                ) { if let page = release.page { NSWorkspace.shared.open(page) } }
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Jamf Reports \(release.version) is available")
                        .font(.callout)
                        .foregroundStyle(InlineBannerTone.info.color)
                    HStack(spacing: 6) {
                        Text(Self.detail(current: AppVersionState.currentVersion))
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.fgMuted)
                        Button("Skip this version") { model.skip(release.version) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Hide this notice until a later release.")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    static func detail(current: String) -> String {
        "You have \(current). Read what changed, then update when it suits you."
    }
}
