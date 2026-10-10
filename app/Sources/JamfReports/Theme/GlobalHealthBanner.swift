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
    /// Shared-config keys waiting for a Confirm on this Mac (`SharedConfigPin`).
    var sharedConfigKeys: [String] = []
    /// Opens the Automation screen, where the detail and the manual controls are.
    let onOpenAutomation: () -> Void
    /// Force-collects the tiers behind the freshness issues. Optional so a
    /// caller with no collect context keeps the informational banner.
    var onCollectNow: (() -> Void)?
    /// Opens Audit on its Config Doctor segment, where the Confirm button is.
    var onOpenConfigDoctor: (() -> Void)?

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
            freshness: freshnessIssues, automation: automationIssues,
            sharedConfig: sharedConfigKeys
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
            freshness: freshnessIssues, canCollect: onCollectNow != nil,
            sharedConfig: sharedConfigKeys
        ) {
        case .openConfigDoctor:
            return InlineBannerAction(
                label: PrimaryAction.openConfigDoctor.label,
                icon: "stethoscope",
                help: "Review the values another Mac changed in the shared config.yaml",
                handler: onOpenConfigDoctor ?? onOpenAutomation
            )
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
        case openConfigDoctor

        var label: String {
            switch self {
            case .openConfigDoctor: return "Review"
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
        canCollect: Bool,
        sharedConfig: [String] = []
    ) -> PrimaryAction {
        // The shared-config entry ranks below failing kinds, so the button follows the headline.
        if !sharedConfig.isEmpty, !freshness.contains(where: { $0.kind == .failing }) {
            return .openConfigDoctor
        }
        return (canCollect && !freshness.isEmpty) ? .collectNow : .openAutomation
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
    /// Kinds never attempted on this workspace rank below genuinely stale ones
    /// and read as information, not alarm — but still above schedule issues,
    /// because any freshness issue is what makes the button "Collect now".
    ///
    /// `nonisolated` because `View` conformance MainActor-isolates statics on
    /// Swift 6.1, which would break nonisolated test callers.
    nonisolated static func headline(
        freshness: [DataFreshnessIssue],
        automation: [AutomationHealthIssue],
        sharedConfig: [String] = []
    ) -> Headline? {
        let failing = freshness.filter { $0.kind == .failing }
        let stale = freshness.filter { $0.kind == .stale && !$0.neverCollected }
        let neverCollected = freshness.filter { $0.kind == .stale && $0.neverCollected }

        if !failing.isEmpty {
            return Headline(
                icon: "exclamationmark.triangle.fill",
                tone: .danger,
                text: countPhrase(failing.count, "data source") + " failing to collect",
                detail: kindList(failing) + " — " + failingReason(failing)
            )
        }
        // Below failing collects, above everything else: background runs on this Mac are using
        // safe values (a default report folder, no webhook) until it is confirmed.
        if !sharedConfig.isEmpty {
            let named = sharedConfig.prefix(maxNamedKinds).joined(separator: ", ")
            let extra = sharedConfig.count - min(sharedConfig.count, maxNamedKinds)
            return Headline(
                icon: "lock.trianglebadge.exclamationmark",
                tone: .warn,
                text: "Shared config needs confirming on this Mac",
                detail: named + (extra > 0 ? " +\(extra) more" : "")
                    + " — background runs use safe values until you confirm"
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
        if !neverCollected.isEmpty {
            return Headline(
                icon: "clock",
                tone: .info,
                text: countPhrase(neverCollected.count, "data source") + " not collected yet",
                detail: kindList(neverCollected) + " — not attempted yet on this workspace"
            )
        }
        // A disabled background item is not a run that failed: nothing was allowed to run.
        if automation.contains(where: { $0.kind == .tickerDisabled }) {
            return Headline(
                icon: "calendar.badge.exclamationmark",
                tone: .warn,
                text: "Automation is off",
                detail: "JamfReports is not allowed to run in the background"
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

    /// The cause when every failing kind recorded the same one (spec §10.1), with the
    /// permission names for a missing permission; otherwise the general wording.
    nonisolated static func failingReason(_ failing: [DataFreshnessIssue]) -> String {
        let causes = failing.compactMap(\.cause)
        guard causes.count == failing.count, let first = causes.first, first.kind != .other,
              causes.allSatisfy({ $0.kind == first.kind }) else {
            return "data on screens using " + (failing.count == 1 ? "it" : "them")
                + " is out of date"
        }
        guard first.kind == .missingPermission else { return first.label }
        var seen: Set<String> = []
        let names = causes.flatMap(\.names).filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return first.label }
        let extra = names.count - min(names.count, maxNamedKinds)
        return "missing permission: " + names.prefix(maxNamedKinds).joined(separator: "; ")
            + (extra > 0 ? " +\(extra) more" : "")
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
