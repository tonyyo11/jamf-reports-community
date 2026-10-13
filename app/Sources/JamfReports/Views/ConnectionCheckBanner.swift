import SwiftUI

/// The connection check's verdict, shown by onboarding's Validate step and the Update
/// credentials sheet.
struct ConnectionCheckBanner: View {
    let verdict: ConnectionCheck.Verdict
    /// Starts a Jamf School workspace; offered only for a verdict that suggests one.
    var onSetUpSchool: (() -> Void)?

    var body: some View {
        InlineBanner(
            icon: Self.icon(for: verdict), tone: Self.tone(for: verdict), action: schoolAction
        ) {
            Text(verbatim: verdict.message)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var schoolAction: InlineBannerAction? {
        guard verdict.suggestsJamfSchool, let onSetUpSchool else { return nil }
        return InlineBannerAction(
            label: "Set up Jamf School", icon: "graduationcap.fill", handler: onSetUpSchool
        )
    }

    nonisolated static func tone(for verdict: ConnectionCheck.Verdict) -> InlineBannerTone {
        switch verdict {
        case .accepted: .info
        case .rejectedID: .danger
        case .noJamfPro, .undecided: .warn
        }
    }

    nonisolated static func icon(for verdict: ConnectionCheck.Verdict) -> String {
        switch verdict {
        case .accepted: "checkmark.seal"
        case .rejectedID: "xmark.octagon.fill"
        case .noJamfPro, .undecided: "exclamationmark.triangle.fill"
        }
    }
}
