import SwiftUI

/// The connection check's verdict, shown by onboarding's Validate step and the Update
/// credentials sheet.
struct ConnectionCheckBanner: View {
    let verdict: ConnectionCheck.Verdict

    var body: some View {
        InlineBanner(icon: Self.icon(for: verdict), tone: Self.tone(for: verdict)) {
            Text(verbatim: verdict.message)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
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
