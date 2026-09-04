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
    ///   - aiNarrative: Optional AI executive narrative (F3). GUI-generate flows pass
    ///                  a pre-generated paragraph; headless callers (scheduled runs,
    ///                  included CLI) leave the default nil and no AI block is written.
    ///   - onLine: Optional streaming log callback. Post-generate side-effect warnings
    ///             (archive rotation, CSV snapshot, summary JSON) are routed here when
    ///             provided, so callers with a live log view (e.g. GenerateSheet) see them.
    /// - Returns: A list of `SheetFailure` entries for sheets that encountered unexpected
    ///            errors. An empty list means all sheets that had data were written cleanly.
    ///            Sheets that threw `SheetSkippable` (absent cached data) are not included.
    @discardableResult
    func generate(
        csvURL: URL?,
        outputURL: URL,
        template: any ReportTemplate = FullInstanceTemplate(),
        aiNarrative: String? = nil,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) async throws -> [SheetFailure] {
        // PR-10 / threat-model T-11: strict-mode pre-flight. Abort before any
        // sheet writes if the workspace has tampered or corrupt-manifest
        // snapshots. Catching per-sheet inside writeSelected wouldn't abort
        // the run — SheetSkippable would just skip the offending sheet.
        try Self.preflightStrictManifestCheck(config: config, dataDir: dataDir)

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
                                 provenance: prov, aiNarrative: aiNarrative)
        let registry = SheetRegistry(plan: core.sheetPlan)
        for sheetID in template.includedSheets {
            AppLogger.report.debug("sheet \(sheetID.rawValue, privacy: .public)")
        }
        let (writtenCore, coreFailures, unimplementedSheets) = registry.writeSelected(template: template)
        for sheetID in unimplementedSheets {
            let msg = "[warn] template '\(template.identifier)': SheetID '\(sheetID.rawValue)' " +
                      "has no writer in CoreDashboard — skipped (engine follow-up required)"
            AppLogger.report.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
        }
        if writtenCore.isEmpty {
            // No cached data at all — not an error if CSV was provided.
            if csvURL == nil {
                throw ReportEngineError.noCachedData(dataDir)
            }
        }

        // CSVDashboard sheets — Swift CSV writers are non-throwing; failures are captured
        // in writeAll()'s return value (currently always empty, reserved for future writers).
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
            // CSVDashboard.writeAll returns [String] — its closures are non-throwing
            // so there is no failure list here. Named for clarity if the contract widens.
            _ = csv.writeAll()
        }

        // Chart sheet — render PNG charts from trend summaries and embed in workbook.
        // Standalone PNGs land next to the xlsx via ExportNaming conventions.
        // charts.save_png gates only the standalone files; embedding is governed
        // separately by embed_in_xlsx, so turning PNGs off still leaves charts in
        // the workbook. Defaults to true: the key was declared but unread before
        // 2.7.0, so PNGs always appeared, and absent config must keep doing that.
        if config.charts?.isEnabled == true,
           let summariesDir = resolvedSummariesDir(profile: profile, onLine: onLine) {
            let savePNGs = config.charts?.savePng ?? true
            renderChartSheet(
                workbook: workbook,
                summariesDir: summariesDir,
                pngOutputDir: savePNGs ? outputURL.deletingLastPathComponent() : nil,
                profile: profile
            )
        }

        // Write the workbook atomically.
        try workbook.write(to: outputURL)

        // Write a SHA-256 manifest alongside the artifact for federal compliance.
        writeManifest(for: outputURL, profile: profile, template: template.identifier)

        // T-13 integrity envelope: write `<basename>.xlsx.sha256` sidecar in
        // `shasum -a 256` output format. The hash is also surfaced to the UI
        // via the log stream so GenerateSheet can show it in the toast.
        if let hash = Self.writeSHA256Sidecar(for: outputURL) {
            onLine?(.init(
                timestamp: Date(),
                level: .ok,
                text: "[ok] sha256: \(hash) \(outputURL.lastPathComponent)"
            ))
        }

        // Archive CSV snapshot only after a successful write — avoids archiving when generate fails.
        if let csvURL,
           config.charts?.archiveCurrentCsv == true,
           let historicalDir = resolvedHistoricalDir(profile: profile, onLine: onLine) {
            archiveCurrentCSV(csvURL: csvURL, historicalDir: historicalDir, onLine: onLine)
        }

        // Post-write: archive old runs, emit trend summary.
        let outputDir = outputURL.deletingLastPathComponent()
        let stem = stemFromURL(outputURL)
        if config.output?.isArchiveEnabled == true {
            let archiveDir = resolvedArchiveDir(profile: profile, outputDir: outputDir, onLine: onLine)
            let keep = config.output?.resolvedKeepLatestRuns ?? 10
            archiveOldRuns(
                outputDir: outputDir,
                archiveDir: archiveDir,
                stem: stem,
                keep: keep,
                onLine: onLine
            )
        }

        if let summariesDir = resolvedSummariesDir(profile: profile, onLine: onLine) {
            emitSummaryJSON(summariesDir: summariesDir, provenance: prov, onLine: onLine)
        }

        return coreFailures
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
            AppLogger.report.warning("\(msg, privacy: .private)")
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
                AppLogger.report.warning("\(msg, privacy: .private)")
                print(msg)
                onLine?(.init(timestamp: Date(), level: .warn, text: msg))
                // Skip sidecar move when the xlsx move failed — sidecars without
                // a workbook in the archive are uninformative.
                continue
            }
            // Move sibling sidecar files (sha256 + manifest.txt) alongside the
            // xlsx so they don't accumulate as orphans in the reports root.
            // Failures are best-effort: warn and continue rather than block rotation.
            let sidecarExts = ["sha256", "manifest.txt"]
            for ext in sidecarExts {
                let sidecar = file.appendingPathExtension(ext)
                guard fm.fileExists(atPath: sidecar.path) else { continue }
                let sidecarDest = archiveDir.appendingPathComponent(sidecar.lastPathComponent)
                do {
                    if fm.fileExists(atPath: sidecarDest.path) {
                        try fm.removeItem(at: sidecarDest)
                    }
                    try fm.moveItem(at: sidecar, to: sidecarDest)
                } catch {
                    let msg = "[warn] Could not archive sidecar \(sidecar.lastPathComponent): \(error)"
                    AppLogger.report.warning("\(msg, privacy: .private)")
                    onLine?(.init(timestamp: Date(), level: .warn, text: msg))
                }
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
            AppLogger.report.warning("\(msg, privacy: .private)")
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
            AppLogger.report.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
        }
    }

    // MARK: - Summary JSON emission (mirrors Python _build_summary_from_bridge)

    /// Write `summary_YYYY-MM-DD.json` to `summariesDir` from cached jamf-cli snapshots.
    ///
    /// Skips if a valid same-day file already exists (first run of day wins, matching Python
    /// default non-force behavior). compliancePct is the control-gap proxy (flagged via
    /// complianceIsProxy) when per-device security data exists; crowdstrikePct still requires
    /// CSV/EA data and is omitted so TrendStore skips it rather than rendering a flat 0% line.
    ///
    /// - Parameters:
    ///   - summariesDir: Directory to write the summary file into.
    ///   - provenance: Run provenance captured by the caller; embedded in the JSON output.
    ///   - onLine: When provided, warnings are emitted here in addition to `print`.
    /// - Returns: What happened, so a caller can tell "today's point is on
    ///   disk" from "nothing was written, and here is why". Deliberately not a
    ///   bare Bool: the caller also has to know whether the `[partial]` marker
    ///   has already been emitted, or it double-reports the write failure.
    @discardableResult
    func emitSummaryJSON(
        summariesDir: URL,
        provenance: Provenance? = nil,
        liveKinds: Set<String>? = nil,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) -> SummaryEmitOutcome {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        } catch {
            let msg = "[warn] Could not create summaries dir: \(error)"
            AppLogger.collect.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return .directoryUnavailable
        }

        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let summaryFile = summariesDir.appendingPathComponent("summary_\(today).json")

        if fm.fileExists(atPath: summaryFile.path),
           let existingData = try? Data(contentsOf: summaryFile),
           let obj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
           obj["date"] != nil, obj["totalDevices"] != nil, obj["source"] != nil {
            // Same-day summary is valid. Check whether a fresh build would be strictly
            // better (proxy→real mSCP upgrade, or mscpBands newly populated). If not,
            // keep the existing file so its mtime reflects the first run.
            if let fresh = buildSummaryFromCLI(date: today, provenance: provenance, liveKinds: liveKinds),
               let existing = try? JSONDecoder().decode(DailySummary.self, from: existingData),
               Self.freshSummaryIsBetter(existing: existing, fresh: fresh) {
                let upgradeMsg = "[info] summary_\(today).json upgraded (proxy→real mSCP)"
                AppLogger.collect.info("\(upgradeMsg, privacy: .public)")
                onLine?(.init(timestamp: Date(), level: .info, text: upgradeMsg))
                return writeSummaryFile(fresh, to: summaryFile, onLine: onLine)
                    ? .wrote : .writeFailed
            }
            let msg = "[info] summary_\(today).json already exists — "
                + "leaving existing file in place"
            AppLogger.collect.info("\(msg, privacy: .public)")
            onLine?(.init(timestamp: Date(), level: .info, text: msg))
            return .keptExisting
        }

        guard let summary = buildSummaryFromCLI(date: today, provenance: provenance, liveKinds: liveKinds) else {
            // buildSummaryFromCLI returns nil when no cached jamf-cli snapshots
            // are available to summarize (fresh workspace, failed/skipped collect,
            // CSV-only generate run). Surface this so operators understand why
            // the trend chart and StaleDataBanner won't refresh on this run.
            let msg = "[warn] summary JSON not written: no jamf-cli snapshots available to summarize " +
                      "(run `collect` first, or this is expected for CSV-only generation)"
            AppLogger.collect.warning("\(msg, privacy: .public)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return .nothingToSummarize
        }

        return writeSummaryFile(summary, to: summaryFile, onLine: onLine)
            ? .wrote : .writeFailed
    }

    // MARK: - Summary upgrade helpers

    /// Returns true when `fresh` is strictly better than `existing` — meaning it
    /// should overwrite a same-day summary that would otherwise be kept.
    ///
    /// "Better" means at least one of:
    /// - `existing.complianceIsProxy == true` AND `fresh.complianceIsProxy == false`
    ///   (real mSCP data is now available where before only the 4-control proxy was), OR
    /// - `existing` has no `mscpBands` (or empty) AND `fresh` has non-empty `mscpBands`, OR
    /// - `existing.staleCount`/`mobileDeviceCount` is nil (unmeasured) AND `fresh` measured it,
    ///   or `existing.staleCount == 0` on a non-empty fleet AND `fresh` measures a real value.
    ///
    /// Never returns true when the fresh run would downgrade (real→proxy, bands dropped, or a
    /// measured value replaced by nil), preserving the PR-18 protection against a partial
    /// collect clobbering a good summary.
    static func freshSummaryIsBetter(existing: DailySummary, fresh: DailySummary) -> Bool {
        if existing.complianceIsProxy == true && fresh.complianceIsProxy == false { return true }
        let existingHasBands = !(existing.mscpBands?.isEmpty ?? true)
        let freshHasBands = !(fresh.mscpBands?.isEmpty ?? true)
        if !existingHasBands && freshHasBands { return true }
        // A later same-day collect that now measures staleness where the earlier
        // one couldn't (nil), or sees stale devices where the earlier one
        // recorded zero on a non-empty fleet, is strictly better — the earlier
        // run's stale source (device-compliance) was absent/degraded. Upgrade
        // only; a real count is never downgraded to 0 or to unknown.
        if existing.staleCount == nil, fresh.staleCount != nil { return true }
        if existing.staleCount == 0, existing.totalDevices > 0,
           let freshStale = fresh.staleCount, freshStale > 0 { return true }
        // Same pattern for mobileDeviceCount: a same-day summary written before
        // a mobile-devices collect landed (or by a prior build that predates
        // the field) must not freeze mobileDeviceCount at nil all day once a
        // later collect measures it. Upgrade only; a measured count is never
        // replaced by nil.
        if existing.mobileDeviceCount == nil, fresh.mobileDeviceCount != nil { return true }
        return false
    }

    /// Encode and atomically write `summary` to `url`, logging the outcome to
    /// `onLine`. Returns whether the file actually landed.
    ///
    /// The failure line carries the `[partial]` marker rather than a plain
    /// `[warn]`: a run whose summary never reached disk has not updated Trends
    /// or the freshness banner, and reporting it as an unqualified success is
    /// exactly the kind of quiet lie this release is closing. The return value
    /// is what lets the scheduled path stop claiming "Trends updated".
    @discardableResult
    private func writeSummaryFile(
        _ summary: DailySummary,
        to url: URL,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(summary)
            try data.write(to: url, options: .atomic)
            let msg = "[ok] wrote \(url.lastPathComponent) — trend chart and StaleDataBanner will reflect this run"
            AppLogger.collect.info("\(msg, privacy: .public)")
            onLine?(.init(timestamp: Date(), level: .ok, text: msg))
            return true
        } catch {
            let msg = "\(Self.summaryNotWrittenMarker) \(error.localizedDescription)"
            AppLogger.collect.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return false
        }
    }

    /// What one `emitSummaryJSON` call did.
    ///
    /// The reason lives here rather than at the emit site because `generate`
    /// calls `emitSummaryJSON` on its CSV-only path, where having no jamf-cli
    /// snapshots is normal and must not mark the run partial. Only the collect
    /// path turns these into a `[partial]` line.
    enum SummaryEmitOutcome: Equatable, Sendable {
        /// This run wrote today's summary.
        case wrote
        /// An earlier run of the day wrote it and this one deliberately left it
        /// in place — today's point is on disk either way.
        case keptExisting
        /// The write was attempted and failed. `writeSummaryFile` has already
        /// emitted the `[partial] summary not written:` line.
        case writeFailed
        /// No cached jamf-cli snapshots to summarize.
        case nothingToSummarize
        /// The summaries directory could not be created.
        case directoryUnavailable

        /// Whether today's summary is on disk when the call returns.
        var summaryIsOnDisk: Bool { self == .wrote || self == .keptExisting }

        /// The reason a caller should put behind the `[partial]` marker, or nil
        /// when there is nothing to say — either the summary is on disk, or the
        /// marker has already been emitted by the writer itself.
        var partialReason: String? {
            switch self {
            case .wrote, .keptExisting, .writeFailed: nil
            case .nothingToSummarize: "no jamf-cli snapshots available to summarize"
            case .directoryUnavailable: "the summaries directory could not be created"
            }
        }
    }

    /// Prefix of the line `writeSummaryFile` emits when the day's summary could
    /// not be written. `[partial]` is the marker `RunHistoryService.isPartialRun`
    /// scans for, and the prefix is what `CollectHonestyWatcher` matches on.
    static let summaryNotWrittenMarker = "[partial] summary not written:"

    /// Prefix of the line `collect` emits when shared-workspace coordination
    /// told this Mac to stand down. Same `[partial]` contract as above: nothing
    /// was collected, so the run is not the success a bare exit 0 implies.
    static let standDownMarker = "[partial] stood down:"

    /// The stand-down log line for a `CoordinationOutcome.standDown` reason.
    /// The reason already carries its own level tag (`[info] …` / `[warn] …`);
    /// stripping it keeps one level marker per line so `LogLevel.from(line:)`
    /// and the operator both read the line the same way.
    static func standDownLine(reason: String) -> String {
        var body = reason
        if body.hasPrefix("["), let close = body.firstIndex(of: "]") {
            body = String(body[body.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return "\(standDownMarker) \(body)"
    }

    // MARK: - Private helpers

    private func buildSummaryFromCLI(
        date: String,
        provenance: Provenance? = nil,
        liveKinds: Set<String>? = nil
    ) -> DailySummary? {
        // Load each snapshot kind once; cache by kind name to avoid repeated I/O + JSON parses.
        var snapshotCache: [String: Data] = [:]
        // R4: per-input provenance — which of the digest's source kinds came
        // from this run (live), an older snapshot (cache), or nowhere (absent).
        // Only recorded when the caller (collect) knows its live kinds.
        var sourceStatus: [String: String] = [:]
        func recordSource(kind: String, present: Bool) {
            guard let liveKinds else { return }
            sourceStatus[kind] = present
                ? (liveKinds.contains(kind) ? "live" : "cache")
                : "absent"
        }
        // max_cache_age_hours enforcement: an over-age snapshot is treated as
        // ABSENT (skipped + warned, named by kind/age/key) so the daily digest
        // and the freshness signal it feeds never silently absorb ancient cache.
        let maxCacheAgeHours = config.jamfCli?.resolvedMaxCacheAgeHours ?? 168
        func cachedData(kind: String) -> Data? {
            if let hit = snapshotCache[kind] { return hit }
            do {
                let d = try Self.loadLatestSnapshotData(
                    kind: kind, dataDir: dataDir, maxCacheAgeHours: maxCacheAgeHours
                )
                snapshotCache[kind] = d
                recordSource(kind: kind, present: true)
                return d
            } catch let expired as SnapshotCacheExpired {
                AppLogger.collect.warning(
                    "\(expired.kind, privacy: .public): cached snapshot \(expired.ageHours)h old exceeds max_cache_age_hours=\(expired.limitHours) — treating as absent"
                )
                recordSource(kind: kind, present: false)
                return nil
            } catch {
                recordSource(kind: kind, present: false)
                return nil
            }
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
        // Compliance proxy (control-gap derivation, same rules as
        // CompliancePostureService): % of devices failing zero of the four
        // baseline controls. Gives the Compliance Benchmark trend and the
        // Stability Index a real signal on jamf-cli-only tenants where no
        // compliance EA / CSV source exists. Marked complianceIsProxy so the
        // UI labels it honestly.
        var complianceProxyPct: Double? = nil

        // Security report: total_devices + per-control counts + per-device
        // sections (decoded once, used for both the summary and the proxy).
        if let secData = cachedData(kind: "security"),
           let items = try? JSONDecoder().decode([SecurityReportItem].self, from: secData) {
            var deviceGapCounts: [Int] = []
            for item in items {
                switch item {
                case .summary(let s):
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
                case .device(let device):
                    if let gaps = CompliancePostureService.deviceGapCount(device) {
                        deviceGapCounts.append(gaps)
                    }
                default:
                    break
                }
            }
            if !deviceGapCounts.isEmpty {
                let compliant = deviceGapCounts.filter { $0 == 0 }.count
                complianceProxyPct = Double(compliant) / Double(deviceGapCounts.count) * 100.0
            }
        }

        // Fallback: inventory-summary for total device count
        if totalDevices == 0,
           let invData = cachedData(kind: "inventory-summary"),
           let rows = try? JSONDecoder().decode([InventorySummaryRow].self, from: invData) {
            totalDevices = rows.reduce(0) { $0 + $1.count }
        }

        guard totalDevices > 0 else { return nil }

        // Mobile device count for the "Managed Devices" trend/tile — nil (not
        // 0) when the mobile-devices-list snapshot is absent or undecodable;
        // most tenants that only manage Macs will never populate this.
        var mobileDeviceCount: Int? = nil
        if let mobileData = cachedData(kind: "mobile-devices-list") {
            mobileDeviceCount = MobileFleetService.deviceCount(fromMobileDevicesListData: mobileData)
        }

        // Stale count from device-compliance, using the row's resolved day count
        // (`days_since_contact`, falling back to legacy `days_since_checkin`)
        // `>= resolvedStaleDays` with the config threshold (default 30 days).
        // Current jamf-cli emits `days_since_contact` (a String), not the legacy
        // `days_since_checkin`, so the old checkin-only filter always read nil and
        // reported 0 stale. When no day count is emitted at all, `isStale` falls
        // back to the server-side `stale` flag. Note: this path unified the
        // summary-writer threshold (#176); DeviceInventoryService and
        // StaleDeviceService still hardcode 30 and use `daysSinceContact` — counts
        // agree at the default config but diverge with a non-default threshold
        // (follow-up: parameterize those services).
        let staleDaysThreshold = config.thresholds?.resolvedStaleDays ?? 30
        // nil (not 0) when device-compliance was never collected — unknown is
        // not zero, and a 0 here renders as a measured "0 stale devices".
        var staleCount: Int? = nil
        if let compData = cachedData(kind: "device-compliance"),
           let rows = try? JSONDecoder().decode([DeviceComplianceRow].self, from: compData) {
            staleCount = rows.filter { $0.isStale(atDays: staleDaysThreshold) }.count
        }

        // OS current % — SOFA-driven: a device is "current" when its OS version is
        // >= the latest release for its own major version per the SOFA macOS feed.
        // Falls back to nil (not 0%) when the SOFA cache or inventory-summary is absent.
        var osCurrentPct: Double? = nil
        if let invData = cachedData(kind: "inventory-summary"),
           let rows = try? JSONDecoder().decode([InventorySummaryRow].self, from: invData),
           totalDevices > 0 {
            let osCounts = Dictionary(rows.map { ($0.osVersion, $0.count) }, uniquingKeysWith: +)
            let sofaSnapshot = SOFAFeedService.load(dataDir: dataDir)
            recordSource(kind: "sofa", present: !sofaSnapshot.rows.isEmpty)
            let macOSRows = sofaSnapshot.rows.filter { $0.platform == "macOS" }
            osCurrentPct = Self.osCurrentPercent(
                macOSRows: macOSRows, osCounts: osCounts, totalDevices: totalDevices)
        }

        // Patch % — unweighted mean of per-title compliance_pct across patch-status
        // rows; nil when patch-status data is absent (not the same as 0%).
        //
        // `compactMap` excludes titles that carry a nil or unparseable
        // compliance_pct (e.g. patch titles with no enrolled devices yet).
        // Those titles are not counted in the denominator, so `patchPct` is the
        // average title compliance for titles that *have* data. It is NOT a
        // device-weighted fleet compliance figure. The displayed label "Patch
        // Compliance" should be read as "average per-title compliance", not as
        // the fraction of devices on the latest patch version.
        var patchPct: Double? = nil
        if let patchData = cachedData(kind: "patch-status"),
           let rows = try? JSONDecoder().decode([PatchStatusRow].self, from: patchData) {
            // total > 0 guard matches PatchVelocityBuilder: a 0-device title
            // carries no compliance signal, and some jamf-cli builds emit a
            // parseable "0%" for it that would drag the unweighted mean down.
            let values = rows.filter { $0.total > 0 }
                .compactMap { parsePercentString($0.compliancePct) }
            if !values.isEmpty {
                patchPct = values.reduce(0, +) / Double(values.count)
            }
        }

        // Real mSCP compliance from ea-results — overrides the proxy when the
        // primary baseline resolves to at least one device with data.
        // `devicesWithData == 0` → primary.compliancePct is nil → proxy kept.
        var complianceFinalPct: Double? = complianceProxyPct
        var complianceIsRealData = false
        var mscpBandsSnapshot: [String: MSCPBandCounts]? = nil
        // Parallel to mscpBandsSnapshot: baseline name -> failures_count_column.
        // Stable identity that lets the trend chart bridge a later baseline rename.
        var mscpBandColumnsSnapshot: [String: String]? = nil
        // cachedData records the source automatically (live/cache/absent), so a single
        // call here covers both the recordSource and the data load. Guard on eaBaselines
        // so "absent" is not recorded for tenants that never configured an EA baseline.
        let eaBaselines = config.compliance?.resolvedBaselines ?? []
        if !eaBaselines.isEmpty, let eaData = cachedData(kind: "ea-results") {
            let decoded = EAResultRow.decodeSnapshot(eaData)
            if let eaRows = decoded.rows {
                let results = MSCPComplianceService.evaluate(rows: eaRows, baselines: eaBaselines)
                if let primary = results.first, let realPct = primary.compliancePct {
                    complianceFinalPct = realPct
                    complianceIsRealData = true
                }
                // Map all baseline results into the mscpBands summary field so the
                // trend chart has per-date band data from the first collect onward.
                let bandsMap = Self.mscpBandsMap(from: results)
                if !bandsMap.isEmpty {
                    mscpBandsSnapshot = bandsMap
                    // Only the baselines that produced bands carry a column entry.
                    mscpBandColumnsSnapshot = Self.mscpBandColumnsMap(
                        from: results, baselines: eaBaselines)
                }
            } else {
                // `.notice` (not `.debug`) so the shape surfaces without verbose logging;
                // `reason` is keys-only (PII-safe).
                AppLogger.platform.notice(
                    "ReportEngine: ea-results undecodable — \(decoded.reason, privacy: .public)"
                )
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

        // complianceIsProxy:
        //   nil   — no compliance data at all (neither proxy nor real)
        //   true  — 4-control proxy from security report
        //   false — real mSCP failure-count data from ea-results
        let complianceIsProxy: Bool?
        if complianceIsRealData {
            complianceIsProxy = false
        } else if complianceProxyPct != nil {
            complianceIsProxy = true
        } else {
            complianceIsProxy = nil
        }

        return DailySummary(
            date: date,
            totalDevices: totalDevices,
            fileVaultPct: fileVaultPct.map(round1),
            compliancePct: complianceFinalPct.map(round1),
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
            actionItemsP1: gatekeeperCount.map { _ in p1 },
            complianceIsProxy: complianceIsProxy,
            mscpBands: mscpBandsSnapshot,
            mscpBandColumns: mscpBandColumnsSnapshot,
            collectionSources: liveKinds != nil && !sourceStatus.isEmpty ? sourceStatus : nil,
            mobileDeviceCount: mobileDeviceCount,
            // Only on a shared workspace. On a single-Mac install the answer is
            // trivially "this Mac", and writing it into every summary would add
            // a hostname to a file that never needed one.
            collectedByHost: Self.collectingHostLabel(dataDir: dataDir)
        )
    }

    /// This machine's display name when the workspace is shared, else nil.
    ///
    /// Derived from the data directory rather than a passed-in flag so the
    /// summary writer needs no new parameter threading through its callers.
    static func collectingHostLabel(dataDir: URL) -> String? {
        guard CloudStorage.provider(for: dataDir) != nil else { return nil }
        return SharedWorkspace.currentHost.display
    }

    /// Map `MSCPComplianceService.BaselineResult` array → `[baselineName: MSCPBandCounts]`
    /// for persistence in `summary.json`.
    ///
    /// Skips baselines with zero total devices (no data seen for that baseline's EA).
    static func mscpBandsMap(from results: [MSCPComplianceService.BaselineResult]) -> [String: MSCPBandCounts] {
        var out: [String: MSCPBandCounts] = [:]
        for result in results {
            guard result.totalDevices > 0 else { continue }
            out[result.name] = bandCountsFromBands(result.bands, noData: result.noDataCount)
        }
        return out
    }

    /// Map `MSCPComplianceService.BaselineResult` array → `[baselineName: failuresCountColumn]`,
    /// parallel to `mscpBandsMap`. The column is the stable identity that lets
    /// `MSCPChartDataBuilder` bridge a later baseline rename in multi-baseline orgs.
    ///
    /// Only baselines with at least one device (present in `mscpBandsMap`) get an
    /// entry; the column is looked up from config (`baselines`) by name, falling
    /// back to the result's own `failuresCountColumn`.
    static func mscpBandColumnsMap(
        from results: [MSCPComplianceService.BaselineResult],
        baselines: [ComplianceBaselineConfig]
    ) -> [String: String] {
        let colByName = Dictionary(
            baselines.map { ($0.name, $0.failuresCountColumn) },
            uniquingKeysWith: { first, _ in first })
        var out: [String: String] = [:]
        for result in results where result.totalDevices > 0 {
            out[result.name] = colByName[result.name] ?? result.failuresCountColumn
        }
        return out
    }

    /// Extract raw integer counts from `[ComplianceBand]` (which carries computed pct
    /// alongside count). Band order matches `ComplianceBandingService.Band.allCases`:
    /// pass, low, medLow, medium, high, noData.
    private static func bandCountsFromBands(
        _ bands: [ComplianceBand],
        noData: Int
    ) -> MSCPBandCounts {
        // bands is always 6 elements in Band.allCases order: pass, low, medLow, medium, high, noData.
        // Index them defensively.
        func count(at index: Int) -> Int { index < bands.count ? bands[index].count : 0 }
        return MSCPBandCounts(
            pass: count(at: 0),
            low: count(at: 1),
            medLow: count(at: 2),
            medium: count(at: 3),
            high: count(at: 4),
            noData: noData
        )
    }

    /// Compute OS-currency percentage from SOFA macOS rows and the fleet OS histogram.
    ///
    /// A device is "current" when its full OS version tuple is >= the latest release for
    /// its own major version in the SOFA feed (e.g., a Sequoia device is current iff on
    /// 15.7.7; a Tahoe device iff on 26.5.1). Devices on a major that SOFA does not
    /// track are excluded from both the numerator and denominator, so a transition fleet
    /// with devices on two majors still returns a meaningful percentage.
    ///
    /// Returns nil when `macOSRows` is empty (SOFA cache absent) or `totalDevices` is 0.
    ///
    /// Exposed as `static` for unit testability — callers pass in the data rather than
    /// relying on `self.dataDir`, so tests need no temp dir.
    static func osCurrentPercent(
        macOSRows: [SOFAFeedService.OSFamilyRow],
        osCounts: [String: Int],
        totalDevices: Int
    ) -> Double? {
        guard !macOSRows.isEmpty, totalDevices > 0 else { return nil }
        // Build latest-version-per-major from SOFA macOS rows.
        // When two rows share a major (e.g., two macOS 15 entries), keep the
        // numerically greatest product version — that is the true latest.
        var latestByMajor: [Int: String] = [:]
        for row in macOSRows {
            let tuple = SOFAFeedService.versionTuple(row.productVersion)
            guard let major = tuple.first else { continue }
            if let existing = latestByMajor[major] {
                let existingTuple = SOFAFeedService.versionTuple(existing)
                // Compare component-by-component; keep the greater version.
                let len = max(tuple.count, existingTuple.count)
                var newer = false
                for i in 0..<len {
                    let a = i < tuple.count ? tuple[i] : 0
                    let b = i < existingTuple.count ? existingTuple[i] : 0
                    if a != b { newer = a > b; break }
                }
                if newer { latestByMajor[major] = row.productVersion }
            } else {
                latestByMajor[major] = row.productVersion
            }
        }
        guard !latestByMajor.isEmpty else { return nil }
        // Count devices whose version >= their major's SOFA latest.
        // fleetCurrency internally filters osCounts to the given major, so
        // iterating all entries and summing onLatest cannot double-count a device
        // (each device OS version maps to exactly one major).
        var currentCount = 0
        for (_, familyLatest) in latestByMajor {
            let (onLatest, _) = SOFAFeedService.fleetCurrency(
                latestVersion: familyLatest, osCounts: osCounts)
            currentCount += onLatest
        }
        return Double(currentCount) / Double(totalDevices) * 100.0
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
    /// - `compliance.baselines` — when configured, appends mSCP/STIG compliance donut(s) and
    ///   a band trend stackplot even when the summaries dir is empty (first-run case).
    ///
    /// - Parameters:
    ///   - workbook: Workbook to append the "Charts" sheet to.
    ///   - summariesDir: Directory containing `summary_*.json` files.
    ///   - pngOutputDir: When non-nil, standalone PNG files are written here alongside
    ///     the xlsx using `ExportNaming` conventions.
    ///   - profile: Profile slug used in `ExportNaming` filenames. Defaults to "".
    func renderChartSheet(
        workbook: Workbook,
        summariesDir: URL,
        pngOutputDir: URL? = nil,
        profile: String = ""
    ) {
        let summaries = SummaryJSONParser.parseDirectory(summariesDir)
            .sorted { $0.parsedDate < $1.parsedDate }
        let baselines = config.compliance?.resolvedBaselines ?? []

        // Load the mSCP baseline data for the current snapshot — needed even when
        // summaries is empty (first-run case: ea-results exists, summary not yet written).
        let eaData = try? Self.loadLatestSnapshotData(kind: "ea-results", dataDir: dataDir)
        let eaDecoded = eaData.map { EAResultRow.decodeSnapshot($0) }
        if let eaDecoded, eaDecoded.rows == nil {
            // `.notice` (not `.debug`) so the shape surfaces without verbose logging;
            // `reason` is keys-only (PII-safe).
            AppLogger.platform.notice(
                "ReportEngine.renderChartSheet: ea-results undecodable — \(eaDecoded.reason, privacy: .public)"
            )
        }
        let eaRows = eaDecoded?.rows
        let mscpResults: [MSCPComplianceService.BaselineResult] = {
            guard !baselines.isEmpty, let rows = eaRows else { return [] }
            return MSCPComplianceService.evaluate(rows: rows, baselines: baselines)
        }()
        let hasMSCPData = mscpResults.contains { $0.devicesWithData > 0 }

        // Only open the sheet when there's something to render.
        guard !summaries.isEmpty || hasMSCPData else { return }

        let ws = workbook.addSheet("Charts")
        ws.setColumnWidth(0, 0, 30)
        var embedRow = 0

        // --- Fleet size trend ---
        if !summaries.isEmpty {
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
                    writePNG(png, kind: "fleet-trend", profile: profile, to: pngOutputDir)
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
                    writePNG(png, kind: "security-trend", profile: profile, to: pngOutputDir)
                }
            }

            // --- Device state trend (managed / stale) ---
            if config.charts?.deviceStateTrend?.enabled == true {
                let stalePoints = summaries.compactMap { s -> (date: Date, value: Double)? in
                    s.staleCount.map { (s.parsedDate, Double($0)) }
                }
                if !stalePoints.isEmpty {
                    let series = ChartSeries(label: "Stale Devices",
                                             color: ChartPalette.color(for: 3), points: stalePoints)
                    if let png = ChartRenderer.lineChart(series: [series],
                                                          title: "Stale Device Count Trend") {
                        ws.insertImage(row: embedRow, col: 0, data: png, filename: "stale_trend.png")
                        embedRow += 20
                        writePNG(png, kind: "stale-trend", profile: profile, to: pngOutputDir)
                    }
                }
            }

            // --- Compliance trend (stacked area with configurable bands) ---
            if let bands = config.charts?.complianceTrend?.bands, !bands.isEmpty {
                let bandSeries: [ChartSeries] = bands.enumerated().compactMap { (idx, band) in
                    let color = cgColorFromHex(band.color) ?? ChartPalette.color(for: idx)
                    let pts = summaries.compactMap { s -> (date: Date, value: Double)? in
                        guard let pct = s.compliancePct else { return nil }
                        let within = pct >= Double(band.minFailures) && pct <= Double(band.maxFailures)
                        return within ? (s.parsedDate, 1.0) : nil
                    }
                    return pts.isEmpty ? nil : ChartSeries(label: band.label, color: color, points: pts)
                }
                if !bandSeries.isEmpty {
                    if let png = ChartRenderer.stackedAreaChart(
                        series: bandSeries, title: "Compliance Band Distribution"
                    ) {
                        ws.insertImage(row: embedRow, col: 0, data: png,
                                       filename: "compliance_bands.png")
                        embedRow += 20
                        writePNG(png, kind: "compliance-bands", profile: profile, to: pngOutputDir)
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
                        embedRow += 20
                        writePNG(png, kind: "os-adoption", profile: profile, to: pngOutputDir)
                    }
                }
            }
        }

        // --- mSCP/STIG compliance charts (appended after existing 5) ---
        embedRow = renderMSCPCharts(
            workbook: workbook, ws: ws, embedRow: embedRow,
            mscpResults: mscpResults, baselines: baselines, summaries: summaries,
            profile: profile, pngOutputDir: pngOutputDir
        )
        _ = embedRow  // final row count not needed outside this scope
    }

    /// Renders mSCP/STIG compliance charts and embeds them in `ws`.
    ///
    /// Separated from `renderChartSheet` to keep line count per function ≤100.
    /// Returns the updated `embedRow` value so the caller can continue appending.
    private func renderMSCPCharts(
        workbook: Workbook,
        ws: Worksheet,
        embedRow startRow: Int,
        mscpResults: [MSCPComplianceService.BaselineResult],
        baselines: [ComplianceBaselineConfig],
        summaries: [DailySummary],
        profile: String,
        pngOutputDir: URL?
    ) -> Int {
        var embedRow = startRow
        guard !mscpResults.isEmpty else { return embedRow }

        for (idx, result) in mscpResults.enumerated() {
            guard result.devicesWithData > 0 else { continue }

            // Build donut slices (No Data → Pass → Low → Med-Low → Medium → High).
            let slices = MSCPChartDataBuilder.toDonutSlices(result: result)
            // Skip when no slice has any count (baseline produced purely empty data).
            guard slices.contains(where: { $0.count > 0 }) else { continue }

            let baseline = idx < baselines.count ? baselines[idx] : nil
            var footer = "Total systems: \(result.totalDevices)"
            if let rc = baseline?.ruleCount { footer += " · Baseline: \(rc) auditable rules" }

            // Per spec: all six legend rows rendered ("No Data: N (P%)", "Pass (0): N (P%)", …).
            let donutTitle = "Compliance Donut — \(result.name) All Devices"
            if let png = ChartRenderer.donutChart(slices: slices,
                                                   title: donutTitle, footer: footer) {
                let fname = "mscp-donut-\(idx).png"
                ws.insertImage(row: embedRow, col: 0, data: png, filename: fname)
                embedRow += 20
                writePNG(png, kind: "mscp-donut-\(sanitizeForFilename(result.name))",
                         profile: profile, to: pngOutputDir)
            }
        }

        // Band trend stackplot — uses primary baseline (first with data).
        guard let primaryBaseline = baselines.first,
              let primaryResult = mscpResults.first, primaryResult.devicesWithData > 0
        else { return embedRow }

        let points = MSCPChartDataBuilder.buildSeries(
            baseline: primaryBaseline, dataDir: dataDir, summaries: summaries)
        guard !points.isEmpty else { return embedRow }

        let stackSeries = MSCPChartDataBuilder.toStackedSeries(points: points)
        let trendTitle = "mSCP/STIG Compliance Trend — \(primaryBaseline.name)"
        if let png = ChartRenderer.stackedAreaChart(series: stackSeries, title: trendTitle) {
            ws.insertImage(row: embedRow, col: 0, data: png, filename: "mscp-band-trend.png")
            embedRow += 20
            writePNG(png, kind: "mscp-band-trend", profile: profile, to: pngOutputDir)
        }

        return embedRow
    }

    /// Write a PNG to `dir` using `ExportNaming` conventions.
    /// No-ops when `dir` is nil. Logs a warning on write failure; xlsx embed is unaffected.
    private func writePNG(_ png: Data, kind: String, profile: String, to dir: URL?) {
        guard let dir else { return }
        let name = ExportNaming.filename(kind: kind, profile: profile, ext: "png")
        let url = dir.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            AppLogger.report.warning(
                "[warn] PNG export failed for \(kind, privacy: .public): \(error)"
            )
        }
    }

    private func sanitizeForFilename(_ s: String) -> String {
        ExportNaming.sanitize(s).prefix(32).description
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

    /// Routes through `WorkspacePaths.historicalDir(for:)` so that
    /// config-supplied absolute paths are subject to the same containment check
    /// as all other workspace-relative paths. Returns nil and logs when the
    /// profile is invalid or the path escapes the workspace — both are non-fatal
    /// because CSV archival is a best-effort post-write side effect.
    private func resolvedHistoricalDir(
        profile: String,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) -> URL? {
        do {
            return try WorkspacePaths.historicalDir(for: profile)
        } catch {
            let msg = "[warn] could not resolve historical_csv_dir for '\(profile)': " +
                      "\(error.localizedDescription) — CSV archival skipped"
            AppLogger.report.warning("\(msg, privacy: .public)")
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return nil
        }
    }

    private func resolvedSummariesDir(
        profile: String,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) -> URL? {
        resolvedHistoricalDir(profile: profile, onLine: onLine)?
            .appendingPathComponent("summaries", isDirectory: true)
    }

    /// Routes through `WorkspacePaths.archiveDir(for:)` so that config-supplied
    /// absolute archive paths are subject to the workspace containment check.
    /// Falls back to `<outputDir>/archive` on failure and logs a warning — archive
    /// rotation is a non-fatal post-write side effect.
    private func resolvedArchiveDir(
        profile: String,
        outputDir: URL,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) -> URL {
        do {
            return try WorkspacePaths.archiveDir(for: profile)
        } catch {
            let fallback = outputDir.appendingPathComponent("archive", isDirectory: true)
            let msg = "[warn] could not resolve archive_dir for '\(profile)': " +
                      "\(error.localizedDescription) — using \(fallback.lastPathComponent)"
            AppLogger.report.warning("\(msg, privacy: .public)")
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return fallback
        }
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
    /// Kinds that ran this cycle and served stale cache: present in `outcomes`
    /// (so they were actually attempted, not filtered out by tier or cadence)
    /// but absent from `savedKinds` (so nothing was written). Sorted for a
    /// stable log line.
    ///
    /// The rule is deliberately about the snapshot, not the exit code. An
    /// earlier version also filtered on `exitCode != 0 && != 7`, which mutation
    /// testing showed to be both redundant and wrong: redundant because exit 7
    /// normally *does* save (so `savedKinds` already excludes it), and wrong
    /// because when exit 7 returns empty or non-JSON output nothing is saved and
    /// the operator is genuinely being served stale cache. Exit 0 with unusable
    /// output has the same shape. "Did data land?" is the only question the
    /// `[partial]` marker is answering, so it is the only one asked here.
    static func degradedKinds(
        outcomes: [CollectOutcome], savedKinds: Set<String>
    ) -> [String] {
        outcomes
            .map(\.kind)
            .filter { !savedKinds.contains($0) }
            .sorted()
    }

    /// Exit codes worth one immediate in-run retry.
    ///
    /// 1 is jamf-cli's generic failure — on on-prem Jamf Pro that is
    /// overwhelmingly a request timeout on a heavy per-device query, and it
    /// clears on a second attempt often enough to be worth 3 seconds. 6 is
    /// HTTP 429, which is a retry instruction by definition.
    ///
    /// Deliberately excluded: 2 (usage — deterministic, a caller bug), 3 (401)
    /// and 5 (403) (credential/privilege state won't change in 3 seconds, and
    /// hammering an auth endpoint risks lockout), 4 (404 — the resource does
    /// not exist), 7 (partial success, already saved).
    static let retryableExitCodes: Set<Int32> = [1, CLIBridge.exitCodeRateLimited]

    /// Delay before the single in-run retry. Long enough for a transient
    /// server-side blip to clear, short enough not to stretch a 30-kind
    /// collect meaningfully when several kinds fail.
    static let retryDelayNanoseconds: UInt64 = 3_000_000_000

    static let expensivePerDeviceKinds: Set<String> = [
        "ea-results",
        "patch-device-failures",
        "update-device-failures",
        "device-compliance",
        // 2.8.0 per-device scan phase (ReportEngine+DeviceScan).
        "ddm-device-status",
        "mdm-command-health",
    ]

    /// Kinds served only by the Jamf Platform API. On a Jamf Pro instance
    /// profile (`auth-method: oauth2`) these four fail on every run forever —
    /// silently before 2.7.0, and as a permanently red health strip plus an
    /// hourly retry loop after it. The views that render them are already
    /// gated on `PlatformCapabilityService`; collect now agrees.
    static let platformOnlyKinds: Set<String> = [
        "compliance-devices",
        "compliance-rules",
        "ddm-status",
        "blueprint-status",
    ]

    /// The profile's auth method when it positively rules out
    /// `platformOnlyKinds`; nil for a platform profile and — deliberately —
    /// for an unknown method. Unknown fails toward collecting: never skip a
    /// kind because we could not ask.
    static func nonPlatformAuthMethod(_ authMethod: String?) -> String? {
        guard let method = authMethod?.trimmingCharacters(in: .whitespaces).lowercased(),
              !method.isEmpty, method != "platform" else { return nil }
        return method
    }

    /// Every snapshot kind `collect` produces, in the order the engine
    /// fetches them. PR-22 T-1: used by `CollectionTier` tests to verify
    /// every kind has a tier assignment, and (T-8) as the iteration
    /// surface when filtering by tier + cadence. Must stay in sync with
    /// the `commands` array inside `collect(profile:...)` —
    /// `CollectionTierLookupTests.testEveryTieredKindIsKnownToReportEngine`
    /// enforces this in CI.
    static let knownCollectKinds: [String] = [
        "overview",
        "security",
        "patch-status",
        "patch-device-failures",
        "update-status",
        "update-device-failures",
        "inventory-summary",
        "device-compliance",
        "policy-status",
        "classic-macos-profiles",
        "app-status",
        "software-installs",
        "computer-extension-attributes",
        "ea-results",
        "profile-status",
        "mobile-devices-list",
        "compliance-devices",
        "compliance-rules",
        "ddm-status",
        "blueprint-status",
        "computers",
        "policies",
        "scripts",
        "packages",
        "smart-computer-groups",
        "groups",
        "sites",
        "buildings",
        "departments",
        "advanced-mobile-device-searches",
        "classic-computer-groups",
        "classic-mobile-device-groups",
        "categories",
        "classic-ios-profiles",
        "device-enrollment-instances",
        "mobile-device-inventory-details",
        // Health audit — cheap single call; see collect command matrix entry above.
        "audit",
        // Duplicate-serial records (v1.23.0+) — data-integrity aggregate query.
        "duplicate-serials",
        // SOFA OS currency and patch release dates — post-loop steps, not argv-matrix.
        "sofa",
        "patch-release-dates",
        // 2.8.0 per-device scan phase — written by ReportEngine+DeviceScan, not the argv matrix.
        "ddm-device-status",
        "mdm-command-health",
    ]

    /// Fetch jamf-cli snapshots for `profile`, filtered by:
    ///
    /// - `tiers` (PR-22 T-9): which tier(s) to fetch. Default is all three
    ///   (Refresh + Inventory + Scan). Snapshot-only schedule mode (T-10)
    ///   narrows to `[.refresh]` so only cheap KPI commands run.
    /// - `skipExpensive` (PR-16): when true, removes the four cold-tier
    ///   per-device commands regardless of cadence. Settings toggle.
    /// - `force`: when `false` (the default), skips the entire collection loop
    ///   if a valid `summary_<today>.json` already exists for the profile —
    ///   i.e., a full collect already completed today. Passes `force: true` for
    ///   ad-hoc Refresh so manual refreshes are never skipped.
    /// - Cadence: per-report time-since-last-run check; uses
    ///   `CadenceResolver.cadence(forReport:)` for the fixed cloud cadence and
    ///   `StateFileStore` for the last-success timestamp. State is written on
    ///   successful save so a crashed/skipped run does not advance the boundary.
    ///   A `force: true` call bypasses the cadence check entirely.
    ///
    /// Log-prefix conventions for skip lines (operators read these in the
    /// Runs view to understand why a report didn't update):
    ///
    /// - `[skip] <kind>: tier <t> not selected` — tier filter
    /// - `[skip] <kind>: not due (last: ..., cadence: ...)` — cadence check
    /// - `[info] skipping per-device commands (...)` — PR-16 skipExpensive
    /// - `[info] already collected today — skipping (use Refresh to force)` — once-per-day guard
    /// One jamf-cli command's outcome in the collect loop, for the auth-dead verdict.
    struct CollectOutcome: Equatable, Sendable {
        let kind: String
        let exitCode: Int32
    }

    /// Whether a collect's per-command outcomes mean the profile's credentials are
    /// dead (vs a partial failure that should fall back to cache).
    ///
    /// Auth-dead requires BOTH: zero successful live calls (no `exit 0` with a
    /// non-empty body) AND at least one `exit 3` (HTTP 401 — expired/revoked).
    /// A single 401 among successes is NOT auth-dead: a working call proves auth is
    /// alive, so the 401 is transient/per-endpoint and falls back to cache. Chronic
    /// non-auth failures (Platform-API 404 → exit 1 on on-prem) carry no 401 and
    /// cannot trip this on their own. An empty outcome set (no auth-bearing command
    /// ran) is never auth-dead.
    static func isCollectAuthDead(_ outcomes: [CollectOutcome]) -> Bool {
        guard !outcomes.isEmpty else { return false }
        // exit 0 and exit 7 (partial failure, v1.19.0+) both prove auth was accepted
        // (auth precedes the response body), so both count as success here. A single
        // such success means auth is alive, so a co-occurring 401 is transient.
        let anySuccess = outcomes.contains {
            $0.exitCode == 0 || $0.exitCode == CLIBridge.exitCodePartialFailure
        }
        let anyAuthFailure = outcomes.contains { $0.exitCode == CLIBridge.exitCodeUnauthorized }
        return !anySuccess && anyAuthFailure
    }

    /// Whether a collect's per-command outcomes represent a total outage where live
    /// calls were attempted but ALL failed with zero successes and no HTTP 401 signals.
    ///
    /// This catches the case where the server is unreachable, jamf-cli is broken, or
    /// every call exits non-zero for reasons unrelated to auth (exit 1 network error,
    /// exit 4 not-found, exit 5 permission denied, exit 6 rate-limited). Without this
    /// guard such a run would fall through to SOFA + `emitSummaryJSON`, writing a
    /// today-stamped summary built entirely from stale cache and marking the run as
    /// success. Auth-dead (`isCollectAuthDead`) is checked first at the call site, so
    /// this function is only reached when no 401 was present.
    ///
    /// Field defect (production, jamf-cli 1.21.1, 2026-07): a freshness collect that
    /// skipped every healthy kind as "not due" (fresh cache from a prior run) and then
    /// only attempted the chronically-failing residue — Platform-API 404s (exit 1) plus
    /// `duplicate-serials` on a pre-1.23 binary (exit 2, unrecognized subcommand) — was
    /// misdiagnosed as a total outage even though the server was demonstrably reachable
    /// a minute earlier. Two refinements fix that without weakening the real-outage case:
    ///
    /// - `skippedNotDueCount`: a cadence "not due" skip is recent proof the server and
    ///   jamf-cli both work, so any skip at all vetoes the dead verdict for this run.
    /// - exit 2 (`CLIBridge.exitCodeUsage` — bad flags / unrecognized subcommand, e.g. a
    ///   too-new command on an old binary) says nothing about server reachability and is
    ///   excluded from the "failure" evidence; an all-exit-2 run is a broken invocation,
    ///   not an outage, and only warns per-kind.
    ///
    /// Returns false for an empty outcome set, for any outcome set that includes at least
    /// one `exit 0` or `exit 7` (partial failure) success, for any run where at least one
    /// kind was skipped as not-due, and for a failure set that is exit-2-only.
    static func isCollectDead(_ outcomes: [CollectOutcome], skippedNotDueCount: Int = 0) -> Bool {
        guard !outcomes.isEmpty else { return false }
        let anySuccess = outcomes.contains {
            $0.exitCode == 0 || $0.exitCode == CLIBridge.exitCodePartialFailure
        }
        guard !anySuccess else { return false }
        guard skippedNotDueCount == 0 else { return false }
        return outcomes.contains { $0.exitCode != CLIBridge.exitCodeUsage }
    }

    /// Confirmation probe run before honoring an `isCollectAuthDead` verdict — one
    /// cheap `pro auth token` call, checked for exit 0. Injectable for tests; defaults
    /// to `defaultAuthConfirmationProbe`, which spawns the real jamf-cli.
    ///
    /// Field defect (production, jamf-cli 1.21.1, 2026-07): a scan-tier run made
    /// exactly ONE live call — `patch-device-failures`, the most API-expensive
    /// command — which 401'd, while the same morning's freshness run had already
    /// collected six other kinds successfully on the same profile and a direct
    /// `jamf-cli doctor` HEAD probe passed. `isCollectAuthDead` correctly reads
    /// "zero successes + a 401 in this run's outcomes" — but that single endpoint's
    /// 401 is not proof the credentials themselves are dead; a long-running
    /// per-device command can 401 mid-flight (token expiry inside the call, or a
    /// server-side token quirk on that endpoint) while the stored credentials
    /// remain valid. This probe disproves the "dead" hypothesis before the app
    /// aborts a run — and, on a weekly schedule, sticks a Failing banner for a week.
    ///
    /// Invariant this probe depends on: `collect` (and therefore this probe)
    /// must never run for a Jamf School profile — School authenticates with
    /// an API key, not OAuth2, so `pro auth token` has no School equivalent
    /// and a probe against one would be meaningless. Callers are responsible
    /// for keeping that true (e.g. `CollectRouter` dispatches School profiles
    /// to `schoolCollect` instead). It runs unconditionally here rather than
    /// gating a second time on product type — there is no School-side
    /// auth-confirmation call to substitute.
    typealias AuthConfirmationProbe = @Sendable (
        _ profile: String,
        _ bin: URL
    ) async -> Bool

    /// Production `AuthConfirmationProbe`: runs `pro auth token` and treats exit 0
    /// as confirmed-alive. A launch failure or non-zero exit is treated as
    /// "could not confirm" (false), which preserves today's throw behavior.
    static let defaultAuthConfirmationProbe: AuthConfirmationProbe = { profile, bin in
        let probeBridge = CLIBridge()
        guard let (exitCode, _) = try? await probeBridge.runAndCapture(
            executable: bin,
            arguments: ["-p", profile, "pro", "auth", "token", "--output", "json", "--no-input"],
            environment: CLIBridge.environmentForJamfCLI(),
            onLine: { _ in }
        ) else {
            return false
        }
        return exitCode == 0
    }

    /// What `collect` must do once an `isCollectAuthDead(outcomes)` verdict has
    /// been resolved with the confirmation probe.
    enum AuthDeadDecision: Equatable {
        /// The probe confirmed credentials are alive — warn (naming the 401'd
        /// kinds) and let the run continue as an ordinary partial failure.
        case confirmedAlive(warnedKinds: [String])
        /// The probe could not confirm auth is alive — abort as before.
        case confirmedDead(failedCount: Int)
    }

    /// Resolves the auth-dead branch: runs the confirmation `probe` ONLY when
    /// `isCollectAuthDead(outcomes)` is true (never for a healthy run or one with
    /// no 401 evidence), and returns `nil` when there is nothing to resolve.
    /// Isolated from the process-spawning `collect` loop so it is directly
    /// testable with a spy probe — no jamf-cli binary required.
    static func evaluateAuthDead(
        outcomes: [CollectOutcome],
        profile: String,
        bin: URL,
        probe: AuthConfirmationProbe
    ) async -> AuthDeadDecision? {
        guard Self.isCollectAuthDead(outcomes) else { return nil }
        let authFailedKinds = outcomes
            .filter { $0.exitCode == CLIBridge.exitCodeUnauthorized }
            .map(\.kind)
        if await probe(profile, bin) {
            return .confirmedAlive(warnedKinds: authFailedKinds)
        }
        return .confirmedDead(failedCount: authFailedKinds.count)
    }

    static func collect(
        profile: String,
        workspacePaths: WorkspacePaths.Type,
        tiers: Set<CollectionTier> = Set(CollectionTier.allCases),
        skipExpensive: Bool = false,
        force: Bool = false,
        authConfirmationProbe: AuthConfirmationProbe = defaultAuthConfirmationProbe,
        locateJamfCLI: @Sendable () -> URL? = { ExecutableLocator.locate("jamf-cli") },
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws {
        guard ProfileService.isValid(profile) else {
            throw ReportEngineError.invalidProfile(profile)
        }

        // Snapshot retention (v2.2.0): config-driven, OFF by default, once per
        // calendar day. Placed before the early-return guard so it runs on any
        // collect path (headless scheduled, app refresh, ad-hoc, catch-up); its
        // own marker keeps it idempotent. Best-effort — never fails the collect.
        SnapshotRetentionService.sweepIfDue(profile: profile, onLine: onLine)

        // Once-per-day collect guard: skip the expensive jamf-cli loop when a valid
        // summary for today already exists, unless the caller passes force: true.
        // Placed before the jamf-cli binary check so it short-circuits without
        // requiring jamf-cli to be installed (testable without the binary).
        // Mirrors the emitSummaryJSON first-run-of-day check (required keys: date,
        // totalDevices, source). Ad-hoc Refresh paths pass force: true so they are
        // never gated by a prior scheduled collect.
        //
        // Only a FULL collect (all tiers) is gated here. A tier-scoped collect (e.g.
        // the weekly managed-scan run, tiers [.scan]) must fall through to the
        // per-kind cadence check below, or its tier — skipped by the daily freshness
        // run that already wrote today's summary — would never be collected. The
        // per-kind cadence check already prevents redundant work, so dropping the
        // coarse day-guard for tier subsets is safe.
        let isFullCollect = tiers == Set(CollectionTier.allCases)
        if !force, isFullCollect, let summariesDir = try? workspacePaths.summariesDir(for: profile) {
            let today = SummaryJSONParser.dateFormatter.string(from: Date())
            let summaryFile = summariesDir.appendingPathComponent("summary_\(today).json")
            if FileManager.default.fileExists(atPath: summaryFile.path),
               let data = try? Data(contentsOf: summaryFile),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["date"] != nil, obj["totalDevices"] != nil, obj["source"] != nil {
                let msg = "[info] already collected today — skipping (use Refresh to force)"
                AppLogger.collect.info("\(msg, privacy: .public)")
                onLine(.init(timestamp: Date(), level: .info, text: msg))
                return
            }
        }

        // Shared-workspace coordination, placed beside the once-per-day guard
        // and BEFORE the jamf-cli check. "Should I collect" belongs ahead of
        // "can I collect": a teammate's Mac already collecting is a reason to
        // stand down that has nothing to do with whether this Mac has jamf-cli
        // installed. Keeping the whole decision here also makes it reachable
        // without the binary, which is the only way it can be tested.
        let coordination = Self.coordinationGate(profile: profile, force: force)
        var holdsClaim = false
        switch coordination {
        case .standDown(let reason):
            // Marked `[partial]`, not `[info]`: this run collected nothing, so
            // Run History must not show it as a clean success next to a run
            // that actually fetched the fleet.
            let line = Self.standDownLine(reason: reason)
            AppLogger.collect.info("\(line, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .warn, text: line))
            return
        case .proceed(let state, let notes):
            holdsClaim = state.holdsClaim
            for note in notes {
                AppLogger.collect.warning("\(note, privacy: .public)")
                onLine(.init(timestamp: Date(), level: .warn, text: note))
            }
        }
        defer { if holdsClaim { SharedWorkspace.release(profile: profile) } }

        // Test seam. Production callers omit it and get the real locator; a test
        // passes a stub so the whole collect body below is reachable without a
        // real jamf-cli. The stub must NOT be named `jamf-cli` — CLIBridge's
        // codesign gate keys on exactly that filename and would refuse to launch
        // an unsigned one, which is what made this path untestable before.
        guard let bin = locateJamfCLI() else {
            throw ReportEngineError.jamfCLINotFound
        }

        let dataDir = try workspacePaths.dataDir(for: profile)
        // Respect use_cached_data: when false, a failed collect is fatal for that kind.
        // File-missing is a legitimate first-run state and defaults to true.
        // File-exists-but-unparseable is fatal — throw so the caller surfaces the error
        // rather than silently proceeding with stale cache.
        let useCachedData: Bool
        let loadedConfig: ReportConfig?
        if let workspace = ProfileService.workspaceURL(for: profile) {
            let configURL = workspace.appendingPathComponent("config.yaml")
            if FileManager.default.fileExists(atPath: configURL.path) {
                let config = try ConfigLoader.load(from: configURL)
                useCachedData = config.jamfCli?.isCachedDataEnabled ?? true
                loadedConfig = config
            } else {
                useCachedData = true
                loadedConfig = nil
            }
        } else {
            useCachedData = false
            loadedConfig = nil
        }

        // 2.6 accuracy track: when jamf_cli.require_manifest is set, stamp each
        // saved snapshot's sibling manifest.json so the strict-mode gate
        // (preflightStrictManifestCheck) has something to verify against.
        let recordManifest = loadedConfig?.jamfCli?.isManifestRequired == true

        let commands = Self.collectCommandMatrix(profile: profile)

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

        // Cadence state store: persists per-kind last-success timestamps so
        // the cadence filter skips reports that aren't due yet.
        let stateStore: StateFileStore? = (try? workspacePaths.stateDir(for: profile))
            .map(StateFileStore.init(directory:))
        let collectStart = Date()

        // Gate --no-hints/--no-version-check on the installed binary being >= 1.18.0.
        // These flags are 1.18-only; passing them to an older binary produces exit 1
        // (unknown flag) and silently skips every snapshot. Default-off when version
        // detection fails (nil) — safer than risking unknown flags on an old binary.
        // Scope: pro namespace only. school/protect namespace flag support is unverified;
        // those collect paths are left unmodified until confirmed via `school --help`.
        let detectedVersion = JamfCLIInstaller.installedVersion(at: bin)
        let supportsQuietFlags = detectedVersion.map {
            !JamfCLIInstaller.isBelowMinimumSupported($0)
        } ?? false

        // Resolved once per run, not per kind — it spawns `config list`.
        let nonPlatformAuth = Self.nonPlatformAuthMethod(
            ProfileAuthMethod.resolve(profile: profile, binary: bin)
        )

        let bridge = CLIBridge()
        var outcomes: [CollectOutcome] = []
        // Tracks kinds where saveSnapshot actually wrote a file this run.
        // Used to build liveKinds for R4 provenance — exit-0 non-JSON output
        // (Cobra help) passes the exitCode==0 filter but must NOT be "live".
        var savedKinds: Set<String> = []
        // Cadence "not due" skips only — NOT tier-filter skips, which say nothing
        // about server reachability. Feeds isCollectDead's veto: a run that skipped
        // fresh-cache kinds and failed only the chronic residue is not an outage.
        var skippedNotDueCount = 0
        for (args, kind) in plannedCommands {
            // Platform-only filter. Recorded nowhere: a kind this profile's API
            // cannot serve is not a failure, so it must not advance a failure
            // counter, reach `degradedKinds`, or count toward the outage guard.
            if let nonPlatformAuth, Self.platformOnlyKinds.contains(kind) {
                onLine(.init(
                    timestamp: Date(), level: .info,
                    text: "[skip] \(kind): requires a Platform API profile "
                        + "(auth-method is \(nonPlatformAuth))"
                ))
                continue
            }

            // T-9 tier filter: drop kinds outside the selected tier set.
            // An unmapped kind has no tier and is always allowed — the
            // tier map is a guidance layer, not a gate.
            if let tier = CollectionTier.tier(forReport: kind), !tiers.contains(tier) {
                onLine(.init(
                    timestamp: Date(), level: .info,
                    text: "[skip] \(kind): tier \(tier.rawValue) not selected"
                ))
                continue
            }

            // Cadence filter: skip when last-run + cadence is in the future.
            // Bypassed entirely when force == true so ad-hoc refreshes always refetch.
            let cadence = CadenceResolver.cadence(forReport: kind)
            let lastRun = stateStore?.lastRun(report: kind)
            if !force, !CadenceResolver.isDue(lastRun: lastRun, cadence: cadence, now: collectStart) {
                skippedNotDueCount += 1
                onLine(.init(
                    timestamp: Date(), level: .info,
                    text: "[skip] \(kind): not due (last: \(lastRunLabel(lastRun)), cadence: \(cadence.label))"
                ))
                continue
            }

            // Every kind that got this far produces an outcome, launch failures
            // included — see `launchFailureExitCode` for why that matters.
            let result = try await Self.collectOneKind(
                kind: kind, profile: profile, arguments: args,
                supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge,
                dataDir: dataDir, recordManifest: recordManifest,
                useCachedData: useCachedData, stateStore: stateStore,
                collectStart: collectStart, onLine: onLine
            )
            outcomes.append(result.outcome)
            if result.saved { savedKinds.insert(kind) }
        }

        try await Self.enforceCollectVerdicts(
            outcomes: outcomes, savedKinds: savedKinds,
            skippedNotDueCount: skippedNotDueCount, profile: profile, bin: bin,
            authConfirmationProbe: authConfirmationProbe, onLine: onLine
        )

        await Self.finalizeCollect(
            profile: profile, tiers: tiers, bin: bin, dataDir: dataDir,
            savedKinds: savedKinds, loadedConfig: loadedConfig,
            workspacePaths: workspacePaths, onLine: onLine
        )

        // Stamp this machine's activity so other Macs sharing the folder can
        // see the collect happened without parsing summaries. One file per
        // host, so concurrent runs never write the same path.
        if case .proceed(let state, _) = coordination, state.coordinating {
            SharedWorkspace.recordActivity(profile: profile)
        }
    }

    /// The three post-loop honesty checks, in the order they have to run:
    /// dead credentials first (actionable: re-authenticate), then a total
    /// outage, then the `[partial]` marker for a run where only some kinds
    /// landed. Both throws abort BEFORE any summary is written, so a run that
    /// fetched nothing can never promote stale cache as fresh data.
    private static func enforceCollectVerdicts(
        outcomes: [CollectOutcome],
        savedKinds: Set<String>,
        skippedNotDueCount: Int,
        profile: String,
        bin: URL,
        authConfirmationProbe: AuthConfirmationProbe,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) async throws {
        // Auth-dead guard: every live jamf-cli call failed and at least one returned
        // 401 (exit 3) → the profile's credentials are expired/revoked. Checked FIRST
        // so a total outage with 401s surfaces as an auth error (actionable: re-auth)
        // rather than as a generic dead-collect. Surface as a throw so the scheduled-run
        // catch records exit 1 (not a silent success serving stale cache), and abort
        // BEFORE SOFA/summary so no degraded snapshot is written. A single 401 among
        // successes does not reach here — it took the cache-fallback branch above.
        // Skipped when use_cached_data=false (that path already threw collectFailed on
        // the first failure).
        // Confirmation probe (see AuthConfirmationProbe's doc comment for the field
        // defect this fixes): one endpoint's 401 is not proof credentials are dead.
        // evaluateAuthDead only calls the probe when isCollectAuthDead is true.
        if let decision = await Self.evaluateAuthDead(
            outcomes: outcomes, profile: profile, bin: bin, probe: authConfirmationProbe
        ) {
            switch decision {
            case .confirmedAlive(let warnedKinds):
                let msg = "[warn] auth confirmation probe succeeded for '\(profile)' — " +
                    "credentials are valid. \(warnedKinds.joined(separator: ", ")) " +
                    "returned 401, but a direct `pro auth token` check passed, so this " +
                    "reads as endpoint-specific (a mid-command token expiry or a " +
                    "server-side token quirk on that command) rather than dead " +
                    "credentials. Updating jamf-cli may resolve it. Continuing."
                AppLogger.collect.warning("\(msg, privacy: .public)")
                onLine(.init(timestamp: Date(), level: .warn, text: msg))
            case .confirmedDead(let failedCount):
                let msg = "[error] auth failed for '\(profile)': \(failedCount) live call(s) " +
                    "returned 401 and none succeeded — re-authenticate " +
                    "(jamf-cli -p \(profile) pro auth token). No snapshot written."
                AppLogger.collect.error("\(msg, privacy: .public)")
                onLine(.init(timestamp: Date(), level: .fail, text: msg))
                throw ReportEngineError.authExpired(profile: profile, failedCount: failedCount)
            }
        }

        // Total-outage guard: all live calls failed, no 401 signals, no successes, no
        // "not due" cadence skips this run, and at least one failure isn't a bare exit-2
        // usage error → server unreachable or jamf-cli broken. Without this guard the run
        // falls through to SOFA + emitSummaryJSON and records Success while serving
        // entirely stale cache. Abort BEFORE SOFA/summary for the same reason as
        // auth-dead: no degraded snapshot should be promoted as fresh data. See
        // isCollectDead's doc comment for the field defect this veto set fixes.
        if Self.isCollectDead(outcomes, skippedNotDueCount: skippedNotDueCount) {
            let failedCount = outcomes.count
            let msg = "[error] all \(failedCount) live jamf-cli call(s) failed for '\(profile)' " +
                "(server unreachable or jamf-cli broken) — no snapshot written."
            AppLogger.collect.error("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .fail, text: msg))
            throw ReportEngineError.collectDead(profile: profile, failedCount: failedCount)
        }

        // Degraded-run summary. A run where some kinds fell back to cache is not
        // a success, but it is not a total outage either — the guards above only
        // fire when EVERYTHING failed, so before this a 1-of-30 survivor exited 0
        // and Run History showed a green pill. The `[partial]` prefix is the
        // marker `RunHistoryService.isPartialRun` scans for, so a snapshot-only
        // run (where this is the tail of the log) reports Partial instead of OK.
        // Launch failures reach this list too, via `launchFailureExitCode`.
        let unsavedKinds = Self.degradedKinds(outcomes: outcomes, savedKinds: savedKinds)
        if !unsavedKinds.isEmpty {
            let msg = "[partial] \(unsavedKinds.count) of \(outcomes.count) source(s) served "
                + "stale cache: \(unsavedKinds.joined(separator: ", "))"
            AppLogger.collect.warning("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .warn, text: msg))
        }
    }

    /// The post-collect work that turns saved snapshots into something the
    /// dashboards read: the SOFA feeds, the merged patch release dates, and
    /// the day's summary. Reached only once the verdicts above have passed.
    private static func finalizeCollect(
        profile: String,
        tiers: Set<CollectionTier>,
        bin: URL,
        dataDir: URL,
        savedKinds: Set<String>,
        loadedConfig: ReportConfig?,
        workspacePaths: WorkspacePaths.Type,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async {
        // SOFA OS currency: refresh all 4 platform feeds when the "sofa" kind
        // is in the requested tiers. Light network fetch — always in the Refresh tier
        // so snapshot-only and full runs both capture it.
        var sofaRefreshSucceeded = false
        if let sofaTier = CollectionTier.tier(forReport: "sofa"), tiers.contains(sofaTier) {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] collecting sofa for \(profile)"))
            let (sofaSnapshot, sofaWarnings) = await SOFAFeedService.refresh(dataDir: dataDir)
            for w in sofaWarnings {
                onLine(.init(timestamp: Date(), level: .warn, text: "[warn] \(w)"))
            }
            sofaRefreshSucceeded = !sofaSnapshot.rows.isEmpty
            onLine(.init(timestamp: Date(), level: .ok, text: "[ok] sofa: feeds refreshed"))
        }

        // Patch release dates: collect per-title definitions after patch-status.
        // Gated on the "patch-release-dates" kind being in the requested tiers
        // AND patch-status having been collected (so the title list exists).
        if let prdTier = CollectionTier.tier(forReport: "patch-release-dates"),
           tiers.contains(prdTier) {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] collecting patch-release-dates for \(profile)"))
            await collectPatchReleaseDates(
                profile: profile, bin: bin, dataDir: dataDir, onLine: onLine)
        }

        // PR-20: also emit summary.json from collect so the snapshot-only schedule
        // mode populates Trends without requiring a workbook generation. Skipped
        // when config is missing (fresh workspace pre-init) — generate() is the
        // only other site that produces these files, so the trend chart will
        // simply not advance until the next configured run.
        let unwritten: String?
        if let config = loadedConfig,
           let summariesDir = try? workspacePaths.summariesDir(for: profile) {
            let prov = await Provenance.current(
                profile: config.jamfCli?.resolvedProfile ?? profile,
                jamfCLIURL: bin,
                dataDir: dataDir
            )
            let engine = ReportEngine(config: config, dataDir: dataDir)
            // R4: kinds where saveSnapshot succeeded this run → "live" in summary.
            let liveKinds = Self.buildLiveKinds(savedKinds: savedKinds,
                                                sofaRefreshed: sofaRefreshSucceeded)
            unwritten = engine.emitSummaryJSON(
                summariesDir: summariesDir, provenance: prov,
                liveKinds: liveKinds, onLine: onLine
            ).partialReason
        } else if loadedConfig == nil {
            unwritten = "no config.yaml to summarize from"
        } else {
            unwritten = "the summaries directory could not be resolved"
        }

        // A collect that ends with no summary for today did not advance Trends,
        // whatever its exit code said. An all-exit-2 run is the reachable case:
        // `isCollectDead` deliberately forgives a bare usage error, so the run
        // reaches here having fetched nothing and would otherwise report a clean
        // "Trends updated". The marker belongs here rather than inside
        // `emitSummaryJSON` because `generate` calls that on its CSV-only path,
        // where having no jamf-cli snapshots is the normal, correct state.
        if let unwritten {
            let msg = "\(Self.summaryNotWrittenMarker) \(unwritten) — Trends did not advance"
            AppLogger.collect.warning("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .warn, text: msg))
        }
    }

    /// The jamf-cli commands `collect` fetches and the snapshot kind each
    /// one writes, in fetch order. A data table, lifted out of `collect` so the
    /// function reads as the flow it is. Must stay in sync with
    /// `knownCollectKinds` — `CollectionTierLookupTests` enforces that in CI.
    private static func collectCommandMatrix(
        profile: String
    ) -> [(args: [String], kind: String)] {
        [
            (["-p", profile, "pro", "overview", "--output", "json"], "overview"),
            (["-p", profile, "pro", "report", "security", "--output", "json"], "security"),
            (["-p", profile, "pro", "report", "patch-status", "--output", "json"], "patch-status"),
            (["-p", profile, "pro", "report", "patch-status", "--scan-failures",
              "--output", "json"], "patch-device-failures"),
            (["-p", profile, "pro", "report", "update-status", "--output", "json"],
             "update-status"),
            (["-p", profile, "pro", "report", "update-status", "--scan-failures",
              "--output", "json"], "update-device-failures"),
            (["-p", profile, "pro", "report", "inventory-summary", "--output", "json"],
             "inventory-summary"),
            (["-p", profile, "pro", "report", "device-compliance", "--output", "json"],
             "device-compliance"),
            (["-p", profile, "pro", "report", "policy-status", "--output", "json"],
             "policy-status"),
            // Command renamed upstream (classic-macos-profiles → …-config-profiles);
            // the snapshot key stays stable. Python already calls the new name.
            (["-p", profile, "pro", "classic-macos-config-profiles", "list", "--output", "json"],
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
            (["-p", profile, "pro", "computer-groups-smart-groups", "list", "--output", "json"],
             "smart-computer-groups"),
            (["-p", profile, "pro", "groups", "list", "--output", "json"], "groups"),
            (["-p", profile, "pro", "sites", "list", "--output", "json"], "sites"),
            (["-p", profile, "pro", "buildings", "list", "--output", "json"], "buildings"),
            (["-p", profile, "pro", "departments", "list", "--output", "json"], "departments"),
            (["-p", profile, "pro", "advanced-mobile-device-searches", "list", "--output", "json"],
             "advanced-mobile-device-searches"),
            (["-p", profile, "pro", "classic-computer-groups", "list", "--output", "json"],
             "classic-computer-groups"),
            (["-p", profile, "pro", "classic-mobile-device-groups", "list", "--output", "json"],
             "classic-mobile-device-groups"),
            (["-p", profile, "pro", "categories", "list", "--output", "json"],
             "categories"),
            (["-p", profile, "pro", "classic-mobile-config-profiles", "list", "--output", "json"],
             "classic-ios-profiles"),
            (["-p", profile, "pro", "device-enrollment-instances", "list", "--output", "json"],
             "device-enrollment-instances"),
            (["-p", profile, "pro", "mobile-device-inventory-details", "list", "--output", "json"],
             "mobile-device-inventory-details"),
            // Health audit — single cheap server call; matches CLIBridge.audit() shape that
            // AuditView and WorkspaceStore+Refresh all consume as "audit".
            // audit-platform-checks omitted: no Swift reader for that kind yet.
            (["-p", profile, "pro", "audit", "--output", "json", "--no-input"], "audit"),
            // v1.23.0+ only. Observed behavior on jamf-cli 1.21.1 (production, 2026-07):
            // an older binary exits 2 (usage — unrecognized subcommand), NOT Cobra's
            // exit-0-with-parent-help; exit 2 falls through the exit-0/exit-7 success
            // check below and is never saved. The isJSONSnapshot guard is kept as
            // defense-in-depth for any jamf-cli build that does print help at exit 0
            // (see the classic-macos-profiles rename comment), but the real-world
            // failure mode on old binaries is a clean non-zero exit.
            (["-p", profile, "pro", "report", "duplicate-serials", "--output", "json"],
             "duplicate-serials"),
        ]
    }

    /// Stand-in exit code recorded for a kind whose process never launched.
    ///
    /// Deliberately not 0 (which reads as success to every verdict below), not
    /// `CLIBridge.exitCodeUsage` (which `isCollectDead` excludes as saying
    /// nothing about the server), and not `exitCodeUnauthorized` (a launch
    /// failure is not a credential signal). Before this, a launch failure
    /// appended no outcome at all, so a run where jamf-cli failed to launch for
    /// EVERY kind produced an empty outcome set — and an empty set is not dead,
    /// so the run fell through to a summary built entirely from stale cache and
    /// recorded a green exit 0.
    static let launchFailureExitCode: Int32 = -1

    /// What one kind's attempt produced: the outcome that feeds the post-loop
    /// verdicts, and whether a snapshot actually reached disk.
    private struct KindCollectResult: Sendable {
        let outcome: CollectOutcome
        let saved: Bool
    }

    /// One kind's whole attempt — invoke, retry once when it is worth it,
    /// salvage the payload, save it, and record the bookkeeping.
    ///
    /// Lifted out of `collect`'s loop so that function is readable; the tier and
    /// cadence filters stay in the loop because they decide whether to call this
    /// at all. Throws exactly what the inline version threw: a `saveSnapshot`
    /// failure, and `collectFailed` under `use_cached_data: false`.
    private static func collectOneKind(
        kind: String,
        profile: String,
        arguments: [String],
        supportsQuietFlags: Bool,
        bin: URL,
        bridge: CLIBridge,
        dataDir: URL,
        recordManifest: Bool,
        useCachedData: Bool,
        stateStore: StateFileStore?,
        collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> KindCollectResult {
        AppLogger.collect.debug("collect kind=\(kind, privacy: .public)")
        onLine(.init(
            timestamp: Date(), level: .info,
            text: "[info] collecting \(kind) for \(profile)"
        ))
        let captureResult = await Self.invokeWithRetry(
            kind: kind, arguments: arguments, supportsQuietFlags: supportsQuietFlags,
            bin: bin, bridge: bridge, onLine: onLine
        )

        guard let (exitCode, data) = captureResult else {
            // Both launches failed. The failure counter carries the fact into
            // the next run, and the sentinel outcome carries it to this run's
            // own verdicts — a launch outage is an outage.
            stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
            return KindCollectResult(
                outcome: CollectOutcome(kind: kind, exitCode: Self.launchFailureExitCode),
                saved: false
            )
        }
        let outcome = CollectOutcome(kind: kind, exitCode: exitCode)
        let isPartialFailure = exitCode == CLIBridge.exitCodePartialFailure
        if (exitCode == 0 || isPartialFailure), !data.isEmpty {
            return try Self.saveCollectedPayload(
                kind: kind, data: data, outcome: outcome,
                isPartialFailure: isPartialFailure, dataDir: dataDir,
                recordManifest: recordManifest, stateStore: stateStore,
                collectStart: collectStart, onLine: onLine
            )
        } else if useCachedData {
            // use_cached_data=true: warn and skip. Only claim "using cached" when a
            // cached snapshot for this kind actually exists on disk — otherwise the
            // generate step has nothing to fall back to and the copy would mislead.
            let kindDir = dataDir.appendingPathComponent(kind, isDirectory: true)
            let hasCachedSnapshot = FileManager.newestJSONFile(in: kindDir) != nil
            let cacheNote = hasCachedSnapshot
                ? "skipped (using cached)"
                : "no cached snapshot available"
            // THE swallow this whole track exists to close: before the
            // counter, this warn line was the only trace that a kind failed,
            // and the run still exited 0. Persisting it is what lets
            // DataFreshnessHealth report a kind that has been failing nightly
            // for months without anyone opening its screen.
            stateStore?.record(.failed(exitCode: exitCode), report: kind, at: collectStart)
            // jamf-cli reports its own reason as a JSON error object; an
            // exit code alone sends the operator hunting. "exit 2 — no
            // cached snapshot available" is very nearly useless next to
            // "needs Jamf Security Cloud credentials", which is what
            // actually stopped the fleet security report on a live tenant.
            let reason = Self.jamfCLIErrorMessage(in: data).map { " (\($0))" } ?? ""
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] \(kind): exit \(exitCode)\(reason) — \(cacheNote)"))
            return KindCollectResult(outcome: outcome, saved: false)
        } else {
            // use_cached_data=false: treat collect failure as fatal for this kind.
            stateStore?.record(.failed(exitCode: exitCode), report: kind, at: collectStart)
            onLine(.init(
                timestamp: Date(), level: .fail,
                text: "[error] \(kind): exit \(exitCode) — failing (use_cached_data=false)"
            ))
            throw ReportEngineError.collectFailed(kind: kind, exitCode: exitCode)
        }
    }

    /// One kind's jamf-cli invocation plus the single in-run retry. nil means
    /// the process never launched — twice.
    ///
    /// Split out of `collectOneKind` for length only; a pure move.
    private static func invokeWithRetry(
        kind: String,
        arguments: [String],
        supportsQuietFlags: Bool,
        bin: URL,
        bridge: CLIBridge,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> (Int32, Data)? {
        // --no-hints suppresses interactive usage tips; --no-version-check
        // suppresses the "new version available" banner that jamf-cli 1.18+
        // emits on stderr. Both keep Runs-screen output signal-to-noise clean
        // during automated collects. Only appended when the binary is >= 1.18.0
        // (see `supportsQuietFlags` at the call site).
        let invokeArgs = supportsQuietFlags
            ? arguments + ["--no-hints", "--no-version-check"]
            : arguments
        @Sendable func invoke() async -> (Int32, Data)? {
            do {
                return try await bridge.runAndCapture(
                    executable: bin, arguments: invokeArgs,
                    environment: CLIBridge.environmentForJamfCLI(),
                    onLine: onLine
                )
            } catch {
                onLine(.init(timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): launch failed — \(error.localizedDescription)"))
                return nil
            }
        }

        var captureResult = await invoke()
        // Self-remediation, attempt 1: one immediate retry for a transient
        // exit. On-prem Jamf Pro times out heavy per-device queries under
        // load, and before this a single timeout meant the kind waited a
        // whole tier cadence (up to a week) for its next chance.
        let firstExit = captureResult?.0
        if firstExit == nil || Self.retryableExitCodes.contains(firstExit ?? 0) {
            let reason = firstExit.map { "exit \($0)" } ?? "launch failure"
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] \(kind): \(reason) — retrying once"))
            try? await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
            if let retried = await invoke() { captureResult = retried }
        }
        return captureResult
    }

    /// The exit-0 (and exit-7) half of one kind's attempt: salvage the payload,
    /// write the snapshot, and record the bookkeeping.
    ///
    /// Split out of `collectOneKind` only for length; the two together are the
    /// original loop body verbatim, in the original order. Not `async` — every
    /// step here is synchronous file work.
    private static func saveCollectedPayload(
        kind: String,
        data: Data,
        outcome: CollectOutcome,
        isPartialFailure: Bool,
        dataDir: URL,
        recordManifest: Bool,
        stateStore: StateFileStore?,
        collectStart: Date,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) throws -> KindCollectResult {
        if isPartialFailure {
            // exit 7 (v1.19.0+): some sub-operations failed, but stdout
            // contains valid JSON for the successful subset. Save it and
            // log a warning so the operator knows to check the full log.
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] \(kind): exit 7 (partial failure) — partial data returned"))
        }
        // Cobra prints the parent help and exits 0 for an unknown
        // subcommand — saving that as a snapshot poisons the cache
        // (a renamed command filled classic-macos-profiles with help
        // text). Python's bridge json.loads()es output, so this
        // guard keeps the engines equivalent.
        // patch-status --scan-failures prints several ── section ──
        // blocks; only one of them is this kind. Selected before the
        // generic guard, because the generic path would otherwise file
        // the compliance section under patch-device-failures on any
        // tenant with no failures.
        let salvaged = sectionedCollectKinds.contains(kind)
            ? Self.patchDeviceFailurePayload(from: data, onLine: onLine)
            : jsonPayload(from: data)
        guard let payload = salvaged else {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] \(kind): output is not JSON (renamed/unsupported "
                    + "command on this jamf-cli?) — snapshot not saved"))
            // Exit 0 with unusable output is a failure for this kind even
            // though the process succeeded — count it, or a renamed command
            // stays permanently invisible behind a green run.
            stateStore?.record(.failed(exitCode: outcome.exitCode), report: kind, at: collectStart)
            return KindCollectResult(outcome: outcome, saved: false)
        }
        if payload.count != data.count {
            let note = sectionedCollectKinds.contains(kind)
                ? "of section headings and other sections jamf-cli printed alongside it"
                : "of non-JSON text printed before the payload"
            onLine(.init(timestamp: Date(), level: .info,
                text: "[info] \(kind): dropped \(data.count - payload.count) byte(s) "
                    + note))
        }
        do {
            try saveSnapshot(
                data: payload, kind: kind, dataDir: dataDir,
                recordManifest: recordManifest, onLine: onLine
            )
        } catch {
            // The throw aborts the whole collect, so without this the kind
            // that caused it would be the one kind with no record of having
            // failed — and its cadence boundary would stay wherever the last
            // success left it.
            stateStore?.record(.failed(exitCode: outcome.exitCode), report: kind, at: collectStart)
            onLine(.init(timestamp: Date(), level: .fail,
                text: "[fail] \(kind): snapshot could not be written — "
                    + error.localizedDescription))
            throw error
        }
        // T-8: advances the cadence boundary and clears the failure
        // streak — see StateFileStore.record for why both live there.
        stateStore?.record(.landed, report: kind, at: collectStart)
        if !isPartialFailure {
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] \(kind): \(data.count) bytes"))
        }
        return KindCollectResult(outcome: outcome, saved: true)
    }

    /// Whether this workspace is coordinated, and whether this run holds the claim.
    struct CoordinationState: Equatable, Sendable {
        let coordinating: Bool
        let holdsClaim: Bool
    }

    /// The whole "should this Mac collect right now" decision.
    enum CoordinationOutcome: Equatable, Sendable {
        /// Go ahead. `notes` carries anything the operator should see but that
        /// is not a reason to stop (a stale claim taken over, a peer working
        /// alongside a forced run).
        case proceed(CoordinationState, notes: [String])
        /// Do not collect; the string explains why, in the operator's terms.
        case standDown(String)
    }

    /// Decide whether to collect, and claim the workspace if so.
    ///
    /// Deliberately reads config itself rather than taking the already-loaded
    /// value: it runs before the main config load and before the jamf-cli
    /// check, so the decision never depends on the binary being installed. A
    /// config that fails to parse coordinates nothing — the real load reports
    /// the parse error properly, and refusing to collect because a coordination
    /// block is unreadable would be the wrong failure.
    static func coordinationGate(
        profile: String,
        force: Bool,
        operation: String = "collect",
        checkFreshness: Bool = true,
        now: Date = Date()
    ) -> CoordinationOutcome {
        let idle = CoordinationState(coordinating: false, holdsClaim: false)
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            return .proceed(idle, notes: [])
        }
        let config = try? ConfigLoader.load(
            from: workspace.appendingPathComponent("config.yaml")
        )
        let shared = config?.sharedWorkspace ?? SharedWorkspaceConfig()
        let synced = CloudStorage.provider(for: workspace) != nil
        guard shared.isEnabled(workspaceIsSynced: synced) else {
            return .proceed(idle, notes: [])
        }

        // Freshness: a scheduled run stands down when another machine collected
        // recently — one collect per interval across the team, not one per Mac.
        // An explicit Refresh is a deliberate operator action and proceeds.
        if checkFreshness, !force,
           let recent = SharedWorkspace.newestOtherCollect(profile: profile),
           case .skipCollectedElsewhere(let host, let at) = SharedWorkspace.freshness(
               lastCollectHost: recent.host,
               lastCollectAt: recent.at,
               me: SharedWorkspace.currentHost,
               minInterval: shared.minCollectInterval,
               now: now
           ) {
            return .standDown(
                "[info] skipping collect — \(host.display) collected "
                    + "\(Self.approximateAge(since: at, now: now)) "
                    + "(shared workspace; use Refresh to collect anyway)"
            )
        }

        switch SharedWorkspace.acquire(
            profile: profile, operation: operation, ttl: shared.claimTTL, now: now
        ) {
        case .acquire:
            return .proceed(
                CoordinationState(coordinating: true, holdsClaim: true), notes: []
            )
        case .takeOverExpired(let stale):
            return .proceed(
                CoordinationState(coordinating: true, holdsClaim: true),
                notes: ["[warn] taking over an expired claim from \(stale.host.display) "
                    + "(started \(Self.approximateAge(since: stale.startedAt, now: now)), "
                    + "never released)"]
            )
        case .blocked(let live):
            // Advisory only: a human who asked for this run wins, and is told
            // what they are running alongside. A scheduled run defers.
            let note = "[warn] \(live.host.display) is running \(live.operation) in this "
                + "workspace until \(Self.approximateAge(until: live.expiresAt, now: now))"
            guard force else {
                return .standDown(
                    note + " — standing down; another machine is already working here"
                )
            }
            return .proceed(
                CoordinationState(coordinating: true, holdsClaim: false), notes: [note]
            )
        }
    }

    /// Rough human phrasing for a past instant ("12 minutes ago", "2 days ago").
    /// Deliberately coarse — these strings sit in log lines an operator skims,
    /// not in anything a decision is made from.
    static func approximateAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        return "\(Self.durationPhrase(seconds)) ago"
    }

    /// Rough human phrasing for a future instant ("in about 20 minutes").
    static func approximateAge(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        return seconds < 60 ? "shortly" : "in about \(Self.durationPhrase(seconds))"
    }

    private static func durationPhrase(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    // MARK: - Patch release date collection

    /// Fetch per-title patch definitions from jamf-cli and write the merged
    /// `patch-release-dates_<ts>.json` snapshot.
    ///
    /// Reads the current patch-status snapshot for the title list, then runs
    /// `pro patch-software-title-configurations definitions <id>` for each title.
    /// Mirrors Python's `JamfCLIBridge.collect_patch_release_dates`.
    /// Non-fatal: warn and skip titles that fail rather than aborting the run.
    private static func collectPatchReleaseDates(
        profile: String,
        bin: URL,
        dataDir: URL,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async {
        // Read patch-status snapshot to get title list.
        guard let patchData = try? loadLatestSnapshotData(kind: "patch-status", dataDir: dataDir),
              let patchItems = try? JSONDecoder().decode([PatchStatusRow].self, from: patchData)
        else {
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] patch-release-dates: no patch-status snapshot; skipping"))
            return
        }

        let bridge = CLIBridge()
        var merged: [[String: String]] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let ts = formatter.string(from: Date())

        for patchItem in patchItems {
            let titleId = patchItem.id.trimmingCharacters(in: .whitespacesAndNewlines)
            // titleId is server-supplied and lands in a bare positional argv
            // slot below — refuse a leading dash exactly like singleDeviceDetail
            // already refuses one. The rejected value is not echoed.
            guard CLIBridge.isSafeDeviceIdentifier(titleId) else {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] patch-definitions: skipping title with an unsafe id"))
                continue
            }
            // Sanitize id for filename — mirrors Python's `re.sub(r"[^0-9A-Za-z._-]", "_", id)`.
            let safeId = titleId.unicodeScalars.map { c -> Character in
                let ch = Character(c)
                if ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" {
                    return ch
                }
                return "_"
            }.reduce("") { $0 + String($1) }

            let args = ["-p", profile, "pro", "patch-software-title-configurations",
                        "definitions", titleId, "--page-size", "100", "--output", "json"]
            let captureResult = try? await bridge.runAndCapture(
                executable: bin, arguments: args,
                environment: CLIBridge.environmentForJamfCLI(), onLine: { _ in })
            guard let (exitCode, data) = captureResult, exitCode == 0, !data.isEmpty else {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] patch-definitions: title \(titleId) failed — skipping"))
                continue
            }

            // Cache per-title definition file.
            let defsDir = dataDir.appendingPathComponent("patch-definitions", isDirectory: true)
            try? FileManager.default.createDirectory(at: defsDir, withIntermediateDirectories: true)
            let cacheFile = defsDir.appendingPathComponent(
                "patch-definitions_title\(safeId).json")
            try? data.write(to: cacheFile)

            // Extract latest definition date.
            guard let definitions = try? JSONSerialization.jsonObject(with: data)
                    as? [[String: Any]]
            else { continue }
            let (version, releaseDate) = PatchReleaseDateService.latestDefinitionDate(
                definitions: definitions, latestVersion: patchItem.latest)
            guard !releaseDate.isEmpty else { continue }
            merged.append([
                "title_id": titleId,
                "title": patchItem.title,
                "latest_version": version,
                "release_date": releaseDate,
            ])
        }

        // Write merged snapshot.
        do {
            let outDir = dataDir.appendingPathComponent("patch-release-dates", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let outFile = outDir.appendingPathComponent("patch-release-dates_\(ts).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let payload = try encoder.encode(merged)
            try payload.write(to: outFile)
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] patch-release-dates: \(merged.count) title(s)"))
        } catch {
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] patch-release-dates: could not write snapshot — " +
                               error.localizedDescription))
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
    ///               Defaults to `FullInstanceTemplate()`.
    @discardableResult
    static func generateHTML(
        config: ReportConfig,
        dataDir: URL,
        outputURL: URL,
        template: any ReportTemplate = FullInstanceTemplate(),
        aiNarrative: String? = nil,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) async throws -> String {
        // PR-10 / threat-model T-11: strict-mode pre-flight applies to HTML
        // generation too — otherwise the GUI's "Require snapshot manifest"
        // toggle would be a false promise for users who generate HTML reports.
        try preflightStrictManifestCheck(config: config, dataDir: dataDir)
        let report = HtmlReport(config: config, dataDir: dataDir, aiNarrative: aiNarrative)
        let digest = try await report.generate(
            outputURL: outputURL, sections: template.htmlSections
        )
        // Write SHA-256 manifest alongside the HTML artifact.
        let profile = config.jamfCli?.resolvedProfile ?? ""
        writeManifestStatic(for: outputURL, profile: profile, template: template.identifier)
        // T-13 integrity envelope: surface the embedded fingerprint via the log
        // stream so the GUI can show it in the "Report ready" toast.
        onLine?(.init(
            timestamp: Date(),
            level: .ok,
            text: "[ok] sha256: \(digest) \(outputURL.lastPathComponent)"
        ))
        return digest
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
        template: any ReportTemplate = FullInstanceTemplate()
    ) async throws {
        // PR-10 / threat-model T-11: strict-mode pre-flight applies to PDF
        // generation too. PDF is built on top of HTML; the underlying snapshot
        // data must be verified before either artifact is produced.
        try preflightStrictManifestCheck(config: config, dataDir: dataDir)
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
    ///
    /// Throws `ReportEngineError.collectDead` when commands were attempted and none
    /// succeeded, so a dead School tenant does not silently record Success forever.
    /// Partial failures (≥1 success) warn and continue — the same fallback-to-cache
    /// policy as the Jamf Pro collect path.
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
        var schoolOutcomes: [CollectOutcome] = []
        for (args, kind) in commands {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] collecting \(kind) for \(profile)"))
            let schoolResult: (Int32, Data)?
            do {
                schoolResult = try await bridge.runAndCapture(
                    executable: bin, arguments: args,
                    environment: CLIBridge.environmentForJamfCLI(),
                    onLine: onLine
                )
            } catch {
                onLine(.init(timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): launch failed — \(error.localizedDescription)"))
                schoolResult = nil
            }
            guard let (exitCode, data) = schoolResult else { continue }
            schoolOutcomes.append(CollectOutcome(kind: kind, exitCode: exitCode))
            if exitCode == 0, !data.isEmpty {
                // Cobra prints the parent help and exits 0 for an unknown
                // subcommand — saving that as a snapshot poisons the cache.
                // See the matching guard in the Pro collect loop above.
                guard isJSONSnapshot(data) else {
                    onLine(.init(timestamp: Date(), level: .warn,
                        text: "[warn] \(kind): output is not JSON (renamed/unsupported "
                            + "command on this jamf-cli?) — snapshot not saved"))
                    continue
                }
                try saveSnapshot(data: data, kind: kind, dataDir: dataDir)
                onLine(.init(timestamp: Date(), level: .ok,
                             text: "[ok] \(kind): \(data.count) bytes"))
            } else {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] \(kind): exit \(exitCode) — skipped"))
            }
        }

        // Total-outage guard for School: commands were attempted but none succeeded.
        // Without this, a dead School tenant silently records Success on every run.
        // Checked after the full loop (same as Jamf Pro collect) so partial failures
        // still warm the cache. Launch-failures (nil schoolResult) are excluded from
        // schoolOutcomes intentionally — they carry no exit code signal.
        if Self.isCollectDead(schoolOutcomes) {
            let failedCount = schoolOutcomes.count
            let msg = "[error] all \(failedCount) live jamf-cli school call(s) failed for " +
                "'\(profile)' — server unreachable or credentials broken. No snapshot written."
            AppLogger.collect.error("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .fail, text: msg))
            throw ReportEngineError.collectDead(profile: profile, failedCount: failedCount)
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
            (["-p", profile, "protect", "plans", "list", "--output", "json"], "protect-plans"),
        ]

        let bridge = CLIBridge()
        for (args, kind) in commands {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] collecting \(kind) for \(profile)"))
            let protectResult: (Int32, Data)?
            do {
                protectResult = try await bridge.runAndCapture(
                    executable: bin, arguments: args,
                    environment: CLIBridge.environmentForJamfCLI(),
                    onLine: onLine
                )
            } catch {
                onLine(.init(timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): launch failed — \(error.localizedDescription)"))
                protectResult = nil
            }
            guard let (exitCode, data) = protectResult else { continue }
            if exitCode == 0, !data.isEmpty {
                // Cobra prints the parent help and exits 0 for an unknown
                // subcommand — saving that as a snapshot poisons the cache.
                // See the matching guard in the Pro collect loop above.
                guard isJSONSnapshot(data) else {
                    onLine(.init(timestamp: Date(), level: .warn,
                        text: "[warn] \(kind): output is not JSON (renamed/unsupported "
                            + "command on this jamf-cli?) — snapshot not saved"))
                    continue
                }
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
    ///
    /// - Returns: A list of `SheetFailure` entries for school sheets that encountered
    ///            unexpected errors. Absent snapshots (`SchoolDashboardError.noCachedData`)
    ///            are graceful skips and are not included.
    @discardableResult
    static func schoolGenerate(
        config: ReportConfig,
        csvURL: URL?,
        dataDir: URL,
        outputURL: URL
    ) async throws -> [SheetFailure] {
        // PR-10 / threat-model T-11: strict-mode pre-flight applies to School
        // generation too. School snapshots live under the same workspace data
        // dir and share the manifest discipline; integrity violations here
        // should abort the run, not silently render against tampered data.
        try preflightStrictManifestCheck(config: config, dataDir: dataDir)
        let workbook = Workbook(accentColor: config.branding?.resolvedAccentColor ?? "#2D5EA2")
        let core = SchoolDashboard(config: config, dataDir: dataDir, workbook: workbook)
        let (_, schoolFailures) = core.writeAll()

        if let csvURL {
            let csvData = try Data(contentsOf: csvURL)
            let school = SchoolCSVDashboard(config: config, csvData: csvData, workbook: workbook)
            // SchoolCSVDashboard.writeAll() is currently a stub returning [].
            _ = school?.writeAll()
        }

        try workbook.write(to: outputURL)
        // T-13 integrity envelope: write `<basename>.xlsx.sha256` sidecar.
        _ = writeSHA256Sidecar(for: outputURL)
        return schoolFailures
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

        // Include the profile in the filename so reports remain attributable
        // to their tenant once moved out of the workspace folder.
        // `report_prod_2026-06-01_120000.xlsx`, not `report_2026-06-01_120000.xlsx`.
        let namedStem: String = {
            guard let profile else { return stem }
            let sanitized = ExportNaming.sanitize(profile)
            return sanitized.isEmpty ? stem : "\(stem)_\(sanitized)"
        }()

        let shouldTimestamp = config.output?.timestampOutputs ?? true
        if shouldTimestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
            let ts = formatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "-")
                .replacingOccurrences(of: "T", with: "_")
            return outDir.appendingPathComponent("\(namedStem)_\(ts).xlsx")
        } else {
            return outDir.appendingPathComponent("\(namedStem).xlsx")
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
                AppLogger.collect.warning(
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

    /// Assembles the liveKinds set for R4 provenance from the kinds that were
    /// actually saved this run. `sofa` is added when the SOFA refresh returned rows.
    /// Pure function — testable without subprocess dependencies.
    static func buildLiveKinds(savedKinds: Set<String>, sofaRefreshed: Bool) -> Set<String> {
        var result = savedKinds
        if sofaRefreshed { result.insert("sofa") }
        return result
    }

    /// True when `data` parses as JSON. Snapshot saves are gated on this:
    /// Cobra's unknown-subcommand help text arrives with exit 0 and must
    /// never be cached as a .json snapshot.
    /// jamf-cli's own explanation for a failure, when it emitted one.
    ///
    /// A non-zero exit is accompanied by a JSON object carrying `message`
    /// (alongside `error`/`exitCode`/`exitCodeName`). Surfacing it turns an
    /// opaque number into the actual problem — and it stays useful for reasons
    /// this app has never heard of, which an exit-code table cannot.
    ///
    /// Truncated to keep one bad call from flooding a run log.
    static func jamfCLIErrorMessage(in data: Data, limit: Int = 300) -> String? {
        guard let payload = jsonPayload(from: data),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let message = object["message"] as? String else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    static func isJSONSnapshot(_ data: Data) -> Bool {
        jsonPayload(from: data) != nil
    }

    /// The JSON payload in `data`, tolerating decorative text printed ahead of it.
    ///
    /// `--output json` is supposed to put nothing but JSON on stdout, and
    /// mostly does. But jamf-cli 1.24+ prints a section header before the array
    /// for `pro report patch-status --scan-failures`:
    ///
    ///     ── Patch Title Compliance ──
    ///     [ { ... } ]
    ///
    /// which made the whole snapshot unparseable and silently dropped the Patch
    /// Failures sheet on a live tenant. Rather than pattern-match that one
    /// banner, skip to the first `[` or `{` and parse from there — the same
    /// repair works for whatever decoration a future release adds.
    ///
    /// This only forgives a *prefix*. Anything that still fails to parse is
    /// still rejected, so a genuinely broken or truncated payload is never
    /// promoted to a snapshot.
    /// Snapshot kinds whose jamf-cli command emits several `── section ──`
    /// blocks on stdout rather than one document. Only `patch-status
    /// --scan-failures` does this: its sibling `update-status --scan-failures`
    /// guards structured output and returns one object with named keys, which
    /// is why `update-device-failures` needs nothing here.
    static let sectionedCollectKinds: Set<String> = ["patch-device-failures"]

    /// Splits a sectioned jamf-cli stream into its parseable JSON documents.
    ///
    /// `--output json` is supposed to put only the document on stdout, but
    /// `patch-status --scan-failures` prints a `── Heading ──` line before each
    /// of up to three arrays. Sections are separated on those heading lines, so
    /// nothing depends on the heading text itself.
    static func jsonSections(from data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var sections: [Data] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !trimmed.isEmpty, let chunk = trimmed.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: chunk, options: [])) != nil
            else { return }
            sections.append(chunk)
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\u{2500}\u{2500}") {
                flush()
            } else {
                current += line + "\n"
            }
        }
        flush()
        return sections
    }

    /// Picks the device-failure rows out of a `patch-status --scan-failures`
    /// stream.
    ///
    /// The stream carries up to three arrays — title compliance, policies with
    /// failures, then devices — and only the last is what this kind holds. The
    /// first is always present, so taking the first (or the last) parseable
    /// document would file compliance rows under `patch-device-failures` on the
    /// common tenant that has no failures at all. Devices are identified by
    /// their `device_id` field rather than by heading text or position.
    ///
    /// Returns an empty array when the stream parsed but carried no device
    /// section: that means no failures, which is a real answer. Returns nil only
    /// when nothing parsed, so genuinely broken output still trips the caller's
    /// guard instead of being recorded as a clean zero.
    ///
    /// A multi-section stream with no device rows warns through `onLine`. On a
    /// healthy tenant that is the normal shape (compliance, sometimes policies,
    /// no devices), but it is also what an upstream field rename would look
    /// like — and a rename would be indistinguishable from a clean zero without
    /// a line saying which shape produced it.
    static func patchDeviceFailurePayload(
        from data: Data,
        onLine: @Sendable (CLIBridge.LogLine) -> Void = CLIBridge.noOpOnLine
    ) -> Data? {
        let sections = jsonSections(from: data)
        guard !sections.isEmpty else { return nil }
        for section in sections {
            guard let rows = try? JSONSerialization.jsonObject(with: section, options: [])
                    as? [[String: Any]] else { continue }
            guard let first = rows.first else { continue }
            if first["device_id"] != nil { return section }
        }
        if sections.count > 1 {
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] patch-device-failures: \(sections.count) sections parsed, "
                    + "none carried device rows — treating as no failures"
            ))
        }
        return Data("[]".utf8)
    }

    static func jsonPayload(from data: Data) -> Data? {
        if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            return data
        }
        guard let start = data.firstIndex(where: {
            $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "{")
        }), start > data.startIndex else { return nil }
        let trimmed = data[start...]
        guard (try? JSONSerialization.jsonObject(with: trimmed, options: [])) != nil else {
            return nil
        }
        return Data(trimmed)
    }

    private static func saveSnapshot(
        data: Data,
        kind: String,
        dataDir: URL,
        recordManifest: Bool = false,
        onLine: @Sendable (CLIBridge.LogLine) -> Void = CLIBridge.noOpOnLine
    ) throws {
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
        // Atomic (temp file + rename) so a same-second collision, crash, or
        // full disk mid-write never leaves a torn snapshot on disk — mirrors
        // CLIBridge.saveJSONSnapshot's S-01 discipline. The 0600 setAttributes
        // below still runs on the final path regardless, so this does not
        // change the permission it ends up with.
        try data.write(to: file, options: .atomic)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: file.path
            )
        } catch {
            AppLogger.collect.warning(
                "saveSnapshot: setAttributes failed for \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
        }
        // 2.6 accuracy track: stamp the sibling manifest.json so strict-mode
        // verification (SnapshotManifest.verify) becomes reachable for
        // app-collected snapshots. Gated on jamf_cli.require_manifest by the
        // caller. Best-effort — a manifest-write failure must NOT fail the
        // collect (worst case: verify() reads .absent/.omitted, never .verified).
        if recordManifest {
            do {
                try SnapshotManifest.record(snapshotFile: file, data: data)
            } catch {
                // .error, not .warning — under require_manifest this snapshot will
                // now verify as .omitted instead of .verified, quietly degrading
                // the "no unverified data" promise. Also surfaced on the collect
                // stream (onLine) so it lands in Run History, not just Console.app.
                AppLogger.collect.error(
                    "saveSnapshot: manifest write failed for \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] snapshot manifest write failed for \(kind) — verify will report this snapshot as unverified"
                ))
            }
        }
    }

    /// Thrown by `loadLatestSnapshotData` when the newest snapshot for `kind`
    /// is older than the `max_cache_age_hours` limit. Callers treat this like
    /// ABSENT data (skip the kind, warn) — never a hard failure.
    struct SnapshotCacheExpired: Error { let kind: String; let ageHours: Int; let limitHours: Int }

    /// Load the newest snapshot for `kind`. When `maxCacheAgeHours > 0` and the
    /// newest file is older than the limit, throws `SnapshotCacheExpired` so the
    /// caller can treat stale cache as absent instead of silently serving it.
    /// `maxCacheAgeHours <= 0` disables the age check (keep-forever).
    ///
    /// The age gate is deliberately asymmetric: only the daily summary/digest
    /// path passes a non-zero `maxCacheAgeHours`. Report sheets pass 0 and render
    /// whatever cache exists, carrying their own "data as of" subtitles — a stale
    /// but complete report is more useful than an empty one.
    private static func loadLatestSnapshotData(
        kind: String,
        dataDir: URL,
        maxCacheAgeHours: Int = 0
    ) throws -> Data {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), !files.isEmpty else {
            throw ReportEngineError.snapshotParseError(kind)
        }
        // Order and age snapshots by the timestamp encoded in the FILENAME
        // (mtime fallback for non-canonical names), matching newestSnapshotFile
        // and the chart/drift builders. On synced storage (iCloud/SharePoint)
        // mtimes lie — the file provider re-stamps them on sync — so an
        // mtime-ordered pick here would disagree with every filename-ordered
        // reader: the digest could report a kind absent (or serve older
        // content) while Compliance Posture shows full data from the same dir.
        func snapshotDate(_ url: URL) -> Date {
            // Non-optional: falls back to mtime internally for non-canonical names.
            MSCPChartDataBuilder.dateFromSnapshotFilename(url)
        }
        // Selection uses the one shared rule (`FileSystemHelpers`), which drops
        // the sibling manifest.json, `.partial` staging files and a provider's
        // sync-conflict copy before ordering. The conflict copy matters most
        // here: it carries the SAME filename stamp as its original, so ordering
        // alone resolves the tie by directory-enumeration order and can return
        // the copy — and this picker feeds the day's summary.json.
        let newest = FileManager.newestSnapshot(
            among: files.filter { $0.pathExtension == "json" })
        guard let url = newest else {
            throw ReportEngineError.snapshotParseError(kind)
        }
        if maxCacheAgeHours > 0 {
            let ageHours = Int(Date().timeIntervalSince(snapshotDate(url)) / 3600)
            if ageHours > maxCacheAgeHours {
                throw SnapshotCacheExpired(kind: kind, ageHours: ageHours, limitHours: maxCacheAgeHours)
            }
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
        // Formula-injection neutralization: tab-prefix cells beginning with =, +, -, @.
        // Mirrors PatchStatusService.csvField and Python's _csv_injection_safe.
        var field = value
        if let first = field.first, "=+-@".contains(first) {
            field = "\t" + field
        }
        guard field.contains(where: { ",\"\n\r".contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Internal entry point for injection-guard testing — mirrors `testableScaffoldMappings`.
    static func testableCSVEscape(_ value: String) -> String {
        csvEscape(value)
    }

    /// Test-only exposure of `saveSnapshot` — mirrors `testableScaffoldMappings`.
    static func testableSaveSnapshot(
        data: Data,
        kind: String,
        dataDir: URL,
        recordManifest: Bool,
        onLine: @escaping @Sendable (CLIBridge.LogLine) -> Void
    ) throws {
        try saveSnapshot(
            data: data, kind: kind, dataDir: dataDir,
            recordManifest: recordManifest, onLine: onLine
        )
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

    /// T-13 integrity envelope: write a `<file>.sha256` sidecar in
    /// `shasum -a 256` output format so recipients can verify the artifact
    /// with `shasum -a 256 -c <basename>.sha256` from the file's directory.
    ///
    /// Format: ``<64hex><two-spaces><basename><LF>`` — two spaces and the
    /// basename only are required for `shasum -c` to succeed.
    ///
    /// Returns the hex digest on success or `nil` if the artifact could not
    /// be read or the sidecar could not be written. Errors are logged and
    /// swallowed — a sidecar write must never abort artifact delivery.
    @discardableResult
    static func writeSHA256Sidecar(for artifactURL: URL) -> String? {
        guard let data = try? Data(contentsOf: artifactURL) else {
            fputs("[warn] sha256 sidecar: could not read \(artifactURL.lastPathComponent)\n",
                  stderr)
            return nil
        }
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        let sidecarURL = artifactURL.appendingPathExtension("sha256")
        let line = "\(hex)  \(artifactURL.lastPathComponent)\n"
        do {
            try line.write(to: sidecarURL, atomically: true, encoding: .utf8)
            return hex
        } catch {
            fputs("[warn] sha256 sidecar: could not write \(sidecarURL.lastPathComponent): \(error)\n",
                  stderr)
            return nil
        }
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

    // MARK: - PR-10 / threat-model T-11: strict-manifest pre-flight

    /// When `jamf_cli.require_manifest: true`, scan the workspace's snapshot
    /// directories and abort the whole report run if any newest snapshot
    /// fails SHA-256 verification (`.mismatch` or `.corrupt`). `.absent` and
    /// `.omitted` results don't trigger — legacy snapshots without a
    /// manifest and partial collects cannot be retroactively verified.
    ///
    /// **Static helper** so every report-generation entry point (the
    /// instance `generate()`, plus static `generateHTML`, `generatePDF`,
    /// `schoolGenerate`) can enforce the gate without duplicating logic.
    /// Each entry point must call this before reading any snapshot data —
    /// per-sheet checks would land in `SheetSkippable` handling and just
    /// skip the offending sheet, not abort the run.
    ///
    /// Closes the gap (security-reviewer 2nd review) where only XLSX
    /// generation enforced strict mode — HTML, PDF, and School paths were
    /// silently exempt, defeating the "GUI false-promise" fix.
    static func preflightStrictManifestCheck(
        config: ReportConfig,
        dataDir: URL
    ) throws {
        guard config.jamfCli?.isManifestRequired == true else { return }
        let summary = SnapshotManifest.scanWorkspace(dataDir: dataDir)
        if summary.mismatch > 0 || summary.corrupt > 0 {
            throw ReportEngineError.snapshotIntegrityViolation(
                summary: summary,
                dataDir: dataDir
            )
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
    /// Raised at the end of collect when every live jamf-cli call failed and at
    /// least one returned HTTP 401 (exit 3) — the profile's credentials are dead
    /// (expired or revoked) and need re-auth. Surfaces the run as non-success so a
    /// scheduled job records exit 1 (not a silent success serving stale cache), and
    /// is thrown BEFORE summary emission so no degraded snapshot is written. A 401
    /// among successful calls is NOT this — that falls back to cache per
    /// `use_cached_data`. Chronic non-auth failures (Platform-API 404 → exit 1 on
    /// on-prem) carry no 401 and cannot trip this on their own.
    case authExpired(profile: String, failedCount: Int)
    /// Raised at the end of collect when live calls were attempted, ALL failed
    /// (any non-zero exit code), and none returned HTTP 401 — the server is
    /// unreachable, jamf-cli is broken, or every endpoint returned a non-auth
    /// error. Like `authExpired`, this is thrown BEFORE SOFA refresh and
    /// `emitSummaryJSON` so no stale-cache summary is promoted as fresh data.
    /// Partial failures (≥1 success) do NOT reach this — they warm the cache
    /// and the run continues normally.
    case collectDead(profile: String, failedCount: Int)
    /// PR-10 / threat-model T-11: raised at run start when
    /// `jamf_cli.require_manifest: true` and at least one snapshot directory's
    /// newest JSON fails SHA-256 verification (mismatch or corrupt manifest).
    /// Aborts the whole generate run before any sheet writes start — matches
    /// the Python `--strict-manifest` `RuntimeError` semantics. `.absent` and
    /// `.omitted` results don't trigger this (legacy snapshots and partial
    /// collects can't be retroactively verified).
    case snapshotIntegrityViolation(
        summary: SnapshotManifest.WorkspaceVerificationSummary,
        dataDir: URL
    )

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
        case .authExpired(let p, let n):
            return "Authentication failed for profile '\(p)': all \(n) live Jamf Pro call(s) " +
                "returned 401 (expired or revoked credentials) and none succeeded. " +
                "Re-authenticate with: jamf-cli -p \(p) pro auth token. No snapshot was written."
        case .collectDead(let p, let n):
            return "All \(n) live jamf-cli call(s) failed for profile '\(p)' (server unreachable " +
                "or jamf-cli broken). No snapshot was written. Check network connectivity and " +
                "jamf-cli health, then re-run collect."
        case .snapshotIntegrityViolation(let summary, let dataDir):
            var parts: [String] = []
            if summary.mismatch > 0 { parts.append("\(summary.mismatch) hash mismatch") }
            if summary.corrupt > 0 { parts.append("\(summary.corrupt) corrupt manifest") }
            let breakdown = parts.joined(separator: ", ")
            return "Snapshot integrity violation in \(dataDir.path): \(breakdown). " +
                "jamf_cli.require_manifest is enabled; re-run 'collect' to refresh the " +
                "snapshot+manifest, or set require_manifest: false to bypass."
        }
    }
}

/// PR-22 T-8: render a `lastRun` Date for the "not due" log line.
/// `nil` becomes `"never"` so operators reading the run log immediately
/// see "first fetch was skipped because cadence=never" without needing to
/// cross-reference the state file. Byte-stable ISO-8601 UTC matches
/// `StateFileStore`'s on-disk format so logs and files agree literally.
///
/// `nonisolated(unsafe)` for the same reason as `StateFileStore.formatter`
/// — the post-init read methods are reentrant on macOS.
nonisolated(unsafe) private let collectLogDateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

private func lastRunLabel(_ date: Date?) -> String {
    guard let date else { return "never" }
    return collectLogDateFormatter.string(from: date)
}

