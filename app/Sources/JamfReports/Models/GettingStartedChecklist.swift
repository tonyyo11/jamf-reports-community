/// Pure model for the "Getting started" checklist shown on Overview.
/// All state is derived from real artifacts — no stored progress flag.

struct GettingStartedStep: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case connect, collect, customize, schedule, report
    }

    let kind: Kind
    let title: String
    /// One-line "why this matters / what to do next".
    let detail: String
    let done: Bool
    /// CTA label shown on the first incomplete step.
    let actionLabel: String
    /// Raw value of the `Tab` to route to when the CTA is tapped.
    let destinationTab: String
    /// True for a step that isn't required for `GettingStartedChecklist.isComplete`
    /// (e.g. Extension Attribute tracking — jamf-cli data alone is enough for most dashboards).
    var isOptional: Bool = false

    var id: String { kind.rawValue }
}

struct GettingStartedChecklist: Sendable, Equatable {
    let steps: [GettingStartedStep]

    /// Ignores optional steps — a workspace with nothing but jamf-cli data
    /// can still finish the checklist.
    var isComplete: Bool { steps.filter { !$0.isOptional }.allSatisfy(\.done) }
    var firstIncomplete: GettingStartedStep? { steps.first { !$0.done } }
    var completedCount: Int { steps.filter(\.done).count }

    /// Build the checklist from the five derived booleans.
    /// - Parameters:
    ///   - connected: At least one jamf-cli profile is configured.
    ///   - collected: At least one trend summary file exists.
    ///   - customized: config.yaml tracks at least one custom EA or security agent.
    ///   - scheduled: A hand-built schedule or managed automation covers this profile.
    ///   - reported: At least one generated report file exists.
    static func build(
        connected: Bool,
        collected: Bool,
        customized: Bool,
        scheduled: Bool,
        reported: Bool
    ) -> GettingStartedChecklist {
        let steps: [GettingStartedStep] = [
            GettingStartedStep(
                kind: .connect,
                title: L("Connect to Jamf"),
                detail: L("Authenticate jamf-cli so the app can pull live fleet data."),
                done: connected,
                actionLabel: L("Go to Sources"),
                destinationTab: Tab.sources.rawValue
            ),
            GettingStartedStep(
                kind: .collect,
                title: L("Run your first collect"),
                detail: L("Pull a snapshot from Jamf Pro to populate dashboards."),
                done: collected,
                actionLabel: L("Collect now"),
                destinationTab: Tab.sources.rawValue
            ),
            GettingStartedStep(
                kind: .customize,
                title: L("Track your Extension Attributes"),
                detail: L("Pick the collected Extension Attributes and agents to report on. Optional — jamf-cli data alone covers most dashboards."),
                done: customized,
                actionLabel: L("Open Data Sources"),
                destinationTab: Tab.sources.rawValue,
                isOptional: true
            ),
            GettingStartedStep(
                kind: .schedule,
                title: L("Set up a schedule"),
                detail: L("Automate daily collects so dashboards stay current."),
                done: scheduled,
                actionLabel: L("Set up automation"),
                destinationTab: Tab.schedules.rawValue
            ),
            GettingStartedStep(
                kind: .report,
                title: L("Generate a report"),
                detail: L("Export a workbook or HTML report to share with your team."),
                done: reported,
                actionLabel: L("Generate report"),
                destinationTab: Tab.reports.rawValue
            ),
        ]
        return GettingStartedChecklist(steps: steps)
    }
    /// The Jamf School checklist: School has no Extension Attributes, so there is no
    /// customize step, and the collect step is done once any School snapshot exists.
    static func buildSchool(
        connected: Bool, collected: Bool, scheduled: Bool, reported: Bool
    ) -> GettingStartedChecklist {
        let pro = build(connected: connected, collected: collected, customized: false,
                        scheduled: scheduled, reported: reported)
        let steps = pro.steps.compactMap { step -> GettingStartedStep? in
            switch step.kind {
            case .customize: return nil
            case .connect:
                return step.with(detail: L("Authenticate jamf-cli with your Jamf School API key."))
            case .collect:
                return step.with(detail: L("Pull a snapshot from Jamf School to list its devices."))
            case .schedule, .report: return step
            }
        }
        return GettingStartedChecklist(steps: steps)
    }
}

extension GettingStartedStep {
    func with(detail: String) -> GettingStartedStep {
        GettingStartedStep(kind: kind, title: title, detail: detail, done: done,
                           actionLabel: actionLabel, destinationTab: destinationTab,
                           isOptional: isOptional)
    }
}
