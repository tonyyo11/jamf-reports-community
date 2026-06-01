import SwiftUI
import AppKit

// MARK: - Output type

/// The set of report formats the unified Generate sheet can produce.
enum GenerateOutputType: String, CaseIterable, Hashable, Sendable {
    case xlsx = "XLSX"
    case html = "HTML"
    case pdf  = "PDF"
    case csv  = "CSV"

    var description: String {
        switch self {
        case .xlsx: "Full data, all sheets"
        case .html: "Executive summary, browser"
        case .pdf:  "Paginated audit artifact"
        case .csv:  "Wide inventory export"
        }
    }

    var icon: String {
        switch self {
        case .xlsx: "tablecells"
        case .html: "safari"
        case .pdf:  "doc.richtext"
        case .csv:  "doc.plaintext"
        }
    }
}

// MARK: - Sheet state (extracted for testability)

/// Observable model backing GenerateSheet. Extracted so it can be unit-tested
/// without instantiating a SwiftUI view.
@MainActor
@Observable
final class GenerateSheetState {
    var selectedTypes: Set<GenerateOutputType> = [.xlsx]
    var collectFresh: Bool = true
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
    /// Persisted for the sheet's lifetime; falls back to Executive on next open.
    var selectedTemplateID: String = FullInstanceTemplate().identifier

    /// The resolved template for the current selection. Always a known template —
    /// unknown identifiers fall back to Executive via `TemplateResolver`.
    var resolvedTemplate: any ReportTemplate {
        TemplateResolver.resolve(identifier: selectedTemplateID)
    }

    /// True when at least one output type is selected, not running, and no folder error.
    var canGenerate: Bool {
        !selectedTypes.isEmpty && !isRunning && folderPickerError == nil
    }

    /// Resolved output directory for display. Falls back to the profile default.
    func resolvedOutputDir(for profile: String) -> URL {
        if let dir = customOutputDir { return dir }
        let fallback = ProfileService.workspaceURL(for: profile)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Jamf-Reports")
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
}

// MARK: - Sheet view

/// Unified report-generation modal. Present as a `.sheet` from any view.
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $showGenerate) {
///     GenerateSheet(profile: workspace.profile, bridge: bridge)
/// }
/// ```
struct GenerateSheet: View {
    let profile: String
    let bridge: CLIBridge
    var onSchedule: (ScheduleFormState) -> Void = { _ in }

    @State private var state = GenerateSheetState()
    @State private var showScheduleSheet = false
    @State private var scheduleForm = ScheduleFormState()

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
        .sheet(isPresented: $showScheduleSheet) {
            NewScheduleSheetWrapper(form: $scheduleForm, profiles: [profile]) { form in
                showScheduleSheet = false
                onSchedule(form)
            } onCancel: {
                showScheduleSheet = false
            }
        }
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

            templateDescriptionPanel(for: state.resolvedTemplate)
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
        HStack(spacing: 10) {
            Image(systemName: "key.slash")
                .foregroundStyle(Theme.Colors.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("Auth may be expired for profile '\(profile)'")
                    .font(Theme.Fonts.label.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                Text("Collecting fresh data will fail. Re-authenticate or disable \u{201C}Collect fresh data\u{201D}.")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
            PNPButton(title: "Re-check", size: .sm) {
                Task { await workspace.refreshAuthStatus() }
            }
        }
        .padding(12)
        .background(Theme.Colors.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius)
                .strokeBorder(Theme.Colors.warn.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: auth may be expired for profile '\(profile)'. Re-authenticate or disable collect fresh data.")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.danger)
            Text(message)
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Colors.danger)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius))
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
            Button {
                prefillAndOpenScheduleSheet()
            } label: {
                Text("Save as schedule\u{2026}")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Colors.goldBright)
            }
            .buttonStyle(.plain)
            .disabled(state.isRunning)
            .accessibilityLabel("Save current settings as a recurring schedule")

            Spacer()

            PNPButton(title: state.isRunning ? "Running\u{2026}" : "Done") {
                dismiss()
            }
            .disabled(state.isRunning)

            PNPButton(
                title: state.isRunning ? "Running\u{2026}" : "Generate",
                icon: state.isRunning ? "hourglass" : "play.fill",
                style: .gold
            ) {
                guard state.canGenerate else { return }
                Task { await runGenerate() }
            }
            .disabled(!state.canGenerate)
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

    private func prefillAndOpenScheduleSheet() {
        scheduleForm = ScheduleFormState(defaultProfile: profile)
        scheduleForm.mode = state.collectFresh ? .jamfCLIOnly : .snapshotOnly
        showScheduleSheet = true
    }

    private func runGenerate() async {
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

        var count = 0
        let outputDir: URL? = state.customOutputDir
        let isSchool = state.resolvedTemplate.identifier == SchoolTemplate().identifier

        // School template routes to the school generate command rather than the standard flow.
        if isSchool {
            let result = await bridge.generateAll(
                types: state.selectedTypes,
                collectFresh: state.collectFresh,
                outputDir: outputDir,
                profile: profile,
                schoolMode: true
            ) { line in
                Task { @MainActor in
                    state.appendLine(line)
                }
            }
            if result.failed.isEmpty {
                count = result.succeeded.count
                state.completedCount = count
            } else {
                let codes = result.failed.map { "\($0.type.rawValue): exit \($0.exitCode)" }
                    .joined(separator: ", ")
                state.errorMessage = "Generation failed (\(codes)). Check the log above."
            }
            return
        }

        let result = await bridge.generateAll(
            types: state.selectedTypes,
            collectFresh: state.collectFresh,
            outputDir: outputDir,
            profile: profile,
            template: state.resolvedTemplate
        ) { line in
            Task { @MainActor in
                state.appendLine(line)
            }
        }

        if result.failed.isEmpty {
            count = result.succeeded.count
            state.completedCount = count
        } else {
            let codes = result.failed.map { "\($0.type.rawValue): exit \($0.exitCode)" }
                .joined(separator: ", ")
            state.errorMessage = "Generation failed (\(codes)). Check the log above."
        }
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

// MARK: - NewScheduleSheet wrapper

/// Thin wrapper so GenerateSheet can present NewScheduleSheet (which is `private` in
/// SchedulesView). We re-expose the necessary interface here using ScheduleFormState,
/// which is already `internal`.
private struct NewScheduleSheetWrapper: View {
    @Binding var form: ScheduleFormState
    let profiles: [String]
    let onSave: (ScheduleFormState) -> Void
    let onCancel: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New Schedule")
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.Text.primary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .font(Theme.Fonts.bodyText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
            }
            .padding(18)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formRow(label: "Name") {
                        PNPTextField(value: $form.name, placeholder: "e.g. Daily Snapshot Collection")
                    }
                    formRow(label: "Profile") {
                        Picker("", selection: $form.profile) {
                            ForEach(profiles, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                    formRow(label: "Mode") {
                        Picker("", selection: $form.mode) {
                            ForEach(Schedule.RunMode.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                    Text(modeDescription(for: form.mode))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                    formRow(label: "Cadence") {
                        Picker("", selection: $form.cadenceType) {
                            ForEach(ScheduleFormState.CadenceType.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                    formRow(label: "Time") {
                        DatePicker("", selection: $form.scheduledTime,
                                   displayedComponents: [.hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    }
                    formRow(label: "Enabled") {
                        Toggle("", isOn: $form.enabled).labelsHidden()
                    }
                    FieldHelp(text: "Cadence preview: \(form.scheduleString)")
                    Text("Note: schedules always produce XLSX. HTML/PDF format selection from Generate applies to on-demand runs only.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            Divider()
            HStack {
                Spacer()
                PNPButton(title: "Cancel", action: onCancel)
                PNPButton(title: "Add Schedule", icon: "checkmark", style: .gold) {
                    onSave(form)
                }
                .disabled(!form.isValid)
            }
            .padding(14)
        }
        .frame(minWidth: 360, idealWidth: 420)
        .background(Theme.Surface.raised)
    }

    @ViewBuilder
    private func formRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label: label)
            HStack(spacing: 8) { content() }
        }
    }

    private func modeDescription(for mode: Schedule.RunMode) -> String {
        switch mode {
        case .snapshotOnly: "Refresh jamf-cli JSON and archive CSV snapshots. No report generated."
        case .jamfCLIOnly:  "Generate a report from live or cached jamf-cli data. No CSV required."
        case .jamfCLIFull:  "Full run: collect snapshots, archive CSV, then generate from both sources."
        case .csvAssisted:  "Generate combining a CSV from the inbox with live jamf-cli data."
        }
    }
}
