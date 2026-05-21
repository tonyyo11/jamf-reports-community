import SwiftUI
import AppKit

/// Reusable destructive-action sheet: `pro sg apply` template → group in Jamf Pro.
///
/// **Trust-boundary surface.** This is the only place in the GUI that writes to
/// the Jamf tenant. The flow is intentionally preview-first, confirm-explicit:
///
///   1. Sheet opens → service.preview() fetches the criteria JSON + estimated count
///   2. User reviews the JSON and the auto-populated name (editable)
///   3. User taps "Create in Jamf Pro" → service.apply() runs
///   4. Success card with member count + "Reveal in Jamf Pro" link, or
///   5. Error card with retry/dismiss
///
/// No "skip preview" path. Per the operator-UX choice locked at Stage 2 kickoff,
/// preview is always shown so a misconfigured template can't quietly land in the
/// tenant. The cost is one extra tap; the safety win is the criteria JSON is
/// auditable before any write happens.

// MARK: - View-model

/// Drives `SmartGroupApplySheet`. Separated from the View so the state machine is
/// independently testable without rendering.
@Observable
@MainActor
final class SmartGroupApplySheetViewModel {

    enum Phase: Equatable {
        case loadingPreview
        case previewReady(SmartGroupPreview)
        case previewFailed(String)
        case applying
        case applied(SmartGroupApplyResult)
        case applyFailed(SmartGroupPreview, String)
    }

    let template: SmartGroupTemplate
    let profile: String

    /// Editable smart-group name. Pre-populated from the template's default
    /// name pattern; user can edit before confirming.
    var smartGroupName: String

    /// Optional parameter values keyed by `ParamSpec.name`. Pre-populated with
    /// the template's defaults; required parameters without defaults must be
    /// filled before the Create button enables.
    var paramValues: [String: String]

    /// Current phase of the state machine. Bound by SwiftUI so view updates auto.
    private(set) var phase: Phase = .loadingPreview

    private let templateService: SmartGroupTemplateService
    private let applyService: SmartGroupApplyService

    init(
        template: SmartGroupTemplate,
        profile: String,
        templateService: SmartGroupTemplateService,
        applyService: SmartGroupApplyService,
        suggestedName: String? = nil
    ) {
        self.template = template
        self.profile = profile
        self.templateService = templateService
        self.applyService = applyService
        self.smartGroupName = suggestedName ?? Self.defaultName(for: template)
        var defaults: [String: String] = [:]
        for param in template.params {
            if let value = param.default {
                defaults[param.name] = value
            }
        }
        self.paramValues = defaults
    }

    /// Whether the Create button should be enabled. Requires (a) a non-empty
    /// name, (b) every required parameter populated, and (c) the sheet to be in
    /// a phase where applying is meaningful (previewReady or applyFailed).
    var canApply: Bool {
        guard !smartGroupName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        for param in template.params where param.required {
            let value = paramValues[param.name]?.trimmingCharacters(in: .whitespaces) ?? ""
            if value.isEmpty { return false }
        }
        switch phase {
        case .previewReady, .applyFailed: return true
        default: return false
        }
    }

    /// Phase 1 → loadingPreview → previewReady/previewFailed. Called on sheet appear.
    func loadPreview() async {
        phase = .loadingPreview
        do {
            let preview = try await templateService.preview(
                profile: profile,
                templateSlug: template.slug,
                params: paramValues
            )
            phase = .previewReady(preview)
        } catch let SmartGroupTemplateServiceError.executionFailed(_, stderr) {
            phase = .previewFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let SmartGroupTemplateServiceError.unknownTemplate(message) {
            phase = .previewFailed("Unknown template: \(message)")
        } catch SmartGroupTemplateServiceError.featureNotAvailable {
            phase = .previewFailed(
                "jamf-cli is missing the smart-group templates command. "
                + "This feature is pending merge of Jamf-Concepts/jamf-cli PR #205 — "
                + "watch the project for the next release that includes it."
            )
        } catch {
            phase = .previewFailed(String(describing: error))
        }
    }

    /// Phase 2 → applying → applied/applyFailed. Called when user taps Create.
    func apply() async {
        // Keep the preview around so applyFailed can re-show the JSON the user
        // approved — they shouldn't lose context just because the API rejected.
        guard let preview = currentPreview else { return }
        guard canApply else { return }
        phase = .applying
        do {
            let result = try await applyService.apply(
                profile: profile,
                templateSlug: template.slug,
                smartGroupName: smartGroupName.trimmingCharacters(in: .whitespaces),
                params: paramValues
            )
            phase = .applied(result)
        } catch let SmartGroupApplyError.apiError(status, message) {
            phase = .applyFailed(preview, "Jamf Pro returned HTTP \(status): \(message)")
        } catch let SmartGroupApplyError.networkFailure(detail) {
            phase = .applyFailed(preview, "Network error: \(detail)")
        } catch SmartGroupApplyError.featureNotAvailable {
            phase = .applyFailed(
                preview,
                "jamf-cli is missing the smart-group apply command. "
                + "This feature is pending merge of Jamf-Concepts/jamf-cli PR #205 — "
                + "watch the project for the next release that includes it."
            )
        } catch let SmartGroupApplyError.unexpectedOutput(stderr) {
            phase = .applyFailed(preview, "Unexpected jamf-cli output:\n\(stderr)")
        } catch let SmartGroupApplyError.executionFailed(code, stderr) {
            phase = .applyFailed(preview, "jamf-cli exited \(code):\n\(stderr)")
        } catch {
            phase = .applyFailed(preview, String(describing: error))
        }
    }

    /// The currently-loaded preview, if any. Used by `apply` to anchor the
    /// applyFailed state back to the same JSON the user just approved.
    private var currentPreview: SmartGroupPreview? {
        switch phase {
        case .previewReady(let preview), .applyFailed(let preview, _):
            return preview
        default:
            return nil
        }
    }

    /// Generates a sensible default group name from a template's slug.
    /// PR #205 slugs follow the shape `<category>/<name>` (e.g. `encryption/not-encrypted`);
    /// we strip the category prefix and Title Case the rest.
    /// Examples:
    ///   "encryption/not-encrypted" → "Not Encrypted (Jamf Reports)"
    ///   "mdm/stale-checkin"        → "Stale Checkin (Jamf Reports)"
    ///   "" (degenerate)            → "Smart Group (Jamf Reports)"
    static func defaultName(for template: SmartGroupTemplate) -> String {
        let suffix = " (Jamf Reports)"
        // Strip the category prefix if present — the leaf is the human-meaningful piece.
        let leaf = template.slug.split(separator: "/").last.map(String.init) ?? template.slug
        let cleaned = leaf
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
        // Guard the degenerate "" slug case so we never produce a name like " (Jamf Reports)".
        let label = cleaned.isEmpty ? "Smart Group" : cleaned
        return label + suffix
    }
}

// MARK: - SwiftUI view

struct SmartGroupApplySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @Bindable var viewModel: SmartGroupApplySheetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content.padding(20)
            }
            Divider()
            actionBar
        }
        .frame(width: 560, height: 520)
        .task { await viewModel.loadPreview() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.plus")
                .foregroundStyle(Theme.Colors.gold)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Mono(text: "Smart Group · \(viewModel.template.category)", size: 10.5)
                Text(viewModel.template.description.isEmpty
                     ? viewModel.template.slug
                     : viewModel.template.description)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Phase-driven content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loadingPreview:
            loadingBlock(message: "Loading preview from jamf-cli…")
        case .previewReady(let preview):
            previewBlock(preview)
        case .previewFailed(let message):
            errorBlock(title: "Could not load preview", detail: message)
        case .applying:
            loadingBlock(message: "Creating smart group in Jamf Pro…")
        case .applied(let result):
            successBlock(result: result)
        case .applyFailed(let preview, let message):
            VStack(alignment: .leading, spacing: 16) {
                errorBlock(title: "Apply failed", detail: message)
                previewBlock(preview)
            }
        }
    }

    private func loadingBlock(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.7)
                Text(message).font(.callout).foregroundStyle(Theme.Colors.fg2)
            }
        }
    }

    @ViewBuilder
    private func previewBlock(_ preview: SmartGroupPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            nameAndParamsForm
            if let count = preview.estimatedMatchCount {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(Theme.Colors.fgMuted)
                    Text("Estimated match: \(count) device\(count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.fg2)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Criteria preview (read-only)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                ScrollView {
                    Text(preview.bodyJSON)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.fg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 200)
                .background(Theme.Colors.codeBG, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private var nameAndParamsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Smart group name").font(.caption.weight(.medium)).foregroundStyle(Theme.Text.tertiary(contrast))
                TextField("Smart group name", text: $viewModel.smartGroupName)
                    .textFieldStyle(.roundedBorder)
            }
            ForEach(viewModel.template.params, id: \.name) { param in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(param.name).font(.caption.weight(.medium)).foregroundStyle(Theme.Text.tertiary(contrast))
                        if param.required {
                            Text("*").foregroundStyle(Theme.Colors.danger).font(.caption.weight(.bold))
                        }
                    }
                    TextField(param.description, text: paramBinding(for: param.name))
                        .textFieldStyle(.roundedBorder)
                    if !param.description.isEmpty {
                        Text(param.description).font(.caption2).foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                }
            }
        }
    }

    private func paramBinding(for name: String) -> Binding<String> {
        Binding(
            get: { viewModel.paramValues[name] ?? "" },
            set: { viewModel.paramValues[name] = $0 }
        )
    }

    @ViewBuilder
    private func successBlock(result: SmartGroupApplyResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.ok)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.created ? "Smart group created" : "Smart group updated")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Text(result.name).font(.footnote).foregroundStyle(Theme.Colors.fg2)
                }
                Spacer()
            }
            if let count = result.memberCount {
                Text("\(count) device\(count == 1 ? "" : "s") match the criteria.")
                    .font(.callout).foregroundStyle(Theme.Colors.fg2)
            } else {
                Text("Membership count not available — refresh the smart group in Jamf Pro.")
                    .font(.callout).foregroundStyle(Theme.Text.tertiary(contrast))
            }
            if let consoleURL = workspace.consoleURL(forComputerGroupID: result.smartGroupID, isStatic: false) {
                Link(destination: consoleURL) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Reveal in Jamf Pro")
                    }
                    .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func errorBlock(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.danger)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(Theme.Colors.fg)
                Text(detail).font(.footnote).foregroundStyle(Theme.Colors.fg2).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Theme.Colors.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.Colors.danger.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Action bar

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            Spacer()
            switch viewModel.phase {
            case .applied:
                PNPButton(title: "Done", icon: "checkmark") { dismiss() }
            case .previewFailed:
                PNPButton(title: "Close", icon: "xmark") { dismiss() }
            default:
                PNPButton(title: "Cancel", icon: "xmark") { dismiss() }
                PNPButton(title: "Create in Jamf Pro", icon: "plus.circle.fill") {
                    Task { await viewModel.apply() }
                }
                .disabled(!viewModel.canApply)
                .help(viewModel.canApply
                      ? "Submit the smart group to Jamf Pro"
                      : "Fill required fields before submitting")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
