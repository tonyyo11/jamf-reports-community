import SwiftUI
import AppKit
import Combine

// GenerateOutputType is defined in Models/Models.swift.

// MARK: - Sheet state (extracted for testability)

/// Observable model backing GenerateSheet. Extracted so it can be unit-tested
/// without instantiating a SwiftUI view.
@MainActor
@Observable
final class GenerateSheetState {
    var selectedTypes: Set<GenerateOutputType> = [.xlsx]
    var collectFresh: Bool = true
    /// When true, run a Health Audit before generating so audit-derived
    /// workbook content reflects this run. Persisted via the same UserDefaults
    /// key OverviewView's quick "Generate Report" button reads, so the
    /// preference applies consistently to both generate flows.
    var includeAudit: Bool = UserDefaults.standard.bool(forKey: GenerateSheetState.includeAuditKey) {
        didSet { UserDefaults.standard.set(includeAudit, forKey: GenerateSheetState.includeAuditKey) }
    }
    nonisolated static let includeAuditKey = "includeAuditInGenerate"
    var customOutputDir: URL? = nil
    var folderPickerError: String? = nil
    var logLines: [CLIBridge.LogLine] = []
    var isRunning: Bool = false
    var completedCount: Int = 0
    var completedFiles: [URL] = []
    var errorMessage: String? = nil

    /// T-13 integrity envelope: hashes captured from the run log, keyed by
    /// artifact basename. Populated by `appendLine` when it sees a sentinel
    /// `[ok] sha256: <64hex> <basename>` line emitted by the engine.
    /// Surfaced in the completion banner and exposed to copy-to-clipboard.
    var generatedHashes: [String: String] = [:]

    /// Identifier of the currently selected report template.
    /// Kept for the sheet's lifetime; each open starts on Full Instance.
    var selectedTemplateID: String = FullInstanceTemplate().identifier

    /// Custom sheet selection for the "custom" template.
    /// Persisted across app launches via UserDefaults. The serialized order is
    /// rawValue-alphabetical (`.sorted()`), not tap order.
    var customSelectedSheets: Set<SheetID> {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.customSheetsKey) ?? ""
            let identifiers = raw.split(separator: ",").compactMap { SheetID(rawValue: String($0)) }
            return Set(identifiers)
        }
        set {
            let raw = newValue.map(\.rawValue).sorted().joined(separator: ",")
            UserDefaults.standard.set(raw, forKey: Self.customSheetsKey)
        }
    }

    nonisolated static let customSheetsKey = "generateSheetCustomSelection"

    /// The resolved template for the current selection. Always a known template —
    /// unknown identifiers fall back to Executive via `TemplateResolver`. Custom lists its
    /// sheets in the stored rawValue order: the engine writes them in template order.
    var resolvedTemplate: any ReportTemplate {
        if selectedTemplateID == "custom" {
            return TemplateResolver.resolveCustom(
                sheets: customSelectedSheets.sorted { $0.rawValue < $1.rawValue })
        }
        return TemplateResolver.resolve(identifier: selectedTemplateID)
    }

    /// True when generation can proceed: output type selected, not running, no folder error,
    /// and if custom template is selected, at least one sheet is chosen.
    var canGenerate: Bool {
        let hasOutputType = !selectedTypes.isEmpty
        let notRunning = !isRunning
        let noFolderError = folderPickerError == nil
        let customSelectionValid = selectedTemplateID != "custom" || !customSelectedSheets.isEmpty

        return hasOutputType && notRunning && noFolderError && customSelectionValid
    }

    /// The sheet closes while idle only: a run would carry on out of sight.
    var canDismiss: Bool { !isRunning }

    /// What one Generate press asks for, read from the controls when it is pressed.
    struct Request: Sendable {
        let types: Set<GenerateOutputType>
        let template: any ReportTemplate
        let collectFirst: Bool
        let runsAudit: Bool
        let outputDir: URL?
        /// The School template's workbook comes from the School generator.
        let schoolMode: Bool
        /// The narrative describes Jamf Pro snapshots, which a School report does not read.
        let asksForNarrative: Bool
    }

    func request() -> Request {
        let template = resolvedTemplate
        let school = template.identifier == SchoolTemplate().identifier
        return Request(
            types: selectedTypes, template: template, collectFirst: collectFresh,
            runsAudit: includeAudit, outputDir: customOutputDir,
            schoolMode: school, asksForNarrative: !school)
    }

    /// Runs `request` in the Overview's order (`CLIBridge.runCollectThenGenerate`): the
    /// collect when asked for, then the narrative, which reads the snapshots that collect
    /// wrote, then every format. A refused or failed collect generates nothing and says why.
    static func perform(
        _ request: Request,
        collect: () async throws -> Int32,
        narrative: @escaping () async -> String?,
        generate: (_ aiNarrative: String?) async -> GenerateAllResult
    ) async -> (count: Int, message: String?) {
        var result: GenerateAllResult?
        do {
            let exit = try await CLIBridge.runCollectThenGenerate(
                collect: {
                    guard request.collectFirst else { return 0 }
                    return try await collect()
                },
                narrative: request.asksForNarrative ? narrative : nil,
                generate: { aiNarrative in
                    let generated = await generate(aiNarrative)
                    result = generated
                    return generated.allSucceeded ? 0 : 1
                }
            )
            if let result { return summarize(result) }
            return (0, CLIBridge.explainExit(exit, operation: "Collect"))
        } catch {
            return (0, CLIBridge.explainOperationError(error, operation: "Collect"))
        }
    }

    /// Resolved output directory for display. Falls back to the profile default.
    func resolvedOutputDir(for profile: String) -> URL {
        if let dir = customOutputDir { return dir }
        let fallback = ProfileService.workspaceURL(for: profile)
            ?? WorkspaceRootStore.defaultRoot
        return fallback.appendingPathComponent("Generated Reports", isDirectory: true)
    }

    func appendLine(_ line: CLIBridge.LogLine) {
        logLines.append(line)
        // Match `[ok] sha256: <64hex> <basename>` exactly — Engine emits this
        // for every artifact wrapped in a T-13 integrity envelope.
        if let parsed = GenerateSheetState.parseSHA256LogLine(line.text) {
            generatedHashes[parsed.filename] = parsed.hash
        }
    }

    /// Parse a sentinel SHA-256 log line into `(hash, basename)`.
    /// Returns `nil` if the line doesn't match the expected shape so unrelated
    /// log lines (other `[ok]` lines, free-form messages) flow through untouched.
    /// `nonisolated` because the implementation is a pure function over the
    /// input string — callers from any actor context can invoke it.
    nonisolated static func parseSHA256LogLine(_ text: String) -> (hash: String, filename: String)? {
        let prefix = "[ok] sha256: "
        guard text.hasPrefix(prefix) else { return nil }
        let tail = String(text.dropFirst(prefix.count))
        // Expected: <64 hex chars><space><filename>
        guard let spaceIdx = tail.firstIndex(of: " ") else { return nil }
        let hashCandidate = String(tail[..<spaceIdx])
        guard hashCandidate.count == 64,
              hashCandidate.allSatisfy({ $0.isHexDigit }) else { return nil }
        let filename = String(tail[tail.index(after: spaceIdx)...])
            .trimmingCharacters(in: .whitespaces)
        guard !filename.isEmpty else { return nil }
        return (hashCandidate, filename)
    }

    func reset() {
        logLines = []
        isRunning = false
        completedCount = 0
        completedFiles = []
        errorMessage = nil
        generatedHashes = [:]
    }

    /// Summarise a `GenerateAllResult` into the count and optional error message
    /// the UI should display. Three cases:
    /// - All succeed  → `(succeeded.count, nil)`
    /// - Partial      → `(succeeded.count, "Generated X, Y; Z failed (exit N)")`
    /// - All fail     → `(0, "Generation failed (…). Check the log above.")`
    ///
    /// `nonisolated` — the function is pure over its input; callers from any
    /// actor context can invoke it.
    nonisolated static func summarize(_ result: GenerateAllResult) -> (count: Int, message: String?) {
        if result.failed.isEmpty {
            return (result.succeeded.count, nil)
        }
        if result.succeeded.isEmpty {
            let codes = result.failed
                .map { "\($0.type.rawValue): exit \($0.exitCode)" }
                .joined(separator: ", ")
            return (0, "Generation failed (\(codes)). Check the log above.")
        }
        // Partial: some succeeded, some failed.
        let succeededLabel = result.succeeded.map(\.rawValue).sorted().joined(separator: ", ")
        let failedLabel = result.failed
            .map { "\($0.type.rawValue) (exit \($0.exitCode))" }
            .joined(separator: ", ")
        return (result.succeeded.count,
                "Generated \(succeededLabel); \(failedLabel) failed. Check the log above.")
    }
}

// MARK: - Sheet view

/// Report-generation modal: template or custom sheets, formats, collect first, audit.
/// Presented by the Reports screen; `onGenerated` runs after a run that wrote a file.
struct GenerateSheet: View {
    let profile: String
    let bridge: CLIBridge
    let onGenerated: @MainActor () -> Void

    @State private var state = GenerateSheetState()

    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titlebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    formatsSection
                    templateSection
                    collectToggle
                    auditToggle
                    outputFolderRow
                    profileRow
                    if state.collectFresh, let auth = workspace.authStatus, !auth.isValid {
                        authWarningBanner
                    }
                    if state.isRunning || !state.logLines.isEmpty {
                        logPanel
                    }
                    if let err = state.errorMessage {
                        errorBanner(err)
                    }
                    if !state.isRunning && state.completedCount > 0 {
                        completionBanner
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 540)
        .frame(minHeight: 440)
        .background(Theme.Surface.raised)
        .interactiveDismissDisabled(!state.canDismiss)
    }

    // MARK: Subviews

    private var titlebar: some View {
        HStack {
            Text("Generate Reports")
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.Text.primary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .font(Theme.Fonts.bodyText)
            }
            .buttonStyle(.plain)
            .disabled(!state.canDismiss)
            .accessibilityLabel("Close Generate Reports sheet")
        }
        .padding(18)
    }

    private var formatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(label: "Output formats")
            ForEach(GenerateOutputType.allCases, id: \.self) { type in
                formatRow(type)
            }

            if !state.selectedTypes.isEmpty {
                artifactsSummary
            }
        }
    }

    private var artifactsSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What will be written")
                .font(Theme.Fonts.caption.weight(.medium))
                .foregroundStyle(Theme.Text.secondary)
                .padding(.top, 6)

            ForEach(Array(state.selectedTypes.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { type in
                Text("• \(artifactDescription(for: type))")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }

            if state.collectFresh {
                Text("• summary.json (Trends snapshot)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
        .padding(.leading, 4)
    }

    private func artifactDescription(for type: GenerateOutputType) -> String {
        let timestamp = "report_\(profile)_<date>"
        switch type {
        case .xlsx:
            return "\(timestamp).xlsx + integrity sidecar (.sha256, manifest)"
        case .html:
            return "\(timestamp).html + integrity sidecar (.sha256, manifest)"
        case .pdf:
            return "\(timestamp).pdf + integrity sidecar (.sha256, manifest)"
        case .csv:
            return "automation_inventory_\(profile)_<date>.csv"
        }
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label: "Template")
            Picker("Template", selection: $state.selectedTemplateID) {
                ForEach(TemplateResolver.allTemplates, id: \.identifier) { template in
                    Text(template.displayName).tag(template.identifier)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(state.isRunning)
            .accessibilityLabel("Report template selection")

            // Show custom sheet selection when "custom" template is selected
            if state.selectedTemplateID == "custom" {
                customSheetSelection
            } else {
                templateDescriptionPanel(for: state.resolvedTemplate)
            }
        }
    }

    /// Two-line description block + audience line + tier badge for the chosen template.
    private func templateDescriptionPanel(for template: any ReportTemplate) -> some View {
        let sheets = template.includedSheets
        let sheetPreview: String = {
            let names = sheets.prefix(3).map(\.rawValue)
            let suffix = sheets.count > 3 ? " + \(sheets.count - 3) more" : ""
            return names.joined(separator: ", ") + suffix
        }()

        return VStack(alignment: .leading, spacing: 4) {
            Text(template.description)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(sheetPreview)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("For: \(template.audience)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))

                Spacer()

                tierBadge(for: template.recommendedSchedule)
            }
        }
        .padding(.top, 2)
    }

    private func tierBadge(for tier: TemplateDataTier) -> some View {
        Text(tier.rawValue.uppercased())
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(Theme.Colors.goldBright)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Theme.Colors.gold.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.Colors.gold.opacity(0.35), lineWidth: 0.5)
            )
            .accessibilityLabel("Data tier: \(tier.rawValue)")
    }

    // MARK: - Custom sheet selection

    /// Multi-select sheet picker for the "custom" template option.
    private var customSheetSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.customSelectedSheets.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.warn)
                        .font(Theme.Fonts.caption)
                    Text("Select at least one sheet to enable generation")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.warn)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.ok)
                        .font(Theme.Fonts.caption)
                    Text("\(state.customSelectedSheets.count) sheet\(state.customSelectedSheets.count == 1 ? "" : "s") selected")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
                .padding(.top, 4)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(CustomSheetGroup.allGroups, id: \.name) { group in
                        sheetGroupSection(group)
                    }
                }
            }
            .frame(maxHeight: 280)
            .background(Theme.Surface.quiet, in: RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius)
                    .strokeBorder(Theme.Hairline.standard, lineWidth: 0.5)
            )
        }
    }

    private func sheetGroupSection(_ group: CustomSheetGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.name)
                .font(Theme.Fonts.label.weight(.medium))
                .foregroundStyle(Theme.Text.primary)
                .padding(.horizontal, 12)
                .padding(.top, group.name == CustomSheetGroup.allGroups.first?.name ? 8 : 4)

            ForEach(group.sheets, id: \.self) { sheet in
                customSheetRow(sheet)
            }
        }
    }

    private func customSheetRow(_ sheet: SheetID) -> some View {
        let isSelected = state.customSelectedSheets.contains(sheet)
        return Button {
            if isSelected {
                state.customSelectedSheets.remove(sheet)
            } else {
                state.customSelectedSheets.insert(sheet)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Theme.Colors.gold : Theme.Text.tertiary(contrast))
                    .font(Theme.Fonts.bodyText)

                Text(sheet.rawValue)
                    .font(Theme.Fonts.bodyText)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(
                isSelected ? Theme.Colors.gold.opacity(0.06) : Color.clear
            )
        }
        .buttonStyle(.plain)
        .disabled(state.isRunning)
        .accessibilityLabel("\(sheet.rawValue) sheet. \(isSelected ? "Selected" : "Not selected")")
    }

    private func formatRow(_ type: GenerateOutputType) -> some View {
        let isSelected = state.selectedTypes.contains(type)
        return Button {
            if isSelected {
                state.selectedTypes.remove(type)
            } else {
                state.selectedTypes.insert(type)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Theme.Colors.gold : Theme.Text.tertiary(contrast))
                    .font(Theme.Fonts.bodyText)
                Image(systemName: type.icon)
                    .foregroundStyle(isSelected ? Theme.Text.primary : Theme.Text.tertiary(contrast))
                    .font(Theme.Fonts.bodyText)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(type.rawValue)
                        .font(Theme.Fonts.bodyText.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    Text(type.description)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                isSelected ? Theme.Colors.gold.opacity(0.07) : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.Colors.gold.opacity(0.3) : Theme.Hairline.standard,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(state.isRunning)
        .accessibilityLabel("\(type.rawValue) — \(type.description). \(state.selectedTypes.contains(type) ? "Selected" : "Not selected")")
    }

    private var collectToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label: "Data")
            Button {
                state.collectFresh.toggle()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: state.collectFresh ? "checkmark.square.fill" : "square")
                        .foregroundStyle(state.collectFresh ? Theme.Colors.gold : Theme.Text.tertiary(contrast))
                        .font(Theme.Fonts.bodyText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Collect fresh data first")
                            .font(Theme.Fonts.bodyText.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                        Text("Uncheck to use cached snapshots without a live jamf-cli call.")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .disabled(state.isRunning)
            .accessibilityLabel("Collect fresh data first. \(state.collectFresh ? "Enabled" : "Disabled")")
        }
    }

    private var auditToggle: some View {
        Button {
            state.includeAudit.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: state.includeAudit ? "checkmark.square.fill" : "square")
                    .foregroundStyle(state.includeAudit ? Theme.Colors.gold : Theme.Text.tertiary(contrast))
                    .font(Theme.Fonts.bodyText)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Include Health Audit")
                        .font(Theme.Fonts.bodyText.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    Text("Run jamf-cli pro audit first so audit findings in the report are current. Adds a few minutes on large fleets.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(state.isRunning)
        .accessibilityLabel("Include Health Audit. \(state.includeAudit ? "Enabled" : "Disabled")")
    }

    private var outputFolderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label: "Output folder")
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(
                        state.folderPickerError != nil
                            ? Theme.Colors.danger : Theme.Text.tertiary(contrast)
                    )
                    .font(Theme.Fonts.label)
                Text(state.resolvedOutputDir(for: profile).path
                        .replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path,
                            with: "~"
                        ))
                    .font(Theme.Fonts.mono(11.5))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                PNPButton(title: "Choose\u{2026}", size: .sm) {
                    chooseOutputFolder()
                }
                .disabled(state.isRunning)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.Surface.quiet, in: RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius, style: .continuous)
                    .strokeBorder(
                        state.folderPickerError != nil
                            ? Theme.Colors.danger : Theme.Hairline.standard,
                        lineWidth: 0.5
                    )
            )
            if let err = state.folderPickerError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.danger)
                        .font(Theme.Fonts.caption)
                    Text(err)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.danger)
                }
            }
        }
    }

    private var profileRow: some View {
        HStack(spacing: 6) {
            Kicker(text: "Profile")
            Text(profile)
                .font(Theme.Fonts.mono(12))
                .foregroundStyle(Theme.Colors.goldBright)
            Text("(active)")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(text: "Live log")
            RunLogConsoleEmbed(lines: state.logLines, isRunning: state.isRunning)
                .frame(height: 140)
        }
    }

    private var authWarningBanner: some View {
        InlineBanner(
            icon: "key.slash",
            tone: .warn,
            action: InlineBannerAction(label: "Re-check") {
                Task { await workspace.refreshAuthStatus() }
            }
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auth may be expired for profile '\(profile)'")
                    .font(Theme.Fonts.label.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                Text("Collecting fresh data will fail. Re-authenticate or disable \u{201C}Collect fresh data\u{201D}.")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Text.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: auth may be expired for profile '\(profile)'. Re-authenticate or disable collect fresh data.")
    }

    private func errorBanner(_ message: String) -> some View {
        InlineBanner(icon: "exclamationmark.triangle.fill", tone: .danger) {
            Text(message)
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Colors.danger)
        }
    }

    private var completionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.ok)
                Text("Done — \(state.completedCount) file\(state.completedCount == 1 ? "" : "s") generated")
                    .font(Theme.Fonts.bodyText.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                Spacer()
                PNPButton(title: "Reveal in Finder", icon: "folder", size: .sm) {
                    let dir = state.resolvedOutputDir(for: profile)
                    SystemActions.openFolder(dir)
                }
            }

            // T-13 integrity envelope: list the per-artifact SHA-256 fingerprint
            // with a click-to-copy affordance. Truncated to 12 chars for the row;
            // copying yields the full 64-char hex digest.
            if !state.generatedHashes.isEmpty {
                ForEach(state.generatedHashes.sorted(by: { $0.key < $1.key }), id: \.key) { filename, hash in
                    integrityHashRow(filename: filename, hash: hash)
                }
            }
        }
        .padding(12)
        .background(Theme.Colors.ok.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius)
                .strokeBorder(Theme.Colors.ok.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func integrityHashRow(filename: String, hash: String) -> some View {
        let truncated = hash.count > 12 ? String(hash.prefix(12)) + "\u{2026}" : hash
        return HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Theme.Text.secondary)
                .font(.caption)
            Text(filename)
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("sha256: \(truncated)")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .help("Full hash: \(hash)")
            Button {
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hash, forType: .string)
                #endif
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Copy full SHA-256 to clipboard")
            .accessibilityLabel("Copy SHA-256 for \(filename)")
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            PNPButton(title: state.isRunning ? "Running\u{2026}" : "Done") {
                dismiss()
            }
            .disabled(!state.canDismiss)
            .keyboardShortcut(.cancelAction)

            PNPButton(
                title: state.isRunning ? "Running\u{2026}" : "Generate",
                icon: state.isRunning ? "hourglass" : "play.fill",
                style: .gold
            ) {
                guard state.canGenerate else { return }
                Task { await runGenerate() }
            }
            .disabled(!state.canGenerate)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(state.isRunning ? "Running" : "Generate selected report formats")
        }
        .padding(14)
    }

    // MARK: Actions

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose output folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = state.resolvedOutputDir(for: profile)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let testURL = url.appendingPathComponent(
            ".jamf-reports-write-test-\(UUID().uuidString)"
        )
        do {
            try Data().write(to: testURL)
            try FileManager.default.removeItem(at: testURL)
            state.customOutputDir = url
            state.folderPickerError = nil
        } catch {
            state.folderPickerError = "Cannot write to \(url.lastPathComponent): "
                + error.localizedDescription
        }
    }

    private func runGenerate() async {
        // A demo profile's name can match a real workspace; the presenter disables Generate too.
        guard !workspace.demoMode else { return }
        guard workspace.setRunInProgress(for: profile) else {
            state.errorMessage = "Another run is already in progress for profile '\(profile)' — skipped"
            return
        }

        state.reset()
        state.isRunning = true
        defer {
            workspace.clearRunInProgress(for: profile)
            state.isRunning = false
        }

        let request = state.request()
        let onLine: @Sendable (CLIBridge.LogLine) -> Void = { line in
            Task { @MainActor in state.appendLine(line) }
        }

        // Opt-in audit-before-generate (v2.2.0): refresh Health Audit data so
        // audit-derived workbook content reflects this run. Failures warn and
        // continue — a stale audit is preferable to no report.
        if request.runsAudit {
            state.appendLine(.init(
                timestamp: Date(), level: .info,
                text: "[info] running health audit before generate"
            ))
            do {
                _ = try await bridge.audit(profile: profile, category: nil, onLine: onLine)
            } catch {
                state.appendLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] audit failed; continuing with cached audit data: \(error.localizedDescription)"
                ))
            }
        }

        // The collect is the Overview's (`collectThenGenerate`'s), and the F3 narrative,
        // time-boxed inside makeForGUIGenerate, is asked for after it. `generateAll` gets
        // collectFresh: false because the collect has already run.
        let outcome = await GenerateSheetState.perform(
            request,
            collect: { try await bridge.collect(profile: profile, force: true, onLine: onLine) },
            narrative: { await ReportNarrative.makeForGUIGenerate(profile: profile) },
            generate: { narrative in
                await bridge.generateAll(
                    types: request.types, collectFresh: false, outputDir: request.outputDir,
                    profile: profile, schoolMode: request.schoolMode,
                    template: request.template, aiNarrative: narrative, onLine: onLine)
            }
        )
        state.completedCount = outcome.count
        state.errorMessage = outcome.message
        if outcome.count > 0 { onGenerated() }
    }
}

// MARK: - Embedded run log console

/// Minimal terminal-style console embedded in the Generate sheet.
/// Reuses the same line-coloring logic as the popover variant in SchedulesView.
private struct RunLogConsoleEmbed: View {
    let lines: [CLIBridge.LogLine]
    let isRunning: Bool

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isScrolledToBottom = true
    @State private var cursorVisible = true
    private let cursorTick = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        HStack(spacing: 0) {
                            Text(isRunning ? "Starting\u{2026}" : "No output yet")
                                .font(Theme.Fonts.mono(11.5))
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                                .accessibilityAddTraits(.updatesFrequently)
                            blinkingCursor
                        }
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                            HStack(spacing: 0) {
                                Text(line.text)
                                    .font(Theme.Fonts.mono(11.5))
                                    .foregroundStyle(lineColor(line))
                                    .textSelection(.enabled)
                                    .accessibilityAddTraits(.updatesFrequently)
                                if idx == lines.count - 1 { blinkingCursor }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("log-bottom")
                }
                .padding(10)
            }
            .background(Theme.Colors.codeBG)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius, style: .continuous)
                    .strokeBorder(Theme.Hairline.strong, lineWidth: 1)
            )
            .onChange(of: lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
        .onReceive(cursorTick) { _ in cursorVisible.toggle() }
    }

    private var blinkingCursor: some View {
        Rectangle()
            .fill(Theme.Colors.goldBright)
            .frame(width: 6, height: 12)
            .opacity(cursorVisible && isRunning ? 1 : 0)
            .padding(.leading, 2)
    }

    private func lineColor(_ line: CLIBridge.LogLine) -> Color {
        let l = line.text.lowercased()
        if l.contains("error") || l.contains("fail") || line.level == .fail { return Theme.Colors.dangerSoft }
        if l.contains("warn") || line.level == .warn { return Theme.Colors.warnSoft }
        if l.contains("[ok]") || l.contains("success") || l.contains("done") || line.level == .ok {
            return Theme.Colors.ok
        }
        return Theme.Text.secondary
    }
}
