import SwiftUI
import AppKit

struct ReportsView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var bridge = CLIBridge()
    @State private var filter: String = "All"
    @State private var selectedReports = Set<Report.ID>()
    @State private var reports: [Report] = []
    @State private var reportStats = ReportLibrary.Stats(count: 0, totalBytes: 0, archivedCount: 0)
    @State private var snapshotFamilies: [SnapshotFamily] = []
    @State private var isGeneratingHTML = false
    @State private var isGeneratingPDF = false
    @State private var isExportingCSV = false
    @State private var reportError: String?
    @State private var searchText = ""
    @State private var profileFilter: String? = nil
    @State private var availableProfiles: [String] = []
    @State private var showPeriodReport = false
    @State private var showQuickLook = false
    @State private var quickLookURL: URL? = nil

    private var reportsDirectory: URL {
        let workspace = ProfileService.workspaceURL(for: workspace.profile)
            ?? WorkspaceRootStore.defaultRoot
        return workspace.appendingPathComponent("Generated Reports", isDirectory: true)
    }

    /// The header's folder. Demo mode names the demo workspace, not this Mac's
    /// configured root, which may be a synced team folder.
    private var reportsFolderDisplayPath: String {
        workspace.demoMode
            ? DemoData.workspaceDisplayPath(
                profile: DemoData.org.profile, subpath: "Generated Reports") + "/"
            : WorkspaceRootStore.displayPath(profile: workspace.profile,
                                             subpath: "Generated Reports") + "/"
    }

    private func revealReportsFolder() {
        // Demo reports are not on disk; the demo profile's folder could be real.
        guard !workspace.demoMode else { return }
        SystemActions.openFolder(reportsDirectory)
    }

    private var filteredReports: [Report] {
        let typeFiltered: [Report]
        if filter == "All" {
            typeFiltered = reports
        } else {
            typeFiltered = reports.filter { $0.name.lowercased().hasSuffix(".\(filter.lowercased())") }
        }

        return Self.filteredReports(
            reports: typeFiltered,
            searchText: searchText,
            profileFilter: profileFilter
        )
    }

    private var snapshotCount: Int {
        snapshotFamilies.reduce(0) { $0 + $1.snapshotCount }
    }

    /// Pure filter function for testing. Filters reports by search text and profile.
    /// Search matches report name and source (case-insensitive). Profile filter matches
    /// profile tokens in the filename (case-insensitive).
    static func filteredReports(
        reports: [Report],
        searchText: String,
        profileFilter: String?
    ) -> [Report] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProfile = profileFilter?.trimmingCharacters(in: .whitespacesAndNewlines)

        return reports.filter { report in
            // Search filter: match name or source (case-insensitive)
            let searchMatch: Bool
            if trimmedSearch.isEmpty {
                searchMatch = true
            } else {
                let searchableText = "\(report.name) \(report.source)".lowercased()
                searchMatch = searchableText.contains(trimmedSearch.lowercased())
            }

            // Profile filter: match profile token in filename (case-insensitive)
            let profileMatch: Bool
            if let profile = trimmedProfile, !profile.isEmpty {
                profileMatch = report.name.lowercased().contains(profile.lowercased())
            } else {
                profileMatch = true
            }

            return searchMatch && profileMatch
        }
    }

    var body: some View {
        PageScaffold(spacing: 16) {
            header
            Card(padding: 0) {
                if reports.isEmpty {
                    emptyState
                } else if filteredReports.isEmpty {
                    noFilterMatches
                } else {
                    Table(filteredReports, selection: $selectedReports) {
                        TableColumn("Filename") { r in
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: r.name))
                                    .foregroundStyle(Theme.Colors.gold)
                                    .font(.system(size: 11))
                                    .accessibilityHidden(true)
                                Mono(text: r.name, color: Theme.Colors.fg)
                            }
                            .accessibilityLabel(
                                "\(r.name), \(r.sheets) sheet\(r.sheets == 1 ? "" : "s"), \(r.size)"
                            )
                        }
                        TableColumn("Source schedule") { r in
                            Text(r.source).font(.footnote)
                        }
                        TableColumn("Sheets") { r in Mono(text: "\(r.sheets)") }
                        TableColumn("Devices") { r in Mono(text: r.devices.map { "\($0)" } ?? "—") }
                        TableColumn("Size") { r in Mono(text: r.size) }
                        TableColumn("Generated") { r in Mono(text: r.date) }
                    }
                    .frame(minHeight: 360)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: Report.ID.self) { selection in
                        if workspace.demoMode {
                            // Demo reports are not on disk, and looking one up
                            // by name would search a real workspace's folder.
                            Button("Reveal in Finder") {}.disabled(true)
                            Button("Open") {}.disabled(true)
                        } else if let reportID = selection.first,
                           let url = ReportLibrary().url(
                            profile: workspace.profile,
                            reportName: reportID
                           ) {
                            Button("Reveal in Finder") {
                                SystemActions.reveal(url)
                            }
                            Button("Open") {
                                SystemActions.open(url)
                            }
                            Button("Copy path") {
                                SystemActions.copyToClipboard(url.path)
                            }
                        }
                    }
                }
            }
            summary
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search reports...")
        .sheet(isPresented: $showPeriodReport) {
            PeriodReportSheet()
        }
        .sheet(isPresented: $showQuickLook) {
            NavigationStack {
                if let url = quickLookURL {
                    QuickLookPreview(url: url)
                        .navigationTitle("Preview")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showQuickLook = false }
                            }
                        }
                } else {
                    Text("Preview not available")
                        .foregroundStyle(.secondary)
                        .navigationTitle("Preview")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showQuickLook = false }
                            }
                        }
                }
            }
        }
        .onKeyPress(.space) {
            handleSpaceKeyPress()
            return .handled
        }
        .onAppear(perform: reload)
        .onChange(of: workspace.profile) { _, _ in reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageHeader(
                kicker: "Generated Reports",
                breadcrumbs: [Breadcrumb(label: "Overview", action: { navigateToOverview() })],
                title: reports.count == 1 ? "1 report" : "\(reports.count) reports",
                subtitle: reportsFolderDisplayPath
            ) {
                AnyView(
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            PNPButton(title: "Reveal in Finder", icon: "folder") {
                                revealReportsFolder()
                            }
                            .disabled(workspace.demoMode)
                            .help(workspace.demoMode
                                  ? "Demo reports are not on disk. Revealing their folder "
                                    + "needs a live profile."
                                  : "Open the Generated Reports folder in Finder")
                            PNPButton(
                                title: "Period report",
                                icon: "calendar.badge.clock",
                                style: .neutral
                            ) {
                                // The sheet reads the workspace's summaries.
                                guard !workspace.demoMode else { return }
                                showPeriodReport = true
                            }
                            .disabled(workspace.demoMode)
                            .help(
                                workspace.demoMode
                                ? DemoData.liveOnlyHelp
                                : "Fleet numbers for a period, with start, end and change"
                            )
                            PNPButton(
                                title: isGeneratingHTML ? "Generating..." : "Generate HTML",
                                icon: "safari",
                                style: .gold
                            ) {
                                generateHTMLReport()
                            }
                            .disabled(workspace.demoMode || isGeneratingHTML || isGeneratingPDF || isExportingCSV)
                            .help(
                                workspace.demoMode
                                ? DemoData.liveOnlyHelp
                                : "Generate a self-contained HTML instance report"
                            )
                            PNPButton(
                                title: isGeneratingPDF ? "Generating..." : "Export PDF",
                                icon: "doc.richtext",
                                style: .neutral
                            ) {
                                generatePDFReport()
                            }
                            .disabled(workspace.demoMode || isGeneratingHTML || isGeneratingPDF || isExportingCSV)
                            .help(
                                workspace.demoMode
                                ? DemoData.liveOnlyHelp
                                : "Render the HTML report to PDF via WKWebView"
                            )
                            PNPButton(
                                title: isExportingCSV ? "Exporting..." : "Export Inventory CSV",
                                icon: "doc.text",
                                style: .neutral
                            ) {
                                runExportInventoryCSV()
                            }
                            .disabled(workspace.demoMode || isGeneratingHTML || isGeneratingPDF || isExportingCSV)
                            .help(
                                workspace.demoMode
                                ? DemoData.liveOnlyHelp
                                : "Export a wide CSV of all computer inventory"
                            )
                        }
                    }
                )
            }
            HStack(spacing: 8) {
                SegmentedControl(
                    selection: $filter,
                    options: [
                        ("All", "All", nil),
                        ("xlsx", "xlsx", nil),
                        ("html", "html", nil),
                        ("pdf", "pdf", nil),
                        ("csv", "csv", nil),
                    ]
                )
                Menu {
                    Button("All Profiles") { profileFilter = nil }
                    if !availableProfiles.isEmpty {
                        Divider()
                        ForEach(availableProfiles, id: \.self) { profile in
                            Button(profile) { profileFilter = profile }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(profileFilter ?? "All Profiles")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fg)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Colors.winBG2, in: RoundedRectangle(cornerRadius: 6))
                }
                .help("Filter reports by profile")
                Spacer()
            }
            if let err = reportError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.danger)
                    .accessibilityLabel("Error: \(err)")
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "doc.badge.plus",
            title: "No reports yet",
            message: "Reports are generated from the Overview screen using "
                + "jamf-cli snapshots and optionally a CSV export.",
            primaryAction: EmptyStateAction(
                label: "Go to Overview",
                icon: "house"
            ) { requestOverviewTab() }
        )
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding(20)
    }

    private var noFilterMatches: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 24))
                .foregroundStyle(Theme.Colors.fgMuted)
                .accessibilityHidden(true)
            Text("No \(filter) reports found")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Colors.fg)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            StatTile(
                label: "Total reports",
                value: "\(reportStats.count)",
                sub: "Generated outputs"
            )
            StatTile(
                label: "Disk used",
                value: FileDisplay.size(reportStats.totalBytes),
                sub: "xlsx · html · pdf · csv"
            )
            StatTile(
                label: "Snapshots archived",
                value: "\(snapshotCount)",
                sub: snapshotFamilies.count == 1 ? "1 family" : "\(snapshotFamilies.count) families"
            )
            StatTile(
                label: "Auto-archived",
                value: "\(reportStats.archivedCount)",
                sub: "Moved to /archive"
            )
        }
    }

    private func reload() {
        if workspace.demoMode {
            // The demo profile's name could match a real workspace on this Mac;
            // demo mode lists the demo's reports and never reads a folder.
            reports = DemoData.generatedReports
            reportStats = DemoData.generatedReportStats
            snapshotFamilies = DemoData.snapshotFamilies(for: DemoData.org.profile)
        } else {
            let library = ReportLibrary()
            reports = library.list(profile: workspace.profile)
            reportStats = library.stats(profile: workspace.profile)
            snapshotFamilies = SnapshotArchiveService().families(profile: workspace.profile)
        }
        selectedReports = selectedReports.intersection(Set(reports.map(\.id)))
        updateAvailableProfiles()
    }

    private func icon(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "xlsx": "tablecells"
        case "html": "safari"
        case "pdf": "doc.richtext"
        case "csv": "doc.text"
        default: "doc"
        }
    }

    private func navigateToOverview() {
        NotificationCenter.default.post(
            name: .navigateToTab,
            object: nil,
            userInfo: ["tab": Tab.overview.rawValue]
        )
    }

    private func requestOverviewTab() {
        NotificationCenter.default.post(name: .requestOverviewTab, object: nil)
    }

    // The generate and export actions run jamf-cli against the selected
    // profile, a fictional one in demo mode; their buttons are disabled there.

    @MainActor
    private func generateHTMLReport() {
        guard !workspace.demoMode else { return }
        let profile = workspace.profile
        let dateStr = ExportNaming.timestamp()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "jamf_report_\(profile)_\(dateStr).html"
        panel.allowedContentTypes = [.html]
        panel.directoryURL = reportsDirectory
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            let outPath = dest.path
            isGeneratingHTML = true
            workspace.globalStatus = "generate · profile=\(profile)"
            reportError = nil
            Task {
                // T-13 integrity envelope: scrape the engine's sentinel sha256 log line
                // so we can surface the truncated fingerprint in the toast.
                let hashBox = HashBox()
                // Status-bar race guard — see comment in AuditView.runAudit.
                let code: Int32
                do {
                    code = try await bridge.generateHTML(
                        profile: profile, outFile: outPath
                    ) { line in
                        if let parsed = GenerateSheetState.parseSHA256LogLine(line.text) {
                            Task { @MainActor in hashBox.value = parsed.hash }
                        }
                        Task { @MainActor in
                            guard self.isGeneratingHTML else { return }
                            workspace.globalStatus = line.text
                        }
                    }
                } catch {
                    isGeneratingHTML = false
                    workspace.globalStatus = nil
                    workspace.toast = Toast(message: "HTML generation failed · \(error.localizedDescription)", style: .danger)
                    reportError = "HTML generation failed: \(error.localizedDescription)"
                    return
                }
                isGeneratingHTML = false
                workspace.globalStatus = nil
                if code == 0 {
                    let message: String
                    if let hash = hashBox.value {
                        let truncated = hash.count > 12 ? String(hash.prefix(12)) + "\u{2026}" : hash
                        message = "HTML report generated · sha256: \(truncated)"
                    } else {
                        message = "HTML report generated"
                    }
                    workspace.toast = Toast(message: message, style: .success)
                    SystemActions.open(dest)
                    reload()
                } else {
                    let msg = CLIBridge.explainExit(code, operation: "HTML report generation")
                    workspace.toast = Toast(message: msg, style: .danger)
                    reportError = msg
                }
            }
        }
    }

    @MainActor
    private func generatePDFReport() {
        guard !workspace.demoMode else { return }
        let profile = workspace.profile
        let dateStr = ExportNaming.timestamp()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "jamf_report_\(profile)_\(dateStr).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = reportsDirectory
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            let outPath = dest.path
            isGeneratingPDF = true
            workspace.globalStatus = "pdf · profile=\(profile)"
            reportError = nil
            Task {
                let code: Int32
                do {
                    code = try await bridge.generatePDF(
                        profile: profile, outFile: outPath
                    ) { line in
                        Task { @MainActor in
                            guard self.isGeneratingPDF else { return }
                            workspace.globalStatus = line.text
                        }
                    }
                } catch {
                    isGeneratingPDF = false
                    workspace.globalStatus = nil
                    workspace.toast = Toast(message: "PDF generation failed · \(error.localizedDescription)", style: .danger)
                    reportError = "PDF generation failed: \(error.localizedDescription)"
                    return
                }
                isGeneratingPDF = false
                workspace.globalStatus = nil
                if code == 0 {
                    workspace.toast = Toast(message: "PDF report generated", style: .success)
                    SystemActions.open(dest)
                    reload()
                } else {
                    let msg = CLIBridge.explainExit(code, operation: "PDF report generation")
                    workspace.toast = Toast(message: msg, style: .danger)
                    reportError = msg
                }
            }
        }
    }

    @MainActor
    private func runExportInventoryCSV() {
        guard !workspace.demoMode else { return }
        let profile = workspace.profile
        let dateStr = ExportNaming.timestamp()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "inventory_\(profile)_\(dateStr).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.directoryURL = reportsDirectory
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            let outPath = dest.path
            isExportingCSV = true
            workspace.globalStatus = "inventory-csv · profile=\(profile)"
            reportError = nil
            Task {
                let code: Int32
                do {
                    code = try await bridge.exportInventoryCSV(
                        profile: profile, outFile: outPath
                    ) { line in
                        Task { @MainActor in
                            guard self.isExportingCSV else { return }
                            workspace.globalStatus = line.text
                        }
                    }
                } catch {
                    isExportingCSV = false
                    workspace.globalStatus = nil
                    workspace.toast = Toast(message: "CSV export failed · \(error.localizedDescription)", style: .danger)
                    reportError = "Inventory CSV export failed: \(error.localizedDescription)"
                    return
                }
                isExportingCSV = false
                workspace.globalStatus = nil
                if code == 0 {
                    workspace.toast = Toast(message: "Inventory CSV exported", style: .success)
                    SystemActions.reveal(dest)
                    reload()
                } else {
                    let msg = CLIBridge.explainExit(code, operation: "Inventory CSV export")
                    workspace.toast = Toast(message: msg, style: .danger)
                    reportError = msg
                }
            }
        }
    }

    private func handleSpaceKeyPress() {
        // Quick Look opens the file on disk, which a demo report does not have.
        guard !workspace.demoMode,
              let selectedReport = selectedReports.first,
              let url = ReportLibrary().url(profile: workspace.profile, reportName: selectedReport) else {
            return
        }
        quickLookURL = url
        showQuickLook = true
    }

    private func updateAvailableProfiles() {
        let profileTokens = Set(reports.compactMap { report in
            Self.profile(fromReportFilename: report.name)
        })
        availableProfiles = Array(profileTokens).sorted()
    }

    /// The profile in a report's filename, written `<prefix><profile>_<yyyy-MM-dd>…`
    /// ("report_meridian-prod_2026-04-24_073305.xlsx"). Everything between the
    /// prefix and the date is the profile, so a hyphen or underscore in it stays;
    /// profile names allow both, and treating any hyphen as a date dropped every
    /// such profile from the menu. Without a date, the first `_` segment is taken.
    /// Nil for an unknown prefix, or when no profile precedes the date.
    nonisolated static func profile(fromReportFilename filename: String) -> String? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let lowered = stem.lowercased()
        // Longest first, so "jamf_report_prod_..." yields "prod", not "report".
        let knownPrefixes = [
            "jamf_report_", "school_report_", "school-report_",
            "report_", "compliance_", "mobile_", "inventory_",
        ]
        guard let prefix = knownPrefixes.first(where: { lowered.hasPrefix($0) }) else {
            return nil
        }
        let rest = String(stem.dropFirst(prefix.count))
        let profile: Substring
        if let date = rest.range(of: #"(^|_)\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            profile = rest[..<date.lowerBound]
        } else {
            profile = rest.split(separator: "_").first ?? ""
        }
        guard !profile.isEmpty, !profile.allSatisfy(\.isNumber) else { return nil }
        return String(profile)
    }
}

extension Notification.Name {
    static let requestOverviewTab = Notification.Name("JamfReports.requestOverviewTab")
}

/// Mutable single-value reference for capturing the SHA-256 fingerprint from
/// the engine's log stream so it can be displayed in the report-ready toast.
/// Boxed so the closure can mutate it across actor hops without needing
/// `@MainActor`-isolated state on the call site.
@MainActor
private final class HashBox {
    var value: String?
}
