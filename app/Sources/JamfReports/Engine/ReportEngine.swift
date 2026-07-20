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
        if config.charts?.isEnabled == true,
           let summariesDir = resolvedSummariesDir(profile: profile, onLine: onLine) {
            renderChartSheet(
                workbook: workbook,
                summariesDir: summariesDir,
                pngOutputDir: outputURL.deletingLastPathComponent(),
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
    func emitSummaryJSON(
        summariesDir: URL,
        provenance: Provenance? = nil,
        liveKinds: Set<String>? = nil,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        } catch {
            let msg = "[warn] Could not create summaries dir: \(error)"
            AppLogger.collect.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return
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
                writeSummaryFile(fresh, to: summaryFile, onLine: onLine)
            } else {
                let msg = "[info] summary_\(today).json already exists — leaving existing file in place"
                AppLogger.collect.info("\(msg, privacy: .public)")
                onLine?(.init(timestamp: Date(), level: .info, text: msg))
            }
            return
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
            return
        }

        writeSummaryFile(summary, to: summaryFile, onLine: onLine)
    }

    // MARK: - Summary upgrade helpers

    /// Returns true when `fresh` is strictly better than `existing` — meaning it
    /// should overwrite a same-day summary that would otherwise be kept.
    ///
    /// "Better" means at least one of:
    /// - `existing.complianceIsProxy == true` AND `fresh.complianceIsProxy == false`
    ///   (real mSCP data is now available where before only the 4-control proxy was), OR
    /// - `existing` has no `mscpBands` (or empty) AND `fresh` has non-empty `mscpBands`.
    ///
    /// Never returns true when the fresh run would downgrade (real→proxy, or bands dropped),
    /// preserving the PR-18 protection against partial-collect clobbering a good summary.
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
        return false
    }

    /// Encode and atomically write `summary` to `url`, logging the outcome to `onLine`.
    private func writeSummaryFile(
        _ summary: DailySummary,
        to url: URL,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(summary)
            try data.write(to: url, options: .atomic)
            let msg = "[ok] wrote \(url.lastPathComponent) — trend chart and StaleDataBanner will reflect this run"
            AppLogger.collect.info("\(msg, privacy: .public)")
            onLine?(.init(timestamp: Date(), level: .ok, text: msg))
        } catch {
            let msg = "[warn] could not write summary JSON: \(error.localizedDescription)"
            AppLogger.collect.warning("\(msg, privacy: .private)")
            print(msg)
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
        }
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
            mobileDeviceCount: mobileDeviceCount
        )
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
    static let expensivePerDeviceKinds: Set<String> = [
        "ea-results",
        "patch-device-failures",
        "update-device-failures",
        "device-compliance"
    ]

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
    /// calls were attempted but ALL failed (any non-zero exit code) with zero successes
    /// and no HTTP 401 signals.
    ///
    /// This catches the case where the server is unreachable, jamf-cli is broken, or
    /// every call exits non-zero for reasons unrelated to auth (exit 1 network error,
    /// exit 4 not-found, exit 5 permission denied, exit 6 rate-limited). Without this
    /// guard such a run would fall through to SOFA + `emitSummaryJSON`, writing a
    /// today-stamped summary built entirely from stale cache and marking the run as
    /// success. Auth-dead (`isCollectAuthDead`) is checked first at the call site, so
    /// this function is only reached when no 401 was present.
    ///
    /// Returns false for an empty outcome set (no live calls were attempted) and for any
    /// outcome set that includes at least one `exit 0` or `exit 7` (partial failure) success.
    static func isCollectDead(_ outcomes: [CollectOutcome]) -> Bool {
        guard !outcomes.isEmpty else { return false }
        return !outcomes.contains {
            $0.exitCode == 0 || $0.exitCode == CLIBridge.exitCodePartialFailure
        }
    }

    static func collect(
        profile: String,
        workspacePaths: WorkspacePaths.Type,
        tiers: Set<CollectionTier> = Set(CollectionTier.allCases),
        skipExpensive: Bool = false,
        force: Bool = false,
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

        guard let bin = ExecutableLocator.locate("jamf-cli") else {
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
            // v1.23.0+ only — an older binary prints Cobra's parent-help text and exits 0
            // for this unknown subcommand; the isJSONSnapshot guard below drops that output
            // instead of poisoning the cache (see the classic-macos-profiles rename comment).
            (["-p", profile, "pro", "report", "duplicate-serials", "--output", "json"],
             "duplicate-serials"),
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

        let bridge = CLIBridge()
        var outcomes: [CollectOutcome] = []
        // Tracks kinds where saveSnapshot actually wrote a file this run.
        // Used to build liveKinds for R4 provenance — exit-0 non-JSON output
        // (Cobra help) passes the exitCode==0 filter but must NOT be "live".
        var savedKinds: Set<String> = []
        for (args, kind) in plannedCommands {
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
                onLine(.init(
                    timestamp: Date(), level: .info,
                    text: "[skip] \(kind): not due (last: \(lastRunLabel(lastRun)), cadence: \(cadence.label))"
                ))
                continue
            }

            AppLogger.collect.debug("collect kind=\(kind, privacy: .public)")
            onLine(.init(
                timestamp: Date(), level: .info,
                text: "[info] collecting \(kind) for \(profile)"
            ))
            let captureResult: (Int32, Data)?
            do {
                // --no-hints suppresses interactive usage tips; --no-version-check
                // suppresses the "new version available" banner that jamf-cli 1.18+
                // emits on stderr. Both keep Runs-screen output signal-to-noise clean
                // during automated collects. Only appended when the binary is >= 1.18.0
                // (see `supportsQuietFlags` gate above the loop).
                let invokeArgs = supportsQuietFlags
                    ? args + ["--no-hints", "--no-version-check"]
                    : args
                captureResult = try await bridge.runAndCapture(
                    executable: bin, arguments: invokeArgs,
                    environment: CLIBridge.environmentForJamfCLI(),
                    onLine: onLine
                )
            } catch {
                onLine(.init(timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): launch failed — \(error.localizedDescription)"))
                captureResult = nil
            }
            guard let (exitCode, data) = captureResult else { continue }
            // Record every command with a known exit code for the auth-dead verdict
            // after the loop. Launch failures (nil captureResult, already warned and
            // continued) carry no exit code and are not auth signals, so they are
            // intentionally excluded.
            outcomes.append(CollectOutcome(kind: kind, exitCode: exitCode))
            let isPartialFailure = exitCode == CLIBridge.exitCodePartialFailure
            if (exitCode == 0 || isPartialFailure), !data.isEmpty {
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
                guard isJSONSnapshot(data) else {
                    onLine(.init(timestamp: Date(), level: .warn,
                        text: "[warn] \(kind): output is not JSON (renamed/unsupported "
                            + "command on this jamf-cli?) — snapshot not saved"))
                    continue
                }
                try saveSnapshot(
                    data: data, kind: kind, dataDir: dataDir,
                    recordManifest: recordManifest, onLine: onLine
                )
                savedKinds.insert(kind)
                // T-8: record success so the cadence boundary advances.
                // Use try? rather than try — a state-write failure should
                // not undo the snapshot we already wrote. The worst case
                // is a redundant fetch next cycle, which is recoverable.
                try? stateStore?.recordRun(report: kind, at: collectStart)
                if !isPartialFailure {
                    onLine(.init(timestamp: Date(), level: .ok,
                                 text: "[ok] \(kind): \(data.count) bytes"))
                }
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

        // Auth-dead guard: every live jamf-cli call failed and at least one returned
        // 401 (exit 3) → the profile's credentials are expired/revoked. Checked FIRST
        // so a total outage with 401s surfaces as an auth error (actionable: re-auth)
        // rather than as a generic dead-collect. Surface as a throw so the scheduled-run
        // catch records exit 1 (not a silent success serving stale cache), and abort
        // BEFORE SOFA/summary so no degraded snapshot is written. A single 401 among
        // successes does not reach here — it took the cache-fallback branch above.
        // Skipped when use_cached_data=false (that path already threw collectFailed on
        // the first failure).
        if Self.isCollectAuthDead(outcomes) {
            let authFailures = outcomes.filter {
                $0.exitCode == CLIBridge.exitCodeUnauthorized
            }.count
            let msg = "[error] auth failed for '\(profile)': \(authFailures) live call(s) " +
                "returned 401 and none succeeded — re-authenticate " +
                "(jamf-cli -p \(profile) pro auth token). No snapshot written."
            AppLogger.collect.error("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .fail, text: msg))
            throw ReportEngineError.authExpired(profile: profile, failedCount: authFailures)
        }

        // Total-outage guard: all live calls failed (any non-zero exit), no 401 signals
        // and no successes → server unreachable or jamf-cli broken. Without this guard
        // the run falls through to SOFA + emitSummaryJSON and records Success while
        // serving entirely stale cache. Abort BEFORE SOFA/summary for the same reason
        // as auth-dead: no degraded snapshot should be promoted as fresh data.
        if Self.isCollectDead(outcomes) {
            let failedCount = outcomes.count
            let msg = "[error] all \(failedCount) live jamf-cli call(s) failed for '\(profile)' " +
                "(server unreachable or jamf-cli broken) — no snapshot written."
            AppLogger.collect.error("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .fail, text: msg))
            throw ReportEngineError.collectDead(profile: profile, failedCount: failedCount)
        }

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
            engine.emitSummaryJSON(
                summariesDir: summariesDir, provenance: prov,
                liveKinds: liveKinds, onLine: onLine
            )
        }
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
            guard !titleId.isEmpty else { continue }
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
    static func isJSONSnapshot(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
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
        try data.write(to: file)
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
        let newest = files
            .filter { $0.pathExtension == "json" }
            // Exclude the sibling manifest.json (2.6 SnapshotManifest.record
            // writer). It is integrity metadata, always newest-by-mtime after a
            // collect, and would otherwise be returned as "the snapshot" and fail
            // the caller's decode.
            .filter { $0.lastPathComponent.lowercased() != SnapshotManifest.fileName }
            .max { snapshotDate($0) < snapshotDate($1) }
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

