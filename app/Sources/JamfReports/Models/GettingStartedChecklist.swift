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

    var id: String { kind.rawValue }
}

struct GettingStartedChecklist: Sendable, Equatable {
    let steps: [GettingStartedStep]

    var isComplete: Bool { steps.allSatisfy(\.done) }
    var firstIncomplete: GettingStartedStep? { steps.first { !$0.done } }
    var completedCount: Int { steps.filter(\.done).count }

    /// Build the checklist from the five derived booleans.
    /// - Parameters:
    ///   - connected: At least one jamf-cli profile is configured.
    ///   - collected: At least one trend summary file exists.
    ///   - customized: config.yaml contains at least one column mapping.
    ///   - scheduled: A LaunchAgent or managed automation is active.
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
                title: "Connect to Jamf",
                detail: "Authenticate jamf-cli so the app can pull live fleet data.",
                done: connected,
                actionLabel: "Go to Sources",
                destinationTab: Tab.sources.rawValue
            ),
            GettingStartedStep(
                kind: .collect,
                title: "Run your first collect",
                detail: "Pull a snapshot from Jamf Pro to populate dashboards.",
                done: collected,
                actionLabel: "Collect now",
                destinationTab: Tab.sources.rawValue
            ),
            GettingStartedStep(
                kind: .customize,
                title: "Map your columns",
                detail: "Tell the app which CSV columns match your Jamf field names.",
                done: customized,
                actionLabel: "Open Config",
                destinationTab: Tab.config.rawValue
            ),
            GettingStartedStep(
                kind: .schedule,
                title: "Set up a schedule",
                detail: "Automate daily collects so dashboards stay current.",
                done: scheduled,
                actionLabel: "Set up automation",
                destinationTab: Tab.schedules.rawValue
            ),
            GettingStartedStep(
                kind: .report,
                title: "Generate a report",
                detail: "Export a workbook or HTML report to share with your team.",
                done: reported,
                actionLabel: "Generate report",
                destinationTab: Tab.reports.rawValue
            ),
        ]
        return GettingStartedChecklist(steps: steps)
    }
}
