import SwiftUI

/// The "Getting started" card above the Overview for new users (Jamf Pro and Jamf School).
/// The caller hides it once every required step is done; `onAction` runs the active step's
/// button.
struct GettingStartedCard: View {
    let checklist: GettingStartedChecklist
    let onAction: (GettingStartedStep) -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Kicker(
                        text: L("Getting started — \(checklist.completedCount) of \(checklist.steps.count)"),
                        tone: checklist.completedCount > 0 ? .teal : .muted
                    )
                    Spacer(minLength: 8)
                }
                ForEach(checklist.steps) { step in
                    row(step, isActive: checklist.firstIncomplete?.id == step.id)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ step: GettingStartedStep, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The button is outside the combined element so VoiceOver can activate it.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            step.done ? Theme.Colors.ok : Theme.Text.tertiary(contrast)
                        )
                        .accessibilityHidden(true)
                    Text(step.title)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(
                            step.done ? Theme.Text.tertiary(contrast) : Theme.Colors.fg
                        )
                        .strikethrough(step.done, color: Theme.Text.tertiary(contrast))
                }
                if !step.done {
                    Text(step.detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .padding(.leading, 24)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(step.title): \(step.done ? "complete" : "incomplete"). "
                    + (step.done ? "" : step.detail)
            )
            if isActive {
                PNPButton(title: step.actionLabel, style: .gold, size: .sm) {
                    onAction(step)
                }
                .padding(.leading, 24)
                .padding(.top, 2)
            }
        }
    }
}
