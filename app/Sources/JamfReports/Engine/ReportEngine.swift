import Foundation
import CoreGraphics
import CryptoKit

// MARK: - ReportEngine

/// Top-level orchestrator replacing the Python `cmd_generate`, `cmd_collect`,
/// `cmd_html`, `cmd_inventory_csv`, and school command functions.
///
/// Coordinates `CoreDashboard` (jamf-cli JSON sheets), `CSVDashboard` (CSV sheets),
/// chart rendering, and OOXML writing. Writes the final `.xlsx` atomically.
///
/// Usage:
/// ```swift
/// let engine = ReportEngine(config: config, dataDir: workspaceDataURL)
/// try await engine.generate(csvURL: csvURL, outputURL: reportURL)
/// ```
struct ReportEngine: Sendable {

    let config: ReportConfig
    /// Directory containing cached jamf-cli JSON snapshots (`jamf_cli.data_dir`).
    let dataDir: URL

    // MARK: - Public API: generate

    /// Generate an `.xlsx` report and write it atomically to `outputURL`.
    ///
    /// - Parameters:
    ///   - csvURL: Optional path to a Jamf Pro CSV export.
    ///             When `nil`, only jamf-cli sheets are generated.
    ///   - outputURL: Destination path for the `.xlsx` file.
    ///                Parent directory is created if absent.
    ///   - template: The `ReportTemplate` that controls which sheets are included and
    ///               in what order. Defaults to `ExecutiveTemplate()` — preserving the
    ///               legacy behavior for callers that do not supply a template.
    ///   - onLine: Optional streaming log callback. Post-generate side-effect warnings
    ///             (archive rotation, CSV snapshot, summary JSON) are routed here when
    ///             provided, so callers with a live log view (e.g. GenerateSheet) see them.
    func generate(
        csvURL: URL?,
        outputURL: URL,
        template: any ReportTemplate = ExecutiveTemplate(),
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) async throws {
        let workbook = Workbook(accentColor: config.branding?.resolvedAccentColor ?? "#2D5EA2")

        // Capture provenance once per run — jamf-cli version + tenant URL are best-effort.
        let jamfCLIURL = ExecutableLocator.locate("jamf-cli")
        let profile = config.jamfCli?.resolvedProfile ?? ""
        let prov = await Provenance.current(
            profile: profile,
            jamfCLIURL: jamfCLIURL,
            dataDir: dataDir
        )

        // CoreDashboard sheets (jamf-cli JSON)
        // Build the sheet registry from the dashboard's plan, then dispatch in
        // template order rather than plan order. Unknown SheetID values are skipped
        // with a warning — they are engine-team follow-ups, not fatal errors.
        let core = CoreDashboard(config: config, dataDir: dataDir, workbook: workbook,
                                 provenance: prov)
        let registry = SheetRegistry(plan: core.sheetPlan)
        let (writtenCore, unimplementedSheets) = registry.writeSelected(template: template)
        for sheetID in unimplementedSheets {
            let msg = "[warn] template '\(template.identifier)': SheetID '\(sheetID.rawValue)' " +
                      "has no writer in CoreDashboard — skipped (engine follow-up required)"
            AppLogger.engine.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
        }
        if writtenCore.isEmpty {
            // No cached data at all — not an error if CSV was provided.
            if csvURL == nil {
                throw ReportEngineError.noCachedData(dataDir)
            }
        }

        // CSVDashboard sheets
        if let csvURL {
            let csvData = try Data(contentsOf: csvURL)
            guard let csv = CSVDashboard(
                config: config,
                csvData: csvData,
                workbook: workbook,
                currentCSVURL: csvURL
            ) else {
                throw ReportEngineError.csvParseFailed(csvURL)
            }
            csv.writeAll()
        }

        // Chart sheet — render PNG charts from trend summaries and embed in workbook.
        if config.charts?.isEnabled == true,
           let summariesDir = resolvedSummariesDir(outputURL: outputURL) {
            renderChartSheet(workbook: workbook, summariesDir: summariesDir)
        }

        // Write the workbook atomically.
        try workbook.write(to: outputURL)

        // Write a SHA-256 manifest alongside the artifact for federal compliance.
        writeManifest(for: outputURL, profile: profile, template: template.identifier)

        // Archive CSV snapshot only after a successful write — avoids archiving when generate fails.
        if let csvURL,
           config.charts?.archiveCurrentCsv == true,
           let historicalDir = resolvedHistoricalDir(outputURL: outputURL) {
            archiveCurrentCSV(csvURL: csvURL, historicalDir: historicalDir, onLine: onLine)
        }

        // Post-write: archive old runs, emit trend summary.
        let outputDir = outputURL.deletingLastPathComponent()
        let stem = stemFromURL(outputURL)
        if config.output?.isArchiveEnabled == true {
            let archiveDir = resolvedArchiveDir(outputDir: outputDir)
            let keep = config.output?.resolvedKeepLatestRuns ?? 10
            archiveOldRuns(
                outputDir: outputDir,
                archiveDir: archiveDir,
                stem: stem,
                keep: keep,
                onLine: onLine
            )
        }

        if let summariesDir = resolvedSummariesDir(outputURL: outputURL) {
            emitSummaryJSON(summariesDir: summariesDir, provenance: prov, onLine: onLine)
        }
    }

    // MARK: - Output rotation (mirrors Python _archive_old_output_runs)

    /// Move older timestamped report files into `archiveDir`, keeping `keep` newest.
    ///
    /// Supports 6 date suffix patterns:
    ///   `YYYY-MM-DD`, `YYYYMMDD`, `YYYY-MM-DD_HHMMSS`,
    ///   `YYYY-MM-DDTHHMMSS`, `YYYY-MM-DDTHH_MM_SS`, `YYYY-MM-DDTHH-MM-SS`
    /// Falls back to file mtime when no date pattern is found.
    ///
    /// - Parameter onLine: When provided, warnings are emitted here instead of (only) via
    ///   `print`, so live log views (e.g. GenerateSheet) display side-effect failures.
    func archiveOldRuns(
        outputDir: URL,
        archiveDir: URL,
        stem: String,
        keep: Int,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let candidates = files.filter {
            $0.pathExtension == "xlsx" && $0.lastPathComponent.hasPrefix(stem)
        }

        let sorted = candidates.sorted {
            dateFromFilename($0, fm: fm) > dateFromFilename($1, fm: fm)
        }

        guard sorted.count > keep else { return }

        do {
            try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        } catch {
            let msg = "[warn] Could not create archive dir \(archiveDir.lastPathComponent): \(error)"
            AppLogger.engine.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return
        }

        for file in sorted.dropFirst(keep) {
            let dest = archiveDir.appendingPathComponent(file.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: file, to: dest)
            } catch {
                let msg = "[warn] Could not archive \(file.lastPathComponent): \(error)"
                AppLogger.engine.warning("\(msg, privacy: .private)")
                print(msg)
                onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            }
        }
    }

    // MARK: - CSV archival (mirrors Python _archive_csv_snapshot)

    /// Copy `csvURL` into `historicalDir` with a timestamp suffix.
    ///
    /// Written as `computers_YYYY-MM-DD_HHmmss.csv`. Failures are logged but do
    /// not abort the generate run.
    ///
    /// - Parameter onLine: When provided, warnings are emitted here in addition to
    ///   `print` so live log views display side-effect failures.
    func archiveCurrentCSV(
        csvURL: URL,
        historicalDir: URL,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: historicalDir, withIntermediateDirectories: true)
        } catch {
            let msg = "[warn] Could not create historical dir: \(error)"
            AppLogger.engine.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let ts = formatter.string(from: Date())
        let dest = historicalDir.appendingPathComponent("computers_\(ts).csv")
        do {
            try fm.copyItem(at: csvURL, to: dest)
        } catch {
            let msg = "[warn] Could not archive CSV snapshot: \(error)"
            AppLogger.engine.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
        }
    }

    // MARK: - Summary JSON emission (mirrors Python _build_summary_from_bridge)

    /// Write `summary_YYYY-MM-DD.json` to `summariesDir` from cached jamf-cli snapshots.
    ///
    /// Skips if a valid same-day file already exists (first run of day wins, matching Python
    /// default non-force behavior). Fields that require CSV data (compliancePct, crowdstrikePct)
    /// are omitted so TrendStore skips them rather than rendering a flat 0% line.
    ///
    /// - Parameters:
    ///   - summariesDir: Directory to write the summary file into.
    ///   - provenance: Run provenance captured by the caller; embedded in the JSON output.
    ///   - onLine: When provided, warnings are emitted here in addition to `print`.
    func emitSummaryJSON(
        summariesDir: URL,
        provenance: Provenance? = nil,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        } catch {
            let msg = "[warn] Could not create summaries dir: \(error)"
            AppLogger.engine.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return
        }

        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let summaryFile = summariesDir.appendingPathComponent("summary_\(today).json")

        if fm.fileExists(atPath: summaryFile.path),
           let data = try? Data(contentsOf: summaryFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["date"] != nil, obj["totalDevices"] != nil, obj["source"] != nil {
            return  // Valid same-day summary already exists.
        }

        guard let summary = buildSummaryFromCLI(date: today, provenance: provenance) else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(summary)
            try data.write(to: summaryFile, options: .atomic)
        } catch {
            let msg = "[warn] could not write summary JSON: \(error.localizedDescription)"
            AppLogger.engine.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
        }
    }

    // MARK: - Private helpers

    private func buildSummaryFromCLI(date: String, provenance: Provenance? = nil) -> DailySummary? {
        // Load each snapshot kind once; cache by kind name to avoid repeated I/O + JSON parses.
        var snapshotCache: [String: Data] = [:]
        func cachedData(kind: String) -> Data? {
            if let hit = snapshotCache[kind] { return hit }
            if let d = try? Self.loadLatestSnapshotData(kind: kind, dataDir: dataDir) {
                snapshotCache[kind] = d
                return d
            }
            return nil
        }

        var totalDevices = 0
        // nil = source data absent or failed to decode; not the same as 0%.
        var fileVaultPct: Double? = nil
        // v3.5 fleet-health expansion (all optional — populated only when
        // the security summary section carries the source counts).
        var fileVaultCount: Int?
        var sipCount: Int?
        var firewallCount: Int?
        var gatekeeperCount: Int?

        // Security report: total_devices + per-control counts
        if let secData = cachedData(kind: "security"),
           let items = try? JSONDecoder().decode([SecurityReportItem].self, from: secData) {
            for item in items {
                if case .summary(let s) = item {
                    totalDevices = s.data.totalDevices ?? 0
                    fileVaultCount = s.data.fileVaultEncrypted
                    sipCount = s.data.sipEnabled
                    firewallCount = s.data.firewallEnabled
                    gatekeeperCount = s.data.gatekeeperEnabled
                    if let pctStr = s.data.fileVaultEncryptedPct,
                       let pct = parsePercentString(pctStr) {
                        fileVaultPct = pct
                    } else if totalDevices > 0, let enc = s.data.fileVaultEncrypted {
                        fileVaultPct = Double(enc) / Double(totalDevices) * 100.0
                    }
                    // If neither source is available fileVaultPct remains nil.
                    break
                }
            }
        }

        // Fallback: inventory-summary for total device count
        if totalDevices == 0,
           let invData = cachedData(kind: "inventory-summary"),
           let rows = try? JSONDecoder().decode([InventorySummaryRow].self, from: invData) {
            totalDevices = rows.reduce(0) { $0 + $1.count }
        }

        guard totalDevices > 0 else { return nil }

        // Stale count from device-compliance
        var staleCount = 0
        if let compData = cachedData(kind: "device-compliance"),
           let rows = try? JSONDecoder().decode([DeviceComplianceRow].self, from: compData) {
            staleCount = rows.filter { $0.stale == true }.count
        }

        // OS current % — requires current_versions config; nil when unconfigured or
        // inventory data is absent (not the same as 0%).
        var osCurrentPct: Double? = nil
        let currentVersions: [String] = config.customEas?
            .first { $0.type == .version && $0.name.lowercased().contains("macos") }
            .flatMap { $0.currentVersions }?.map { $0.lowercased() } ?? []

        if !currentVersions.isEmpty,
           let invData = cachedData(kind: "inventory-summary"),
           let rows = try? JSONDecoder().decode([InventorySummaryRow].self, from: invData),
           totalDevices > 0 {
            let current = rows
                .filter { row in currentVersions.contains { row.osVersion.lowercased().hasPrefix($0) } }
                .reduce(0) { $0 + $1.count }
            osCurrentPct = Double(current) / Double(totalDevices) * 100.0
        }

        // Patch % — average compliance_pct across patch-status rows; nil when
        // patch-status data is absent (not the same as 0%).
        var patchPct: Double? = nil
        if let patchData = cachedData(kind: "patch-status"),
           let rows = try? JSONDecoder().decode([PatchStatusRow].self, from: patchData) {
            let values = rows.compactMap { parsePercentString($0.compliancePct) }
            if !values.isEmpty {
                patchPct = values.reduce(0, +) / Double(values.count)
            }
        }

        // Derive per-control percentages and the weighted v3.5 security
        // score from the same counts the summary section provided. These are
        // all optional — when a tenant lacks any of these signals the field
        // is left nil so consumers (TrendStore, SecurityPostureView) can
        // distinguish "no data" from a zero.
        let sipPct = pct(of: sipCount, total: totalDevices)
        let firewallPct = pct(of: firewallCount, total: totalDevices)
        let gatekeeperPct = pct(of: gatekeeperCount, total: totalDevices)

        var compliantCounts: [SecurityScore.Metric: Int] = [:]
        if let n = fileVaultCount { compliantCounts[.fileVault] = n }
        if let n = sipCount { compliantCounts[.sip] = n }
        if let n = firewallCount { compliantCounts[.firewall] = n }
        let score = SecurityScoreCalculator.score(
            input: .init(totalDevices: totalDevices, compliantCounts: compliantCounts)
        )
        // Score is only meaningful when at least one metric contributed.
        let securityScore: Double? = score.available.isEmpty ? nil : score.value

        // P0 = devices missing FileVault, SIP, or Firewall. P1 = Gatekeeper
        // gaps. Mirrors v3.5 SecurityPostureView action-items taxonomy.
        let p0 = [fileVaultCount, sipCount, firewallCount]
            .compactMap { $0 }
            .map { totalDevices - $0 }
            .reduce(0, +)
        let p1 = gatekeeperCount.map { totalDevices - $0 } ?? 0

        return DailySummary(
            date: date,
            totalDevices: totalDevices,
            fileVaultPct: fileVaultPct.map(round1),
            compliancePct: nil,
            staleCount: staleCount,
            osCurrentPct: osCurrentPct.map(round1),
            crowdstrikePct: nil,
            patchPct: patchPct.map(round1),
            source: "jamf-cli",
            sipPct: sipPct.map(round1),
            firewallPct: firewallPct.map(round1),
            gatekeeperPct: gatekeeperPct.map(round1),
            securityScore: securityScore.map(round1),
            actionItemsP0: fileVaultCount != nil ? p0 : nil,
            actionItemsP1: gatekeeperCount.map { _ in p1 }
        )
    }

    private func pct(of count: Int?, total: Int) -> Double? {
        guard let count, total > 0 else { return nil }
        return Double(count) / Double(total) * 100
    }

    private func parsePercentString(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        return Double(trimmed)
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    // MARK: - Chart sheet rendering

    /// Render trend charts from daily summary snapshots and embed in a "Charts" worksheet.
    ///
    /// Reads `DailySummary` JSON files from `summariesDir`. With 2+ data points produces
    /// line/stacked-area charts. With 1 point produces a bar chart.
    ///
    /// Respects:
    /// - `charts.os_adoption.per_major_charts` — adds one series per major OS version
    ///   (using `ChartPalette.majorVersionColors`).
    /// - `charts.compliance_trend.bands` — uses band labels/colors for compliance stacked area.
    /// - `charts.device_state_trend.enabled` — renders managed/stale trend line chart.
    func renderChartSheet(workbook: Workbook, summariesDir: URL) {
        let summaries = SummaryJSONParser.parseDirectory(summariesDir)
            .sorted { $0.parsedDate < $1.parsedDate }
        guard !summaries.isEmpty else { return }

        let ws = workbook.addSheet("Charts")
        ws.setColumnWidth(0, 0, 30)
        var embedRow = 0

        // --- Fleet size trend ---
        let fleetPoints = summaries.compactMap { s -> (date: Date, value: Double)? in
            guard s.totalDevices > 0 else { return nil }
            return (s.parsedDate, Double(s.totalDevices))
        }
        if !fleetPoints.isEmpty {
            let series = ChartSeries(label: "Total Devices",
                                     color: ChartPalette.color(for: 0), points: fleetPoints)
            if let png = ChartRenderer.lineChart(series: [series], title: "Fleet Size Trend") {
                ws.insertImage(row: embedRow, col: 0, data: png, filename: "fleet_trend.png")
                embedRow += 20
            }
        }

        // --- FileVault / patch trend (security metrics) ---
        let fvPoints = summaries.compactMap { s -> (date: Date, value: Double)? in
            guard let pct = s.fileVaultPct else { return nil }
            return (s.parsedDate, pct)
        }
        let patchPoints = summaries.compactMap { s -> (date: Date, value: Double)? in
            guard let pct = s.patchPct else { return nil }
            return (s.parsedDate, pct)
        }
        var secSeries: [ChartSeries] = []
        if !fvPoints.isEmpty {
            secSeries.append(ChartSeries(label: "FileVault %",
                                         color: ChartPalette.color(for: 1), points: fvPoints))
        }
        if !patchPoints.isEmpty {
            secSeries.append(ChartSeries(label: "Patch Compliance %",
                                         color: ChartPalette.color(for: 2), points: patchPoints))
        }
        if !secSeries.isEmpty {
            if let png = ChartRenderer.lineChart(series: secSeries,
                                                  title: "Security Metric Trends",
                                                  yLabel: "Percent") {
                ws.insertImage(row: embedRow, col: 0, data: png, filename: "security_trend.png")
                embedRow += 20
            }
        }

        // --- Device state trend (managed / stale) ---
        if config.charts?.deviceStateTrend?.enabled == true {
            let stalePoints = summaries.compactMap { s -> (date: Date, value: Double)? in
                return (s.parsedDate, Double(s.staleCount))
            }
            if !stalePoints.isEmpty {
                let series = ChartSeries(label: "Stale Devices",
                                         color: ChartPalette.color(for: 3), points: stalePoints)
                if let png = ChartRenderer.lineChart(series: [series],
                                                      title: "Stale Device Count Trend") {
                    ws.insertImage(row: embedRow, col: 0, data: png, filename: "stale_trend.png")
                    embedRow += 20
                }
            }
        }

        // --- Compliance trend (stacked area with configurable bands) ---
        if let bands = config.charts?.complianceTrend?.bands, !bands.isEmpty {
            let bandSeries: [ChartSeries] = bands.enumerated().compactMap { (idx, band) -> ChartSeries? in
                let color = cgColorFromHex(band.color) ?? ChartPalette.color(for: idx)
                let pts = summaries.compactMap { s -> (date: Date, value: Double)? in
                    guard let pct = s.compliancePct else { return nil }
                    let within = pct >= Double(band.minFailures) && pct <= Double(band.maxFailures)
                    return within ? (s.parsedDate, 1.0) : nil
                }
                return pts.isEmpty ? nil : ChartSeries(label: band.label, color: color, points: pts)
            }
            if !bandSeries.isEmpty {
                if let png = ChartRenderer.stackedAreaChart(series: bandSeries,
                                                             title: "Compliance Band Distribution") {
                    ws.insertImage(row: embedRow, col: 0, data: png,
                                   filename: "compliance_bands.png")
                    embedRow += 20
                }
            }
        }

        // --- OS adoption (per-major when enabled) ---
        if config.charts?.osAdoption?.perMajorCharts == true {
            var majorData: [String: Double] = [:]
            if let invData = try? Self.loadLatestSnapshotData(kind: "inventory-summary",
                                                              dataDir: dataDir),
               let rows = try? JSONDecoder().decode([InventorySummaryRow].self, from: invData) {
                let total = rows.reduce(0) { $0 + $1.count }
                for invRow in rows {
                    let major = String(invRow.osVersion.prefix(while: { $0.isNumber }))
                    majorData[major, default: 0] += Double(invRow.count)
                }
                if total > 0 {
                    majorData = majorData.mapValues { $0 / Double(total) * 100 }
                }
            } else if let pct = summaries.last?.osCurrentPct {
                majorData["Current"] = pct
                majorData["Other"] = max(0, 100 - pct)
            }
            if !majorData.isEmpty {
                let sortedMajor = majorData.sorted { $0.key > $1.key }
                let barData = BarChartData(
                    categories: sortedMajor.map(\.key),
                    values: sortedMajor.map(\.value),
                    colors: sortedMajor.map { ChartPalette.colorForMajorVersion($0.key) }
                )
                if let png = ChartRenderer.barChart(data: barData,
                                                     title: "OS Adoption by Major Version") {
                    ws.insertImage(row: embedRow, col: 0, data: png, filename: "os_adoption.png")
                }
            }
        }
    }

    /// Parse a hex color string (#RRGGBB) into a `CGColor`. Returns nil on malformed input.
    private func cgColorFromHex(_ hex: String) -> CGColor? {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard h.count == 6,
              let rgb = UInt32(h, radix: 16) else { return nil }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    private func resolvedHistoricalDir(outputURL: URL) -> URL? {
        let raw = config.charts?.historicalCsvDir ?? "snapshots"
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        let workspace = outputURL.deletingLastPathComponent().deletingLastPathComponent()
        return workspace.appendingPathComponent(raw, isDirectory: true)
    }

    private func resolvedSummariesDir(outputURL: URL) -> URL? {
        resolvedHistoricalDir(outputURL: outputURL)?
            .appendingPathComponent("summaries", isDirectory: true)
    }

    private func resolvedArchiveDir(outputDir: URL) -> URL {
        let raw = config.output?.archiveDir?.trimmingCharacters(in: .whitespaces) ?? ""
        if !raw.isEmpty {
            if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
            return outputDir.appendingPathComponent(raw, isDirectory: true)
        }
        return outputDir.appendingPathComponent("archive", isDirectory: true)
    }

    private func stemFromURL(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        // Strip trailing _YYYY-MM-DD or _YYYY-MM-DD_HHmmss timestamp to recover stem.
        let patterns = [
            #"_\d{4}-\d{2}-\d{2}T\d{6}$"#,
            #"_\d{4}-\d{2}-\d{2}_\d{6}$"#,
            #"_\d{8}$"#,
            #"_\d{4}-\d{2}-\d{2}$"#,
        ]
        for pattern in patterns {
            if let range = name.range(of: pattern, options: .regularExpression) {
                name = String(name[..<range.lowerBound])
                break
            }
        }
        return name
    }

    private func dateFromFilename(_ url: URL, fm: FileManager) -> Date {
        let name = url.deletingPathExtension().lastPathComponent
        // Patterns ordered from most-specific to least-specific.
        // Supports 6 variants:
        //   YYYY-MM-DDTHHMMSS     — compact ISO-8601 (original)
        //   YYYY-MM-DDTHH_MM_SS   — Jamf export default (underscores in time)
        //   YYYY-MM-DDTHH-MM-SS   — hyphen-separated time (some exporter versions)
        //   YYYY-MM-DD_HHMMSS     — underscore separator, compact time
        //   YYYYMMDD              — compact date only
        //   YYYY-MM-DD            — ISO date only
        let patterns: [(regex: String, fmt: String)] = [
            (#"(\d{4}-\d{2}-\d{2})T(\d{2})(\d{2})(\d{2})$"#,       "yyyy-MM-dd'T'HHmmss"),
            (#"(\d{4}-\d{2}-\d{2})T(\d{2})_(\d{2})_(\d{2})$"#,     "yyyy-MM-dd'T'HH_mm_ss"),
            (#"(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})$"#,     "yyyy-MM-dd'T'HH-mm-ss"),
            (#"(\d{4}-\d{2}-\d{2})_(\d{6})$"#,                      "yyyy-MM-dd_HHmmss"),
            (#"(\d{8})$"#,                                           "yyyyMMdd"),
            (#"(\d{4}-\d{2}-\d{2})$"#,                              "yyyy-MM-dd"),
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        for (pattern, fmt) in patterns {
            guard let range = name.range(of: pattern, options: .regularExpression) else { continue }
            let match = String(name[range])
            formatter.dateFormat = fmt
            if let date = formatter.date(from: match) { return date }
        }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: - Public API: collect

    /// Run all jamf-cli pro collect commands and save JSON snapshots to `dataDir`.
    ///
    /// Mirrors the Python `cmd_collect` function. Each jamf-cli command is run via
    /// subprocess (jamf-cli is a Go binary — not Python). Results are saved as named
    /// JSON files under `dataDir/<kind>/`.
    ///
    /// - Parameters:
    ///   - profile: jamf-cli profile slug.
    ///   - workspacePaths: Typed path constants for the workspace.
    ///   - onLine: Progress callback; receives log lines in real time.
    /// Per-device commands that hit every device under management and are
    /// expensive on on-prem Jamf servers. The Settings "Skip expensive
    /// collections" toggle filters these out of the manual refresh path.
    /// Scheduled collects (run via LaunchAgent → main.swift) ignore the
    /// toggle and always include them.
    static let expensivePerDeviceKinds: Set<String> = [
        "ea-results",
        "patch-device-failures",
        "update-device-failures",
        "device-compliance"
    ]

    static func collect(
        profile: String,
        workspacePaths: WorkspacePaths.Type,
        skipExpensive: Bool = false,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws {
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            throw ReportEngineError.jamfCLINotFound
        }
        guard ProfileService.isValid(profile) else {
            throw ReportEngineError.invalidProfile(profile)
        }
        let dataDir = try workspacePaths.dataDir(for: profile)
        // Respect use_cached_data: when false, a failed collect is fatal for that kind.
        let useCachedData: Bool
        if let workspace = ProfileService.workspaceURL(for: profile),
           let config = try? ConfigLoader.load(
               from: workspace.appendingPathComponent("config.yaml")
           ) {
            useCachedData = config.jamfCli?.isCachedDataEnabled ?? true
        } else {
            useCachedData = true
        }

        // Commands to collect and their snapshot kind names.
        let commands: [(args: [String], kind: String)] = [
            (["-p", profile, "pro", "overview", "--output", "json"], "overview"),
            (["-p", profile, "pro", "report", "security", "--output", "json"], "security"),
            (["-p", profile, "pro", "report", "patch-status", "--output", "json"], "patch-status"),
            (["-p", profile, "pro", "report", "patch-status", "--scan-failures", "--output", "json"],
             "patch-device-failures"),
            (["-p", profile, "pro", "report", "update-status", "--output", "json"], "update-status"),
            (["-p", profile, "pro", "report", "update-status", "--scan-failures", "--output", "json"],
             "update-device-failures"),
            (["-p", profile, "pro", "report", "inventory-summary", "--output", "json"],
             "inventory-summary"),
            (["-p", profile, "pro", "report", "device-compliance", "--output", "json"],
             "device-compliance"),
            (["-p", profile, "pro", "report", "policy-status", "--output", "json"], "policy-status"),
            (["-p", profile, "pro", "classic-macos-profiles", "list", "--output", "json"],
             "classic-macos-profiles"),
            (["-p", profile, "pro", "report", "app-status", "--output", "json"], "app-status"),
            (["-p", profile, "pro", "report", "software-installs", "--output", "json"],
             "software-installs"),
            (["-p", profile, "pro", "computer-extension-attributes", "list", "--output", "json"],
             "computer-extension-attributes"),
            (["-p", profile, "pro", "report", "ea-results", "--all", "--output", "json"],
             "ea-results"),
            (["-p", profile, "pro", "report", "profile-status", "--output", "json"],
             "profile-status"),
            (["-p", profile, "pro", "mobile-devices", "list", "--output", "json"],
             "mobile-devices-list"),
            (["-p", profile, "pro", "report", "compliance-devices", "--output", "json"],
             "compliance-devices"),
            (["-p", profile, "pro", "report", "compliance-rules", "--output", "json"],
             "compliance-rules"),
            (["-p", profile, "pro", "report", "ddm-status", "--output", "json"],
             "ddm-status"),
            (["-p", profile, "pro", "report", "blueprint-status", "--output", "json"],
             "blueprint-status"),
            (["-p", profile, "pro", "computers", "list", "--output", "json"], "computers"),
            (["-p", profile, "pro", "policies", "list", "--output", "json"], "policies"),
            (["-p", profile, "pro", "scripts", "list", "--output", "json"], "scripts"),
            (["-p", profile, "pro", "packages", "list", "--output", "json"], "packages"),
            (["-p", profile, "pro", "smart-computer-groups", "list", "--output", "json"],
             "smart-computer-groups"),
            (["-p", profile, "pro", "sites", "list", "--output", "json"], "sites"),
            (["-p", profile, "pro", "buildings", "list", "--output", "json"], "buildings"),
            (["-p", profile, "pro", "departments", "list", "--output", "json"], "departments"),
        ]

        let plannedCommands: [(args: [String], kind: String)]
        if skipExpensive {
            plannedCommands = commands.filter { !Self.expensivePerDeviceKinds.contains($0.kind) }
            let skipped = commands
                .filter { Self.expensivePerDeviceKinds.contains($0.kind) }
                .map(\.kind)
                .joined(separator: ", ")
            onLine(.init(
                timestamp: Date(), level: .info,
                text: "[info] skipping per-device commands (\(skipped)) — Settings: Skip expensive collections"
            ))
        } else {
            plannedCommands = commands
        }

        let bridge = CLIBridge()
        for (args, kind) in plannedCommands {
            onLine(.init(
                timestamp: Date(), level: .info,
                text: "[info] collecting \(kind) for \(profile)"
            ))
            let (exitCode, data) = await bridge.runAndCapture(
                executable: bin, arguments: args,
                environment: CLIBridge.environmentForJamfCLI(),
                onLine: onLine
            )
            if exitCode == 0, !data.isEmpty {
                try saveSnapshot(data: data, kind: kind, dataDir: dataDir)
                onLine(.init(timestamp: Date(), level: .ok,
                             text: "[ok] \(kind): \(data.count) bytes"))
            } else if useCachedData {
                // use_cached_data=true: warn and skip; cached snapshot (if any) used at generate time.
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] \(kind): exit \(exitCode) — skipped (using cached)"))
            } else {
                // use_cached_data=false: treat collect failure as fatal for this kind.
                onLine(.init(timestamp: Date(), level: .fail,
                             text: "[error] \(kind): exit \(exitCode) — failing (use_cached_data=false)"))
                throw ReportEngineError.collectFailed(kind: kind, exitCode: exitCode)
            }
        }
    }

    // MARK: - Public API: inventoryCSV

    /// Export a wide computer inventory CSV from cached jamf-cli data.
    ///
    /// Mirrors the Python `cmd_inventory_csv` function. Reads the computers list
    /// snapshot and emits one row per device with all available fields.
    ///
    /// - Parameters:
    ///   - profile: jamf-cli profile slug.
    ///   - workspacePaths: Typed path constants.
    ///   - outputURL: Destination `.csv` file path.
    static func inventoryCSV(
        profile: String,
        workspacePaths: WorkspacePaths.Type,
        outputURL: URL
    ) async throws {
        guard ProfileService.isValid(profile) else {
            throw ReportEngineError.invalidProfile(profile)
        }
        let dataDir = try workspacePaths.dataDir(for: profile)

        // Load the latest computers snapshot.
        let data = try loadLatestSnapshotData(
            kind: "computers",
            dataDir: dataDir
        )
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ReportEngineError.snapshotParseError("computers: \(error.localizedDescription)")
        }
        guard var rows = raw as? [[String: Any]] else {
            throw ReportEngineError.snapshotParseError("computers: unexpected JSON shape")
        }

        // Merge EA results snapshot when available.
        // Groups EA results by device name (Python uses computer_id; the fixture
        // and live CLI output both have device names and may have computer_id).
        rows = mergeEAResults(into: rows, dataDir: dataDir)

        // Collect base inventory columns first, then sorted EA columns.
        var baseCols: [String] = []
        var eaCols: Set<String> = []
        var seen: Set<String> = []
        for row in rows {
            for key in row.keys where !seen.contains(key) {
                seen.insert(key)
                if key.hasPrefix("ea:") {
                    eaCols.insert(key)
                } else {
                    baseCols.append(key)
                }
            }
        }
        baseCols.sort()
        let columns = baseCols + eaCols.sorted()

        // Build CSV text.
        var lines: [String] = []
        lines.append(columns.map { csvEscape($0.hasPrefix("ea:") ? String($0.dropFirst(3)) : $0) }
            .joined(separator: ","))
        for row in rows {
            let cells = columns.map { col -> String in
                let val = row[col]
                let str: String
                switch val {
                case let s as String: str = s
                case let n as Int: str = "\(n)"
                case let d as Double: str = "\(d)"
                case let b as Bool: str = b ? "true" : "false"
                default: str = ""
                }
                return csvEscape(str)
            }
            lines.append(cells.joined(separator: ","))
        }

        let csv = lines.joined(separator: "\n")
        let fm = FileManager.default
        try fm.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try csv.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Public API: generateHTML

    /// Generate a self-contained HTML instance report from cached jamf-cli data.
    ///
    /// Mirrors the Python `cmd_html` function. Reads cached JSON snapshots from
    /// `dataDir` and writes a single `.html` file with embedded Chart.js charts.
    ///
    /// - Parameters:
    ///   - config: Parsed `ReportConfig`.
    ///   - dataDir: Directory containing cached jamf-cli JSON snapshots.
    ///   - outputURL: Destination `.html` file path.
    ///   - template: The `ReportTemplate` controlling which HTML sections are included.
    ///               Defaults to `ExecutiveTemplate()` for backward compatibility.
    static func generateHTML(
        config: ReportConfig,
        dataDir: URL,
        outputURL: URL,
        template: any ReportTemplate = ExecutiveTemplate()
    ) async throws {
        let report = HtmlReport(config: config, dataDir: dataDir)
        try await report.generate(outputURL: outputURL, sections: template.htmlSections)
        // Write SHA-256 manifest alongside the HTML artifact.
        let profile = config.jamfCli?.resolvedProfile ?? ""
        writeManifestStatic(for: outputURL, profile: profile, template: template.identifier)
    }

    // MARK: - Public API: generatePDF

    /// Generate a self-contained PDF instance report from cached jamf-cli data.
    ///
    /// Builds the same HTML content as `generateHTML`, then converts it to a
    /// paginated PDF using `PDFExporter` (WKWebView + `createPDF`). The PDF is
    /// suitable for compliance evidence files — it is paginated to US Letter and
    /// honors `@media print` CSS overrides in the HTML template.
    ///
    /// PDF pagination follows `template.pdfPagination`:
    /// - `.compact` — minimal page breaks, low page count for NOC/daily ops.
    /// - `.standard` — one page break between major sections (general management).
    /// - `.sectionPerPage` — explicit break after every section (formal auditor packages).
    ///
    /// - Parameters:
    ///   - config: Parsed `ReportConfig`.
    ///   - dataDir: Directory containing cached jamf-cli JSON snapshots.
    ///   - outputURL: Destination `.pdf` file path.
    ///   - profileName: Active workspace profile slug (shown in provenance footer).
    ///   - template: The `ReportTemplate` controlling sections and pagination strategy.
    @MainActor
    static func generatePDF(
        config: ReportConfig,
        dataDir: URL,
        outputURL: URL,
        profileName: String = "",
        template: any ReportTemplate = ExecutiveTemplate()
    ) async throws {
        // Write HTML to a temp file so that WKWebView can resolve relative resource
        // URLs (Chart.js CDN is network-fetched; baseURL gives it the right origin).
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpHTML = tmpDir.appendingPathComponent(
            "jamf_report_pdf_\(UUID().uuidString).html"
        )
        let report = HtmlReport(config: config, dataDir: dataDir)
        try await report.generate(
            outputURL: tmpHTML,
            profileName: profileName,
            sections: template.htmlSections
        )
        defer { try? FileManager.default.removeItem(at: tmpHTML) }

        // Apply pagination strategy by injecting CSS page-break rules into the HTML
        // before passing to PDFExporter. WKWebView honors `page-break-after` in print.
        let htmlContent = try String(contentsOf: tmpHTML, encoding: .utf8)
        let paginatedHTML = applyPagination(
            html: htmlContent,
            strategy: template.pdfPagination
        )
        try await PDFExporter.export(htmlString: paginatedHTML, to: outputURL)
        // Write SHA-256 manifest alongside the PDF artifact.
        let profile = config.jamfCli?.resolvedProfile ?? ""
        writeManifestStatic(for: outputURL, profile: profile, template: template.identifier)
    }

    // MARK: - Pagination helper

    /// Inject CSS page-break rules into an HTML document based on the pagination strategy.
    ///
    /// - `.compact` — No modifications; minimal page count.
    /// - `.standard` — Adds a `<style>` block with `section { page-break-after: auto; }`
    ///   so the browser engine places natural breaks between major sections.
    /// - `.sectionPerPage` — Wraps every top-level `<section>` element in a div with
    ///   `page-break-after: always` by injecting a CSS rule. This produces one section
    ///   per page regardless of content height, suitable for formal auditor deliverables.
    ///
    /// Implementation note: CSS `page-break-after` is the CSS2.1 property recognized by
    /// WKWebView's `createPDF`. The CSS3 `break-after` alias also works but `page-break-after`
    /// has wider WKWebView support across macOS versions.
    static func applyPagination(html: String, strategy: PaginationStrategy) -> String {
        switch strategy {
        case .compact:
            return html
        case .standard:
            let style = "<style>section { page-break-after: auto; }</style>"
            return html.replacingOccurrences(of: "</head>", with: "\(style)\n</head>")
        case .sectionPerPage:
            let style = """
            <style>
            section { page-break-after: always; }
            section:last-of-type { page-break-after: avoid; }
            </style>
            """
            return html.replacingOccurrences(of: "</head>", with: "\(style)\n</head>")
        }
    }

    // MARK: - Public API: schoolCollect

    /// Run all jamf-cli school collect commands and save JSON snapshots.
    ///
    /// Mirrors the Python `cmd_school_collect` function.
    static func schoolCollect(
        profile: String,
        workspacePaths: WorkspacePaths.Type,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws {
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            throw ReportEngineError.jamfCLINotFound
        }
        guard ProfileService.isValid(profile) else {
            throw ReportEngineError.invalidProfile(profile)
        }
        let dataDir = try workspacePaths.dataDir(for: profile)

        let commands: [(args: [String], kind: String)] = [
            (["-p", profile, "school", "overview", "--output", "json"], "school-overview"),
            (["-p", profile, "school", "devices", "list", "--output", "json"], "school-devices"),
            (["-p", profile, "school", "device-groups", "list", "--output", "json"],
             "school-device-groups"),
            (["-p", profile, "school", "users", "list", "--output", "json"], "school-users"),
            (["-p", profile, "school", "classes", "list", "--output", "json"], "school-classes"),
            (["-p", profile, "school", "apps", "list", "--output", "json"], "school-apps"),
            (["-p", profile, "school", "profiles", "list", "--output", "json"], "school-profiles"),
            (["-p", profile, "school", "locations", "list", "--output", "json"], "school-locations"),
            (["-p", profile, "school", "ibeacons", "list", "--output", "json"], "school-ibeacons"),
            (["-p", profile, "school", "dep-devices", "list", "--output", "json"], "school-dep-devices"),
        ]

        let bridge = CLIBridge()
        for (args, kind) in commands {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] collecting \(kind) for \(profile)"))
            let (exitCode, data) = await bridge.runAndCapture(
                executable: bin, arguments: args,
                environment: CLIBridge.environmentForJamfCLI(),
                onLine: onLine
            )
            if exitCode == 0, !data.isEmpty {
                try saveSnapshot(data: data, kind: kind, dataDir: dataDir)
                onLine(.init(timestamp: Date(), level: .ok,
                             text: "[ok] \(kind): \(data.count) bytes"))
            } else {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] \(kind): exit \(exitCode) — skipped"))
            }
        }
    }

    // MARK: - Public API: protectCollect

    /// Run all jamf-cli protect collect commands and save JSON snapshots.
    ///
    /// Mirrors the Python protect collection flow. Only runs when `protect.enabled`
    /// is true in config. The Protect CLI uses a separate named profile (`protect.profile`)
    /// and its own `data_dir` path so protect snapshots don't overwrite pro snapshots.
    ///
    /// - Parameters:
    ///   - profile: jamf-cli protect profile slug.
    ///   - dataDir: Directory under which snapshots are written.
    ///   - onLine: Progress callback for log lines.
    static func protectCollect(
        profile: String,
        dataDir: URL,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws {
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            throw ReportEngineError.jamfCLINotFound
        }
        guard ProfileService.isValid(profile) else {
            throw ReportEngineError.invalidProfile(profile)
        }

        let commands: [(args: [String], kind: String)] = [
            (["-p", profile, "protect", "overview", "--output", "json"], "protect-overview"),
            (["-p", profile, "protect", "alerts", "list", "--output", "json"], "protect-alerts"),
            (["-p", profile, "protect", "computers", "list", "--output", "json"], "protect-computers"),
            (["-p", profile, "protect", "insights", "list", "--output", "json"], "protect-insights"),
        ]

        let bridge = CLIBridge()
        for (args, kind) in commands {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] collecting \(kind) for \(profile)"))
            let (exitCode, data) = await bridge.runAndCapture(
                executable: bin, arguments: args,
                environment: CLIBridge.environmentForJamfCLI(),
                onLine: onLine
            )
            if exitCode == 0, !data.isEmpty {
                try saveSnapshot(data: data, kind: kind, dataDir: dataDir)
                onLine(.init(timestamp: Date(), level: .ok,
                             text: "[ok] \(kind): \(data.count) bytes"))
            } else {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] \(kind): exit \(exitCode) — skipped"))
            }
        }
    }

    // MARK: - Public API: schoolGenerate

    /// Build a Jamf School Excel report from cached jamf-cli school data and/or a CSV export.
    ///
    /// Mirrors the Python `cmd_school_generate` function.
    static func schoolGenerate(
        config: ReportConfig,
        csvURL: URL?,
        dataDir: URL,
        outputURL: URL
    ) async throws {
        let workbook = Workbook(accentColor: config.branding?.resolvedAccentColor ?? "#2D5EA2")
        let core = SchoolDashboard(config: config, dataDir: dataDir, workbook: workbook)
        core.writeAll()

        if let csvURL {
            let csvData = try Data(contentsOf: csvURL)
            let school = SchoolCSVDashboard(config: config, csvData: csvData, workbook: workbook)
            school?.writeAll()
        }

        try workbook.write(to: outputURL)
    }

    // MARK: - Convenience: timestamped output path

    /// Return a timestamped output URL based on config `output` settings.
    ///
    /// Mirrors the Python timestamping logic in `cmd_generate`:
    /// `<output_dir>/<stem>_<YYYY-MM-DD_HHmmss>.xlsx`.
    ///
    /// - Parameter stem: Base filename stem (without extension).
    /// - Parameter profile: Profile slug used to validate absolute config paths against
    ///   the workspace root. When an absolute `output_dir` fails validation it falls back
    ///   to `Generated Reports` inside the workspace.
    func resolveOutputURL(stem: String, profile: String? = nil) -> URL {
        let rawDir = config.output?.resolvedOutputDir ?? "Generated Reports"
        let outDir: URL
        if rawDir.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: rawDir)
            if let profile,
               let root = WorkspacePathGuard.root(for: profile),
               WorkspacePathGuard.validate(candidate, under: root) != nil {
                outDir = candidate
            } else {
                if let profile, let root = WorkspacePathGuard.root(for: profile) {
                    outDir = root.appending(component: "Generated Reports")
                } else {
                    outDir = candidate
                }
            }
        } else {
            if let profile, let root = WorkspacePathGuard.root(for: profile) {
                outDir = root.appending(component: rawDir)
            } else {
                outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(rawDir)
            }
        }

        let shouldTimestamp = config.output?.timestampOutputs ?? true
        if shouldTimestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
            let ts = formatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "-")
                .replacingOccurrences(of: "T", with: "_")
            return outDir.appendingPathComponent("\(stem)_\(ts).xlsx")
        } else {
            return outDir.appendingPathComponent("\(stem).xlsx")
        }
    }

    // MARK: - Workspace init helper

    /// Initialize a workspace directory for `profile` under `workspacesRoot`.
    ///
    /// Creates the standard subdirectory tree and a minimal `config.yaml` seeded
    /// from `seedConfigURL` if provided. Mirrors `cmd_workspace_init` behavior.
    static func initializeWorkspace(
        profile: String,
        workspacesRoot: URL,
        seedConfigURL: URL?,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) throws {
        guard ProfileService.isValid(profile) else {
            throw ReportEngineError.invalidProfile(profile)
        }
        let workspace = workspacesRoot.appendingPathComponent(profile, isDirectory: true)
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o700))]
        let paths = [
            workspace,
            workspace.appendingPathComponent("csv-inbox", isDirectory: true),
            workspace.appendingPathComponent("jamf-cli-data", isDirectory: true),
            workspace.appendingPathComponent("Generated Reports", isDirectory: true),
            workspace.appendingPathComponent("automation", isDirectory: true),
            workspace.appendingPathComponent("automation/logs", isDirectory: true),
            workspace.appendingPathComponent("snapshots", isDirectory: true),
        ]
        for url in paths {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: attrs)
            do {
                try fm.setAttributes(attrs, ofItemAtPath: url.path)
            } catch {
                AppLogger.engine.warning(
                    "initializeWorkspace: setAttributes failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
            }
        }

        let configURL = workspace.appendingPathComponent("config.yaml")
        if !fm.fileExists(atPath: configURL.path) {
            if let seed = seedConfigURL, fm.fileExists(atPath: seed.path) {
                try fm.copyItem(at: seed, to: configURL)
            } else {
                let minimal = defaultConfigYAML(profile: profile)
                try minimal.write(to: configURL, atomically: true, encoding: .utf8)
            }
        }
        onLine(.init(timestamp: Date(), level: .ok,
                     text: "[ok] workspace initialized at \(workspace.path)"))
    }

    // MARK: - Scaffold helper

    /// Generate a starter `config.yaml` by inspecting CSV column headers.
    ///
    /// Reads the header row, fuzzy-matches known logical field names to CSV columns,
    /// and writes a `config.yaml` with `columns:` pre-filled. Replaces `cmd_scaffold`.
    static func scaffoldConfig(csvURL: URL, outputURL: URL, profile: String) throws {
        let data = try Data(contentsOf: csvURL)
        let (columns, _) = try CSVParser.parse(data)

        let mappings = scaffoldMappings(from: columns)
        let yaml = buildConfigYAML(profile: profile, mappings: mappings)
        let fm = FileManager.default
        try fm.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try yaml.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private helpers

    private static func saveSnapshot(data: Data, kind: String, dataDir: URL) throws {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let ts = formatter.string(from: Date())
        let file = dir.appendingPathComponent("\(kind)_\(ts).json")
        try data.write(to: file)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: file.path
            )
        } catch {
            AppLogger.engine.warning(
                "saveSnapshot: setAttributes failed for \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private static func loadLatestSnapshotData(kind: String, dataDir: URL) throws -> Data {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), !files.isEmpty else {
            throw ReportEngineError.snapshotParseError(kind)
        }
        let newest = files
            .filter { $0.pathExtension == "json" }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return a < b
            }
        guard let url = newest else {
            throw ReportEngineError.snapshotParseError(kind)
        }
        return try Data(contentsOf: url)
    }

    /// Merge `ea-results` snapshot into computer rows.
    ///
    /// EA result rows are grouped by device identifier (computer_id → name fallback).
    /// Each unique EA name becomes a column prefixed `ea:` to avoid collision with base keys.
    /// Devices with no EA results are left unchanged.
    private static func mergeEAResults(
        into rows: [[String: Any]],
        dataDir: URL
    ) -> [[String: Any]] {
        guard let eaData = try? loadLatestSnapshotData(kind: "ea-results", dataDir: dataDir),
              let eaRaw = try? JSONSerialization.jsonObject(with: eaData),
              let eaRows = eaRaw as? [[String: Any]] else {
            return rows
        }

        // Build a lookup: device name → [ea_name: value]
        var eaByDevice: [String: [String: String]] = [:]
        for eaRow in eaRows {
            let deviceKey = (eaRow["computer_id"] as? String)
                ?? (eaRow["device"] as? String)
                ?? (eaRow["computerName"] as? String)
                ?? ""
            guard !deviceKey.isEmpty,
                  let eaName = eaRow["ea_name"] as? String else { continue }
            let value: String
            switch eaRow["value"] {
            case let s as String: value = s
            case let n as Int: value = "\(n)"
            case let b as Bool: value = b ? "true" : "false"
            default: value = ""
            }
            eaByDevice[deviceKey, default: [:]][eaName] = value
        }

        return rows.map { row -> [String: Any] in
            let deviceId = (row["id"] as? String)
                ?? (row["id"] as? Int).map { "\($0)" }
                ?? (row["name"] as? String)
                ?? ""
            guard !deviceId.isEmpty,
                  let eas = eaByDevice[deviceId] else { return row }
            var merged = row
            for (eaName, value) in eas {
                merged["ea:\(eaName)"] = value
            }
            return merged
        }
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: - Column scaffold helpers

    /// Internal entry point for scaffold hints — exposed for testing.
    static func testableScaffoldMappings(from columns: [String]) -> [String: String] {
        scaffoldMappings(from: columns)
    }

    /// Fuzzy-match CSV column names to logical config keys.
    /// Returns a dictionary of key → matched column name.
    private static func scaffoldMappings(from columns: [String]) -> [String: String] {
        // Mapping of logical key → hint substrings (case-insensitive contains)
        let hints: [String: [String]] = [
            "computer_name":       ["computer name", "device name", "name"],
            "serial_number":       ["serial"],
            "operating_system":    ["operating system", "os version", "macos version"],
            "last_checkin":        ["last inventory", "last check", "last contact", "last seen"],
            "department":          ["department"],
            "email":               ["email"],
            "filevault":           ["filevault"],
            "sip":                 ["system integrity", " sip "],
            "firewall":            ["firewall"],
            "gatekeeper":          ["gatekeeper"],
            "secure_boot":         ["secure boot"],
            "bootstrap_token":     ["bootstrap token"],
            "disk_percent_full":   ["disk", "percent full", "drive percentage"],
            "model":               ["model"],
            "architecture":        ["architecture", "arch"],
            "full_name":           ["full name", "fullname", "user full name"],
            "asset_tag":           ["asset tag", "assettag", "asset id"],
            "building":            ["building", "site building"],
            "position":            ["position", "job title"],
            "last_logged_in_user": ["last logged in", "last user", "logged in user"],
            "recovery_lock":       ["recovery lock", "recoverylock", "recovery lock enabled"],
            "battery_health":      ["battery health", "battery condition", "battery cycle"],
            "entra_sso_status":    ["entra sso", "azure ad", "entra id sso"],
        ]
        var result: [String: String] = [:]
        let lowerColumns = columns.map { $0.lowercased() }
        for (key, hintList) in hints {
            for hint in hintList {
                if let idx = lowerColumns.firstIndex(where: { $0.contains(hint) }) {
                    result[key] = columns[idx]
                    break
                }
            }
        }
        return result
    }

    private static func buildConfigYAML(profile: String, mappings: [String: String]) -> String {
        var lines = [
            "# config.yaml generated by Jamf Reports",
            "jamf_cli:",
            "  profile: \"\(profile)\"",
            "  data_dir: \"jamf-cli-data\"",
            "  use_cached_data: true",
            "",
            "columns:",
        ]
        let orderedKeys = [
            "computer_name", "serial_number", "operating_system", "last_checkin",
            "department", "email", "filevault", "sip", "firewall", "gatekeeper",
            "secure_boot", "bootstrap_token", "disk_percent_full", "model",
            "architecture", "full_name", "asset_tag", "building", "position",
            "last_logged_in_user", "recovery_lock", "battery_health", "entra_sso_status",
        ]
        for key in orderedKeys {
            let value = mappings[key] ?? ""
            lines.append("  \(key): \"\(value)\"")
        }
        lines.append("")
        lines.append("output:")
        lines.append("  output_dir: \"Generated Reports\"")
        lines.append("  timestamp_outputs: true")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func defaultConfigYAML(profile: String) -> String {
        buildConfigYAML(profile: profile, mappings: [:])
    }

    // MARK: - SHA-256 manifest helpers (Finding #8)

    /// Instance-method shim that forwards to the static implementation.
    private func writeManifest(for artifactURL: URL, profile: String, template: String = "") {
        Self.writeManifestStatic(for: artifactURL, profile: profile, template: template)
    }

    /// Compute SHA-256 of `artifactURL` and write a `.manifest.txt` sibling file.
    ///
    /// Format (one key: value per line):
    /// ```
    /// filename: jamf_report_prod_2026-05-07_103045.xlsx
    /// sha256:   8f4c2a...
    /// generated_at: 2026-05-07T10:30:45Z
    /// generator: JamfReports <version>
    /// profile: prod
    /// template: Executive
    /// ```
    ///
    /// Failures are logged to stderr and silently swallowed — a manifest write
    /// failure must never abort artifact delivery.
    static func writeManifestStatic(
        for artifactURL: URL,
        profile: String,
        template: String = ""
    ) {
        guard let data = try? Data(contentsOf: artifactURL) else {
            fputs("[warn] manifest: could not read \(artifactURL.lastPathComponent)\n", stderr)
            return
        }
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = iso.string(from: Date())

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
        let generatorLabel = "JamfReports \(appVersion)"

        let manifest = [
            "filename: \(artifactURL.lastPathComponent)",
            "sha256:   \(hex)",
            "generated_at: \(now)",
            "generator: \(generatorLabel)",
            "profile: \(profile.isEmpty ? "(none)" : profile)",
            "template: \(template.isEmpty ? "(default)" : template)",
        ].joined(separator: "\n") + "\n"

        let manifestURL = artifactURL.appendingPathExtension("manifest.txt")
        do {
            try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        } catch {
            fputs("[warn] manifest: could not write \(manifestURL.lastPathComponent): \(error)\n",
                  stderr)
        }
    }

    /// Write a single `<stem>.evidence-bundle.txt` that lists all artifact URLs with their
    /// SHA-256 hashes when multiple artifacts are produced in one call.
    ///
    /// - Parameters:
    ///   - artifacts: Ordered list of artifact file URLs.
    ///   - profile: Profile slug for the manifest header.
    ///   - template: Template identifier for the manifest header.
    static func writeEvidenceBundle(
        artifacts: [URL],
        profile: String,
        template: String = ""
    ) {
        guard !artifacts.isEmpty else { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = iso.string(from: Date())
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"

        var blocks: [String] = []
        for url in artifacts {
            guard let data = try? Data(contentsOf: url) else { continue }
            let digest = SHA256.hash(data: data)
            let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
            blocks.append([
                "filename: \(url.lastPathComponent)",
                "sha256:   \(hex)",
                "generated_at: \(now)",
                "generator: JamfReports \(appVersion)",
                "profile: \(profile.isEmpty ? "(none)" : profile)",
                "template: \(template.isEmpty ? "(default)" : template)",
            ].joined(separator: "\n"))
        }
        guard !blocks.isEmpty else { return }

        // Bundle filename: use the stem of the first artifact.
        let stem = artifacts[0].deletingPathExtension().lastPathComponent
        let bundleURL = artifacts[0]
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem).evidence-bundle.txt")

        let content = blocks.joined(separator: "\n\n") + "\n"
        do {
            try content.write(to: bundleURL, atomically: true, encoding: .utf8)
        } catch {
            fputs("[warn] evidence-bundle: could not write \(bundleURL.lastPathComponent): \(error)\n",
                  stderr)
        }
    }
}

// MARK: - Errors

enum ReportEngineError: Error, LocalizedError {
    case noCachedData(URL)
    case csvParseFailed(URL)
    case jamfCLINotFound
    case invalidProfile(String)
    case snapshotParseError(String)
    /// Raised during collect when `use_cached_data=false` and a live call fails.
    case collectFailed(kind: String, exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .noCachedData(let dir):
            return "No cached jamf-cli data found in \(dir.path). Run 'collect' first, or provide a --csv export."
        case .csvParseFailed(let url):
            return "Failed to parse CSV at \(url.path). Ensure the file is UTF-8 and has a header row."
        case .jamfCLINotFound:
            return "jamf-cli not found on PATH. Install it via Homebrew or from GitHub."
        case .invalidProfile(let p):
            return "Invalid profile name '\(p)'."
        case .snapshotParseError(let kind):
            return "No cached snapshot found for '\(kind)'. Run collect first."
        case .collectFailed(let kind, let code):
            return "Collect failed for '\(kind)' (exit \(code)). Set use_cached_data: true to allow fallback."
        }
    }
}

