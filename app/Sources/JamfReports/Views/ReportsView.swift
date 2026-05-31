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

    private var reportsDirectory: URL {
        let workspace = ProfileService.workspaceURL(for: workspace.profile)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Jamf-Reports")
        return workspace.appendingPathComponent("Generated Reports", isDirectory: true)
    }

    private var filteredReports: [Report] {
        guard filter != "All" else { return reports }
        return reports.filter { $0.name.lowercased().hasSuffix(".\(filter.lowercased())") }
    }

    private var snapshotCount: Int {
        snapshotFamilies.reduce(0) { $0 + $1.snapshotCount }
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
                        TableColumn("Devices") { r in Mono(text: "\(r.devices)") }
                        TableColumn("Size") { r in Mono(text: r.size) }
                        TableColumn("Generated") { r in Mono(text: r.date) }
                    }
                    .frame(minHeight: 360)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: Report.ID.self) { selection in
                        if let reportID = selection.first,
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
        .onAppear(perform: reload)
        .onChange(of: workspace.profile) { _, _ in reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageHeader(
                kicker: "Generated Reports",
                breadcrumbs: [Breadcrumb(label: "Overview", action: { navigateToOverview() })],
                title: "\(reports.count) reports archived",
                subtitle: "~/Jamf-Reports/\(workspace.profile)/Generated Reports/"
            ) {
                AnyView(
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
                        PNPButton(title: "Reveal in Finder", icon: "folder") {
                            SystemActions.openFolder(reportsDirectory)
                        }
                        .help("Open the Generated Reports folder in Finder")
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
                            ? "Available in live mode only"
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
                            ? "Available in live mode only"
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
                            ? "Available in live mode only"
                            : "Export a wide CSV of all computer inventory"
                        )
                    }
                )
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
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Colors.gold)
                .accessibilityHidden(true)
            Text("No reports yet — run Generate from Overview")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Colors.fg)
            PNPButton(title: "Go to Overview", icon: "house", style: .gold) {
                requestOverviewTab()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .accessibilityLabel("No reports yet. Use Go to Overview to run Generate.")
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
                sub: "\(snapshotFamilies.count) families"
            )
            StatTile(
                label: "Auto-archived",
                value: "\(reportStats.archivedCount)",
                sub: "Moved to /archive"
            )
        }
    }

    private func reload() {
        let library = ReportLibrary()
        reports = library.list(profile: workspace.profile)
        reportStats = library.stats(profile: workspace.profile)
        snapshotFamilies = SnapshotArchiveService().families(profile: workspace.profile)
        selectedReports = selectedReports.intersection(Set(reports.map(\.id)))
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

    @MainActor
    private func generateHTMLReport() {
        let profile = workspace.profile
        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
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
                // Status-bar race guard — see comment in HealthCheckView.runAudit.
                let code: Int32
                do {
                    code = try await bridge.generateHTML(profile: profile, outFile: outPath) { [weak workspace] line in
                        if let parsed = GenerateSheetState.parseSHA256LogLine(line.text) {
                            Task { @MainActor in hashBox.value = parsed.hash }
                        }
                        Task { @MainActor in
                            guard let workspace, self.isGeneratingHTML else { return }
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
                    workspace.toast = Toast(message: "HTML generation failed · exit \(code)", style: .danger)
                    reportError = "HTML generation failed (exit \(code))"
                }
            }
        }
    }

    @MainActor
    private func generatePDFReport() {
        let profile = workspace.profile
        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
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
                    code = try await bridge.generatePDF(profile: profile, outFile: outPath) { [weak workspace] line in
                        Task { @MainActor in
                            guard let workspace, self.isGeneratingPDF else { return }
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
                    workspace.toast = Toast(message: "PDF generation failed · exit \(code)", style: .danger)
                    reportError = "PDF generation failed (exit \(code))"
                }
            }
        }
    }

    @MainActor
    private func runExportInventoryCSV() {
        let profile = workspace.profile
        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
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
                    code = try await bridge.exportInventoryCSV(profile: profile, outFile: outPath) { [weak workspace] line in
                        Task { @MainActor in
                            guard let workspace, self.isExportingCSV else { return }
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
                    workspace.toast = Toast(message: "CSV export failed · exit \(code)", style: .danger)
                    reportError = "Inventory CSV export failed (exit \(code))"
                }
            }
        }
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
