import SwiftUI

/// App-wide health strip rendered above every screen in `ContentView.shell`.
///
/// The pre-2.8 signals were all local: the automation dead-man banner lived on
/// Overview, per-kind freshness chips lived on the screen that read that kind,
/// and a failed run was only visible on Run History. An operator working on
/// Patch Compliance had no way to learn that `security` had stopped landing 35
/// days ago. This strip is the one surface that follows them.
///
/// Ordering is worst-first: failing kinds (a known, reproducing error) above
/// stale kinds (a symptom), above schedule issues (which the existing Overview
/// banner and Automation card already cover in more detail).
struct GlobalHealthBanner: View {
    let freshnessIssues: [DataFreshnessIssue]
    let automationIssues: [AutomationHealthIssue]
    let isRemediating: Bool
    /// Opens the Automation screen, where the detail and the manual controls are.
    let onOpenAutomation: () -> Void
    /// Force-collects the tiers behind the freshness issues. Optional so a
    /// caller with no collect context keeps the informational banner.
    var onCollectNow: (() -> Void)?

    var body: some View {
        if isRemediating {
            banner(
                icon: "arrow.triangle.2.circlepath",
                tone: .info,
                text: "Re-collecting stale data…",
                detail: nil,
                action: nil
            )
        } else if let headline = Self.headline(
            freshness: freshnessIssues, automation: automationIssues
        ) {
            banner(
                icon: headline.icon,
                tone: headline.tone,
                text: headline.text,
                detail: headline.detail,
                action: bannerAction()
            )
        }
    }

    /// `InlineBanner` renders one button, so the strip offers the action that
    /// resolves what it is complaining about rather than two competing ones.
    private func bannerAction() -> InlineBannerAction {
        switch Self.primaryAction(
            freshness: freshnessIssues, canCollect: onCollectNow != nil
        ) {
        case .collectNow:
            return InlineBannerAction(
                label: PrimaryAction.collectNow.label,
                icon: "arrow.clockwise",
                help: "Collect the data sources that are behind",
                handler: onCollectNow ?? onOpenAutomation
            )
        case .openAutomation:
            return InlineBannerAction(
                label: PrimaryAction.openAutomation.label,
                icon: "gearshape.2",
                handler: onOpenAutomation
            )
        }
    }

    private func banner(
        icon: String,
        tone: InlineBannerTone,
        text: String,
        detail: String?,
        action: InlineBannerAction?
    ) -> some View {
        InlineBanner(icon: icon, tone: tone, action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(tone.color)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pure action derivation

    enum PrimaryAction: Equatable {
        case collectNow
        case openAutomation

        var label: String {
            switch self {
            case .collectNow: return "Collect now"
            case .openAutomation: return "Open Automation"
            }
        }
    }

    /// A red strip whose only button opened a screen with no re-collect
    /// control was a dead end, so anything the operator can fix by collecting
    /// offers the collect. Schedule-only issues still route to Automation,
    /// which is where the fix for those lives.
    ///
    /// `nonisolated` for the same reason as `headline`.
    nonisolated static func primaryAction(
        freshness: [DataFreshnessIssue],
        canCollect: Bool
    ) -> PrimaryAction {
        (canCollect && !freshness.isEmpty) ? .collectNow : .openAutomation
    }

    // MARK: - Pure headline derivation

    struct Headline: Equatable {
        let icon: String
        let tone: InlineBannerTone
        let text: String
        let detail: String?
    }

    /// One line summarising the worst thing currently wrong, plus a detail line
    /// naming the specific kinds. Returns nil when everything is healthy.
    ///
    /// `nonisolated` because `View` conformance MainActor-isolates statics on
    /// Swift 6.1, which would break nonisolated test callers.
    nonisolated static func headline(
        freshness: [DataFreshnessIssue],
        automation: [AutomationHealthIssue]
    ) -> Headline? {
        let failing = freshness.filter { $0.kind == .failing }
        let stale = freshness.filter { $0.kind == .stale }

        if !failing.isEmpty {
            return Headline(
                icon: "exclamationmark.triangle.fill",
                tone: .danger,
                text: countPhrase(failing.count, "data source") + " failing to collect",
                detail: kindList(failing) + " — data on screens using "
                    + (failing.count == 1 ? "it" : "them") + " is out of date"
            )
        }
        if !stale.isEmpty {
            return Headline(
                icon: "clock.badge.exclamationmark",
                tone: .warn,
                text: countPhrase(stale.count, "data source") + " far behind schedule",
                detail: kindList(stale) + " — a re-scan is needed"
            )
        }
        if !automation.isEmpty {
            let overdue = automation.filter { $0.kind == .overdue }.count
            let failed = automation.count - overdue
            let text = overdue > 0
                ? countPhrase(overdue, "scheduled run") + " overdue"
                : countPhrase(failed, "scheduled run") + " failing"
            return Headline(
                icon: "calendar.badge.exclamationmark",
                tone: .warn,
                text: text,
                detail: automation.prefix(3).map(\.displayName).joined(separator: ", ")
            )
        }
        return nil
    }

    nonisolated private static func countPhrase(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun) is" : "\(n) \(noun)s are"
    }

    /// How many kinds the detail line names before collapsing to "+N more".
    /// One constant, because the name list and the overflow count have to agree:
    /// duplicating the number let a mutation list every kind AND still claim
    /// "+2 more".
    nonisolated static let maxNamedKinds = 3

    /// Name at most `maxNamedKinds` kinds, then "+N more" — a fleet with twenty
    /// broken kinds must not push the banner into a wall of text.
    nonisolated private static func kindList(_ issues: [DataFreshnessIssue]) -> String {
        let named = issues.prefix(maxNamedKinds).map(\.snapshotKind)
        let names = named.joined(separator: ", ")
        let extra = issues.count - named.count
        return extra > 0 ? "\(names) +\(extra) more" : names
    }
}
