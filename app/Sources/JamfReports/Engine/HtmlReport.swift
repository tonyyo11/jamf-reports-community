import CryptoKit
import Foundation

// MARK: - HtmlReport

/// T-13 integrity envelope: placeholder for the self-attesting SHA-256 hash.
/// Same shape as a real hex digest (64 chars) so HTML structure is identical
/// pre- and post-substitution. A verifier reproduces the digest by replacing
/// the embedded hash with this placeholder and re-hashing the bytes.
let HTMLReportSHA256Placeholder = String(repeating: "0", count: 64)

/// Generates a self-contained `.html` instance report from cached jamf-cli JSON snapshots.
///
/// The page runs top to bottom: a header of facts (profile, collection date, jamf-cli version,
/// Mac count, template, reporting week), six figures with their change over about a week,
/// a short "Needs attention" list, jamf-cli's fleet dashboard when one was collected, then
/// collapsed detail groups (each a `<details>` whose summary carries its headline numbers)
/// and a collapsed audit appendix. Which of those a report has comes from the template's
/// `htmlSections`; which groups start open comes from its `htmlOpenSections`. Lists show ten
/// rows and keep the rest behind "Show all". The layout is built in `HtmlReport+Layout`.
///
/// Full device lists are not in the HTML report at all: a report is forwarded, and the
/// workbook is where a Mac-by-Mac inventory lives.
///
/// Design adapted from @DevliegereM's JamfDash.
struct HtmlReport: Sendable {
    let config: ReportConfig
    let dataDir: URL
    /// GUI-generate-only AI executive narrative (F3). nil (the default) omits
    /// the `.aiNarrative` section entirely — headless callers never set it.
    var aiNarrative: String? = nil
    /// Where a `[warn]` line goes, beside the run's other log lines.
    var onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    /// The installed jamf-cli's version, for the header. Nil leaves it out; the version the
    /// newest daily summary recorded stands in.
    var jamfCLIVersion: String? = nil
    /// The template's display name, for the header.
    var templateName: String? = nil
    /// Sections whose detail group starts open. A group is open when it holds any of them.
    var openSections: Set<SectionID> = []
    /// Renders every `<details>` open and leaves out the expand and collapse buttons, for
    /// the PDF export, whose renderer runs no script.
    var expandAll: Bool = false

    // MARK: - HTML local config

    /// `html.track_history` and `html.history_file`, which the decoder does not model.
    private struct HtmlConfig: Sendable {
        var trackHistory: Bool = false
        var historyFile: String = ""
    }

    /// Read from the config.yaml beside `dataDir` through the engine's loader, so a value
    /// reads as the decoder would read it.
    private func htmlConfig() -> HtmlConfig {
        let configURL = dataDir.deletingLastPathComponent().appendingPathComponent("config.yaml")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8),
              let root = try? ConfigLoader.rawMapping(fromYAML: text)
        else { return HtmlConfig() }
        return HtmlConfig(
            trackHistory: ConfigLoader.rawValue(at: ["html", "track_history"], in: root)
                as? Bool ?? false,
            historyFile: ConfigLoader.rawValue(at: ["html", "history_file"], in: root)
                as? String ?? ""
        )
    }

    // MARK: - Public API

    /// Generate the HTML report and write it atomically to `outputURL`.
    ///
    /// - Parameters:
    ///   - outputURL: Destination file URL.
    ///   - profileName: Workspace profile slug for the header. Empty reads the config's
    ///     `jamf_cli.profile`.
    ///   - sections: The sections to render, as the active `ReportTemplate.htmlSections`
    ///     lists them. `nil` renders every section (`FullInstanceTemplate`).
    /// - Returns: The embedded SHA-256 source fingerprint.
    ///
    /// The digest is the hash of the placeholder-version bytes (before the real hash is
    /// substituted in). Verifiers reproduce it by replacing the embedded hash with 64 zeros
    /// and re-hashing the file.
    @discardableResult
    func generate(
        outputURL: URL,
        profileName: String = "",
        sections: [SectionID]? = nil
    ) async throws -> String {
        let html = buildTemplatedHTML(
            outputURL: outputURL,
            profileName: profileName,
            sections: sections ?? FullInstanceTemplate().htmlSections
        )
        let fm = FileManager.default
        try fm.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // T-13 integrity envelope: the rendered HTML carries
        // HTMLReportSHA256Placeholder in two sites (meta tag + footer).
        // Compute SHA-256 over the placeholder-version bytes, then substitute
        // the real digest for the placeholder so the embedded fingerprint
        // covers the final document. Verifiers reproduce the digest by
        // replacing the embedded hash with 64 zeros and re-hashing.
        let placeholderBytes = Data(html.utf8)
        let digestHex = SHA256.hash(data: placeholderBytes)
            .compactMap { String(format: "%02x", $0) }.joined()
        let finalHTML = html.replacingOccurrences(
            of: HTMLReportSHA256Placeholder, with: digestHex
        )
        try finalHTML.write(to: outputURL, atomically: true, encoding: .utf8)
        return digestHex
    }

    // MARK: - Section builders

    func buildSummaryTiles(
        total: Int,
        fileVaultPct: Double,
        sipPct: Double,
        firewallPct: Double,
        gatekeeperPct: Double,
        fleet: SecurityFleetCounts?
    ) -> String {
        let tiles: [(String, String, Double?, SecurityControl?)] = [
            ("Total Devices", "\(total)", nil, nil),
            ("FileVault", String(format: "%.1f%%", fileVaultPct), fileVaultPct, .fileVault),
            ("SIP", String(format: "%.1f%%", sipPct), sipPct, .sip),
            ("Firewall", String(format: "%.1f%%", firewallPct), firewallPct, .firewall),
            ("Gatekeeper", String(format: "%.1f%%", gatekeeperPct), gatekeeperPct, .gatekeeper),
        ]
        let tileHTML = tiles.map { label, value, pct, control -> String in
            let ignored = control.map { config.resolvedSecurityPolicy.level(for: $0) == .ignore }
                ?? false
            let statusClass = ignored ? ""
                : control.map { securityTileClass($0, pct: pct ?? 0, fleet: fleet) } ?? ""
            let label = ignored ? label + " (not counted)" : label
            let hardwareMacs = control == .fileVault ? fleet?.fileVaultOffHardwareEncrypted ?? 0 : 0
            let notes = [
                hardwareMacs > 0
                    ? "\(hardwareMacs) more hardware-encrypted, FileVault off" : nil,
                control.flatMap { fleet?.controls[$0]?.notReported }.flatMap {
                    $0 > 0 && !ignored ? "not reported: \($0)" : nil
                },
            ].compactMap { $0 }
            let note = notes.map {
                "\n  <div class=\"tile-label\">" + HtmlSectionFormatters.escapeHTML($0) + "</div>"
            }.joined()
            return """
            <div class="tile \(statusClass)">
              <div class="tile-value">\(HtmlSectionFormatters.escapeHTML(value))</div>
              <div class="tile-label">\(HtmlSectionFormatters.escapeHTML(label))</div>\(note)
            </div>
            """
        }.joined(separator: "\n")
        return """
        <section class="tiles-row">\n\(tileHTML)\n</section>
        """
    }

    /// A security tile's colour under the workspace's policy: the share of Macs not failing
    /// the control (the tile's own share without fleet counts), amber instead of green while
    /// some Macs only warn, none when no Mac is left to grade.
    private func securityTileClass(
        _ control: SecurityControl, pct: Double, fleet: SecurityFleetCounts?
    ) -> String {
        guard let fleet, fleet.controls[control] != nil, fleet.totalDevices > 0 else {
            return colorClass(pct)
        }
        guard let share = fleet.nonFailingPct(control) else { return "" }
        let statusClass = colorClass(share)
        let warnings = fleet.controls[control]?.warning ?? 0
        return statusClass == "ok" && warnings > 0 ? "warn" : statusClass
    }

    /// The Security and compliance group's controls: the four control tiles under the
    /// workspace's `security_policy`, then the sentence that names the gaps. Omitted without
    /// a security report.
    func buildSecurityControls(_ inputs: Inputs) -> HtmlBlock {
        guard !inputs.security.isEmpty || inputs.totalDevices > 0 else {
            return .omitted("no security report snapshot")
        }
        let secSummary = inputs.security.first { $0["section"] as? String == "summary" }
        let secData = secSummary?["data"] as? [String: Any] ?? [:]
        let total = inputs.totalDevices
        let tiles = buildSummaryTiles(
            total: total,
            fileVaultPct: computePct(asInt(secData["filevault_encrypted"]), total: total),
            sipPct: computePct(asInt(secData["sip_enabled"]), total: total),
            firewallPct: computePct(asInt(secData["firewall_enabled"]), total: total),
            gatekeeperPct: computePct(asInt(secData["gatekeeper_enabled"]), total: total),
            fleet: inputs.fleet)
        // Without fleet counts the sentence could only say it has none to word.
        let note = inputs.fleet.map { $0.totalDevices > 0 } == true
            ? "\n<p class=\"block-note\">"
                + HtmlSectionFormatters.escapeHTML(Self.securityGapSentence(inputs.fleet))
                + "</p>"
            : ""
        return .shown(HtmlSectionFormatters.block(
            id: "security-controls", title: "Security controls", body: tiles + note))
    }

    /// The compliance hero and the devices with the most failures. Omitted when the
    /// device-compliance rows carry no failure count (jamf-cli's do not), which neither can
    /// be drawn without.
    func buildComplianceBands(
        deviceCompliance: [[String: Any]], computers: [[String: Any]]
    ) -> HtmlBlock {
        let hero = buildComplianceTile(deviceCompliance: deviceCompliance)
        let top = buildTopNonCompliantTable(
            deviceCompliance: deviceCompliance, computersInventory: computers)
        let html = [hero, top].filter { !$0.isEmpty }.joined(separator: "\n")
        guard !html.isEmpty else {
            return .omitted("the device-compliance rows carry no failure count, so no Mac "
                + "can be called compliant or not")
        }
        return .shown("<div id=\"compliance-posture\">\n\(html)\n</div>")
    }

    // MARK: - Task 1: Compliance posture hero tile

    /// Renders a prominent compliance score tile from the device-compliance snapshot.
    /// Omitted gracefully when the snapshot is empty, and when its rows carry no failure
    /// count: jamf-cli's device-compliance rows (name, serial, managed, stale, days since
    /// contact) do not, and a missing count read as zero failures claimed 100%.
    func buildComplianceTile(deviceCompliance: [[String: Any]]) -> String {
        guard deviceCompliance.contains(where: {
            $0["failure_count"] != nil || $0["failures_count"] != nil
        }) else { return "" }
        let total = deviceCompliance.count
        let passing = deviceCompliance.filter { item -> Bool in
            let failCount = asInt(item["failure_count"]) ?? asInt(item["failures_count"]) ?? 0
            return failCount == 0
        }.count
        let failing = total - passing
        let pct = total > 0 ? Double(passing) / Double(total) * 100 : 0
        let colorCls = pct >= 95 ? "compliance-hero-green"
                       : pct >= 80 ? "compliance-hero-amber"
                       : "compliance-hero-red"
        let pctStr = String(format: "%.0f%%", pct)
        let label = "\(pctStr) Device Compliance &middot; \(failing) of \(total) device\(total == 1 ? "" : "s") have failures"
        return """
        <div class="compliance-hero \(colorCls)">
          <div class="compliance-hero-value">\(pctStr)</div>
          <div class="compliance-hero-label">\(label)</div>
        </div>
        """
    }

    // MARK: - Task 2: Top non-compliant devices table

    private struct NonCompliantDevice {
        let name: String
        let serial: String
        let daysSinceCheckin: Int
        let failureCount: Int
        let topFailure: String
    }

    /// Renders the top-10 non-compliant devices table sorted by failure count desc,
    /// then oldest check-in first.
    func buildTopNonCompliantTable(
        deviceCompliance: [[String: Any]],
        computersInventory: [[String: Any]]
    ) -> String {
        // Build a name → inventory lookup for enriching check-in dates and serials
        var inventoryByName: [String: [String: Any]] = [:]
        for inv in computersInventory {
            let name = inventoryName(inv)
            if !name.isEmpty { inventoryByName[name] = inv }
        }

        let failing = deviceCompliance.filter { item -> Bool in
            let failCount = asInt(item["failure_count"]) ?? asInt(item["failures_count"]) ?? 0
            return failCount > 0
        }

        guard !failing.isEmpty else { return "" }

        let devices: [NonCompliantDevice] = failing.map { item -> NonCompliantDevice in
            let name = item["name"] as? String ?? item["device_name"] as? String ?? ""
            let failureCount = asInt(item["failure_count"]) ?? asInt(item["failures_count"]) ?? 0

            // Serial: prefer compliance snapshot, fall back to inventory lookup (handles nested shape)
            let serial: String
            if let s = item["serial_number"] as? String, !s.isEmpty {
                serial = s
            } else if let s = item["serial"] as? String, !s.isEmpty {
                serial = s
            } else if let inv = inventoryByName[name] {
                serial = inventorySerial(inv)
            } else {
                serial = ""
            }

            // Days since last check-in
            let rawCheckin: String
            if let s = item["last_check_in"] as? String, !s.isEmpty {
                rawCheckin = s
            } else if let s = item["last_contact"] as? String, !s.isEmpty {
                rawCheckin = s
            } else if let inv = inventoryByName[name] {
                rawCheckin = inventoryLastContact(inv)
            } else {
                rawCheckin = ""
            }
            let daysSinceCheckin = daysAgo(from: rawCheckin)

            // Top failure: first entry in failures list
            let topFailure: String
            if let failures = item["failures"] as? [String], let first = failures.first {
                topFailure = first
            } else if let failures = item["failure_list"] as? String {
                topFailure = failures.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            } else {
                topFailure = item["top_failure"] as? String ?? ""
            }

            return NonCompliantDevice(
                name: name,
                serial: serial,
                daysSinceCheckin: daysSinceCheckin,
                failureCount: failureCount,
                topFailure: topFailure
            )
        }
        .sorted { lhs, rhs -> Bool in
            if lhs.failureCount != rhs.failureCount { return lhs.failureCount > rhs.failureCount }
            return lhs.daysSinceCheckin > rhs.daysSinceCheckin
        }

        let rows = devices.map { d -> [String] in
            let daysLabel = d.daysSinceCheckin >= 0 ? "\(d.daysSinceCheckin)" : "—"
            return [d.name, d.serial, daysLabel, "\(d.failureCount)", d.topFailure]
        }

        return HtmlSectionFormatters.block(
            id: "top-noncompliant",
            title: "Top non-compliant devices (\(devices.count))",
            body: HtmlSectionFormatters.renderCappedTable(
                headers: ["Device Name", "Serial", "Days Since Check-in", "Failure Count",
                          "Top Failure"],
                rows: rows, expanded: expandAll))
    }

    /// Parse an ISO-8601 or `yyyy-MM-dd` date string and return the number of days since today.
    /// Returns -1 when the string cannot be parsed.
    func daysAgo(from raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return -1 }
        let fmts = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in fmts {
            df.dateFormat = fmt
            if let date = df.date(from: trimmed) {
                let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? -1
                return max(days, 0)
            }
        }
        // ISO8601DateFormatter fallback
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) {
            return max(Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? -1, 0)
        }
        return -1
    }

    // MARK: - Charts

    /// OS version distribution as bars, most Macs first. "26.7" and "26.7.0" are one
    /// release (`OSVersionName`).
    func buildOSChart(osVersions: [[String: Any]]) -> HtmlBlock {
        guard !osVersions.isEmpty else {
            return .omitted("the security report has no OS version counts")
        }
        let osRows = OSVersionName.merged(osVersions.map {
            .init(version: $0["os_version"] as? String ?? "",
                  count: asInt($0["count"]) ?? 0, pct: 0)
        })
        let rows = osRows.enumerated()
            .sorted { ($0.element.count, $1.offset) > ($1.element.count, $0.offset) }
            .map { (label: $0.element.version, count: $0.element.count) }
        return .shown(HtmlSectionFormatters.block(
            id: "os-chart", title: "OS version distribution",
            body: HtmlSectionFormatters.renderBars(rows, expanded: expandAll)))
    }

    /// Compliance of the first ten patch titles as bars on a 0–100% track.
    func buildPatchChart(patchStatus: [[String: Any]]) -> HtmlBlock {
        guard !patchStatus.isEmpty else { return .omitted("no patch-status snapshot") }
        let rows = patchStatus.prefix(10).map { item -> (label: String, pct: Double) in
            let pct = (item["compliance_pct"] as? String ?? "0")
                .replacingOccurrences(of: "%", with: "")
            return (item["title"] as? String ?? "", Double(pct) ?? 0)
        }
        return .shown(HtmlSectionFormatters.block(
            id: "patch-chart", title: "Patch compliance (first 10 titles)",
            body: HtmlSectionFormatters.renderPercentBars(rows)))
    }

    // MARK: - Policies, profiles and apps

    /// Policy findings, errors first, with the policy counts as one line. Omitted when the
    /// snapshot has no findings: a healthy policy set is counted in the group's summary line,
    /// not listed.
    func buildPolicyHealthSection(_ policyStatus: [[String: Any]]) -> HtmlBlock {
        guard let first = policyStatus.first else {
            return .omitted("no policy-status snapshot")
        }
        let summary = first["summary"] as? [String: Any] ?? [:]
        let findings = first["config_findings"] as? [[String: Any]] ?? []
        let total = asInt(summary["total_policies"]) ?? 0
        let enabled = asInt(summary["enabled"]) ?? 0
        let disabled = asInt(summary["disabled"]) ?? 0
        guard !findings.isEmpty else {
            return .omitted("no policy findings; \(total) policies, \(enabled) enabled")
        }
        func rank(_ finding: [String: Any]) -> Int {
            switch (finding["severity"] as? String ?? "").lowercased() {
            case "error": return 0
            case "warning", "warn": return 1
            default: return 2
            }
        }
        let ordered = findings.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        let rows = ordered.map { f in
            [f["severity"] as? String ?? "", f["policy"] as? String ?? "",
             f["check"] as? String ?? "", f["detail"] as? String ?? ""]
        }
        let classes: [String?] = ordered.map {
            switch rank($0) {
            case 0: return "row-error"
            case 1: return "row-warn"
            default: return nil
            }
        }
        let note = "\(total) policies: \(enabled) enabled, \(disabled) disabled. "
            + "\(findings.count) finding\(findings.count == 1 ? "" : "s"), "
            + "\(asInt(summary["warnings"]) ?? 0) of them warnings."
        let body = "<p class=\"block-note\">\(HtmlSectionFormatters.escapeHTML(note))</p>"
            + HtmlSectionFormatters.renderCappedTable(
                headers: ["Severity", "Policy", "Check", "Detail"], rows: rows,
                rowClasses: classes, expanded: expandAll)
        return .shown(HtmlSectionFormatters.block(
            id: "policy-health", title: "Policy findings (\(findings.count))", body: body))
    }

    /// Configuration profiles that errored in the report window, from `profile-status`.
    /// `profileCount` is every profile the workspace has, so the line says how many of them
    /// are healthy without listing them.
    func buildProfileStatusSection(
        _ report: FailureReport?, profileCount: Int
    ) -> HtmlBlock {
        failureBlock(report, id: "profile-status", noun: "configuration profile",
                     kind: "profile-status", total: profileCount)
    }

    /// Apps that failed to install in the report window, from `app-status`.
    func buildAppStatusSection(_ report: FailureReport?) -> HtmlBlock {
        failureBlock(report, id: "app-status", noun: "app", kind: "app-status", total: 0)
    }

    /// The shared body of the profile and app failure lists: the items that errored, most
    /// errors first. Omitted when none did.
    private func failureBlock(
        _ report: FailureReport?, id: String, noun: String, kind: String, total: Int
    ) -> HtmlBlock {
        guard let report else { return .omitted("no \(kind) snapshot") }
        let window = report.days.map { "the last \($0) days" } ?? "the report window"
        guard !report.failures.isEmpty else {
            return .omitted("no \(noun) reported install errors in \(window)")
        }
        let ordered = report.failures.sorted {
            (asInt($0["errors"]) ?? 0) > (asInt($1["errors"]) ?? 0)
        }
        let rows = ordered.map { item in
            [item["name"] as? String ?? "", item["device_type"] as? String ?? "",
             "\(asInt(item["errors"]) ?? 0)", "\(asInt(item["devices"]) ?? 0)",
             item["top_error"] as? String ?? item["last_error"] as? String ?? ""]
        }
        let count = ordered.count
        let healthy = total > count ? " (\(total - count) of \(total) had none)" : ""
        let note = "\(count) \(noun)\(count == 1 ? "" : "s") reported install errors in "
            + "\(window)\(healthy): \(report.totalErrors) errors on \(report.uniqueDevices) "
            + "device\(report.uniqueDevices == 1 ? "" : "s")."
        let body = "<p class=\"block-note\">\(HtmlSectionFormatters.escapeHTML(note))</p>"
            + HtmlSectionFormatters.renderCappedTable(
                headers: ["Name", "Device type", "Errors", "Devices", "Top error"],
                rows: rows, expanded: expandAll)
        let title = noun == "app" ? "Apps failing to install (\(count))"
            : "Configuration profiles failing (\(count))"
        return .shown(HtmlSectionFormatters.block(id: id, title: title, body: body))
    }

    // MARK: - Catalog overview

    /// Object counts for the catalog, as cards. Omitted when no catalog snapshot exists.
    func buildCatalogSection(counts: [(label: String, count: Int)]) -> HtmlBlock {
        guard !counts.isEmpty else { return .omitted("no catalog snapshots") }
        let cards = counts.map {
            HtmlSectionFormatters.SectionCard(name: $0.label, value: "\($0.count)")
        }
        return .shown(HtmlSectionFormatters.block(
            id: "catalog-overview", title: "Catalog overview",
            body: HtmlSectionFormatters.renderCardGrid(cards: cards)))
    }

    // MARK: - History tracking + inline SVG trend

    /// Append a metric snapshot to the history file (when `html.track_history: true`)
    /// and render an inline SVG trend chart from recent history entries. `historyURL` is the
    /// file a caller already resolved, so a refused path is warned about once.
    func buildHistorySection(
        security: [[String: Any]],
        outputURL: URL,
        historyURL: URL? = nil
    ) -> String {
        let cfg = htmlConfig()
        guard cfg.trackHistory else { return "" }

        let histPath = historyURL ?? resolvedHistoryPath(cfg.historyFile, outputURL: outputURL)
        appendHistoryEntry(security: security, path: histPath)

        let history = loadHistory(path: histPath)
        guard history.count >= 2 else {
            return HtmlSectionFormatters.block(
                id: "os-adoption-trend", title: "OS adoption trend",
                body: "<p class=\"empty-note\">Not enough history yet (\(history.count) "
                    + "snapshot(s)). Run again after collecting more data.</p>")
        }
        return HtmlSectionFormatters.block(
            id: "os-adoption-trend", title: "OS adoption trend",
            body: renderHistorySVG(history: history))
    }

    // MARK: History helpers

    /// `html.history_file`, which the report writes to, under the rules for every path
    /// config.yaml names (`WorkspacePaths.resolve`): relative to the workspace and inside it,
    /// an absolute path outside it only with `output.allow_absolute_paths`, never a system or
    /// credentials folder. Blank or refused, it is `html_history.json` beside the report; a
    /// refused path is one `[warn]` line.
    func resolvedHistoryPath(_ configured: String, outputURL: URL) -> URL {
        let fallback = outputURL.deletingLastPathComponent()
            .appendingPathComponent("html_history.json")
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return fallback }
        let workspace = dataDir.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        do {
            let resolved = try WorkspacePaths.resolve(
                rawValue: trimmed, fallback: fallback.path, workspace: workspace)
            return URL(fileURLWithPath: resolved.path, isDirectory: false)
        } catch {
            let msg = "[warn] html.history_file \"\(ConfigSchema.displayText(trimmed))\" is not "
                + "used: \(WorkspacePaths.refusal(of: error)). Writing the history to "
                + "\(fallback.lastPathComponent) beside the report instead."
            AppLogger.report.warning("\(msg, privacy: .private)")
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return fallback
        }
    }

    struct HistoryEntry: Sendable {
        let timestamp: String
        let versions: [(version: String, count: Int)]
    }

    private func appendHistoryEntry(security: [[String: Any]], path: URL) {
        // Build the versions snapshot from the security report.
        var versions: [(String, Int)] = []
        for item in security {
            guard item["section"] as? String == "os_version" else { continue }
            let ver = item["os_version"] as? String ?? "Unknown"
            let count = asInt(item["count"]) ?? 0
            versions.append((ver, count))
        }

        let dateFormatter = ISO8601DateFormatter()
        let ts = dateFormatter.string(from: Date())
        let entry: [String: Any] = [
            "ts": ts,
            "versions": versions.map { ["v": $0.0, "c": $0.1] },
        ]

        var history: [[String: Any]] = []
        if let existing = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: existing) as? [[String: Any]] {
            history = parsed
        }
        history.append(entry)
        // Trim to last 365 entries
        if history.count > 365 { history = Array(history.suffix(365)) }

        if let data = try? JSONSerialization.data(withJSONObject: history, options: [.prettyPrinted]) {
            try? data.write(to: path, options: .atomic)
        }
    }

    private func loadHistory(path: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: path),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return raw.compactMap { item -> HistoryEntry? in
            guard let ts = item["ts"] as? String,
                  let verList = item["versions"] as? [[String: Any]]
            else { return nil }
            let versions = verList.compactMap { v -> (String, Int)? in
                guard let ver = v["v"] as? String, let count = asInt(v["c"]) else { return nil }
                return (ver, count)
            }
            return HistoryEntry(timestamp: ts, versions: versions)
        }
    }

    /// Render a small inline SVG line chart from history entries.
    /// Shows total device count over time. No external dependencies.
    func renderHistorySVG(history: [HistoryEntry]) -> String {
        guard history.count >= 2 else { return "<p class=\"empty-note\">Not enough data.</p>" }

        let totals: [Int] = history.map { entry in
            entry.versions.reduce(0) { $0 + $1.count }
        }
        let labels: [String] = history.map { entry in
            String(entry.timestamp.prefix(10))
        }

        let svgWidth: Double = 600
        let svgHeight: Double = 160
        let leftPad: Double = 50
        let topPad: Double = 16
        let rightPad: Double = 16
        let bottomPad: Double = 30
        let plotW = svgWidth - leftPad - rightPad
        let plotH = svgHeight - topPad - bottomPad

        let maxVal = Double(totals.max() ?? 1)
        let minVal = Double(totals.min() ?? 0)
        let yRange = max(maxVal - minVal, 1)

        func xPos(_ i: Int) -> Double {
            leftPad + (Double(i) / Double(totals.count - 1)) * plotW
        }
        func yPos(_ v: Int) -> Double {
            topPad + plotH - ((Double(v) - minVal) / yRange) * plotH
        }

        let pointPairs = totals.indices.map { i in (xPos(i), yPos(totals[i])) }
        let polylinePoints = pointPairs
            .map { x, y in "\(String(format: "%.1f", x)),\(String(format: "%.1f", y))" }
            .joined(separator: " ")

        // Y-axis grid lines (4 lines)
        var gridLines = ""
        for idx in 0...4 {
            let yFrac = Double(idx) / 4.0
            let yVal = maxVal - yFrac * (maxVal - minVal)
            let yCoord = topPad + plotH * yFrac
            let label = "\(Int(yVal.rounded()))"
            gridLines += """
            <line x1="\(String(format: "%.1f", leftPad))" y1="\(String(format: "%.1f", yCoord))" \
            x2="\(String(format: "%.1f", svgWidth - rightPad))" y2="\(String(format: "%.1f", yCoord))" \
            stroke="var(--border)" stroke-width="1"/>
            <text x="\(String(format: "%.1f", leftPad - 4))" y="\(String(format: "%.1f", yCoord + 4))" \
            text-anchor="end" style="font-size:9px;fill:var(--subtext)">\(HtmlSectionFormatters.escapeHTML(label))</text>
            """
        }

        // X-axis labels (show at most 6)
        var xLabels = ""
        let labelStep = max(1, totals.count / 6)
        for i in totals.indices {
            guard i % labelStep == 0 || i == totals.count - 1 else { continue }
            let xCoord = xPos(i)
            xLabels += """
            <text x="\(String(format: "%.1f", xCoord))" y="\(String(format: "%.1f", svgHeight - 4))" \
            text-anchor="middle" style="font-size:9px;fill:var(--subtext)">\(HtmlSectionFormatters.escapeHTML(labels[i]))</text>
            """
        }

        // Dots on each data point
        let dots = pointPairs.map { x, y in
            """
            <circle cx="\(String(format: "%.1f", x))" cy="\(String(format: "%.1f", y))" \
            r="3" fill="var(--accent)"/>
            """
        }.joined()

        return """
        <svg viewBox="0 0 \(Int(svgWidth)) \(Int(svgHeight))" class="history-svg" \
        role="img" aria-label="OS adoption trend">
          \(gridLines)
          <polyline fill="none" stroke="var(--accent)" stroke-width="2" \
          stroke-linejoin="round" points="\(polylinePoints)"/>
          \(dots)
          \(xLabels)
        </svg>
        """
    }

    // MARK: - Data helpers

    /// Load the newest JSON file for any of the given kind names from `dataDir`.
    /// Returns an empty array if no file is found or it cannot be parsed.
    func loadJSONList(kinds: [String]) -> [[String: Any]] {
        for kind in kinds {
            if let result = loadJSON(kind: kind) as? [[String: Any]], !result.isEmpty {
                return result
            }
        }
        return []
    }

    private func loadJSON(kind: String) -> Any? {
        guard let data = loadJSONData(kind: kind) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    func loadJSONData(kind: String) -> Data? {
        newestSnapshotURL(kind: kind).flatMap { try? Data(contentsOf: $0) }
    }

    /// The newest snapshot file for `kind`, from its subdirectory and the flat
    /// `<kind>_*.json` pattern under `dataDir`. The shared picker decides which is newest, so
    /// an HTML report and the workbook generated from the same workspace never read different
    /// days.
    func newestSnapshotURL(kind: String) -> URL? {
        let fm = FileManager.default
        let subdir = dataDir.appendingPathComponent(kind, isDirectory: true)
        var candidates: [URL] = []
        if fm.fileExists(atPath: subdir.path),
           let files = try? fm.contentsOfDirectory(
            at: subdir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
           ) {
            candidates.append(contentsOf: files.filter { $0.pathExtension == "json" })
        }
        if let files = try? fm.contentsOfDirectory(
            at: dataDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: files.filter {
                $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(kind + "_")
            })
        }
        return FileManager.newestSnapshot(among: candidates)
    }

    /// The `security` snapshot's counts under the workspace's policy: the same fleet the
    /// workbook and summary.json grade by. Nil without a decodable summary section.
    func securityFleet() -> SecurityFleetCounts? {
        guard let data = loadJSONData(kind: "security"),
              let items = try? JSONDecoder().decode([SecurityReportItem].self, from: data)
        else { return nil }
        let policy = config.resolvedSecurityPolicy
        return SecurityFleetCounts.build(
            items: items, hardware: HardwareEncryption.index(dataDir: dataDir, for: policy),
            policy: policy)
    }

    func overviewDeviceCount(_ overview: [[String: Any]]) -> Int {
        for item in overview {
            if let resource = item["resource"] as? String,
               resource.lowercased().contains("computer"),
               resource.lowercased().contains("total") {
                return asInt(item["value"]) ?? 0
            }
        }
        return 0
    }

    func computePct(_ count: Int?, total: Int) -> Double {
        guard let count, total > 0 else { return 0 }
        return Double(count) / Double(total) * 100
    }

    private func colorClass(_ pct: Double) -> String {
        if pct >= 95 { return "ok" }
        if pct >= 80 { return "warn" }
        return "bad"
    }

    func asInt(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let d as Double: return Int(exactly: d.rounded())
        case let s as String: return Int(s)
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }

    func formattedNow() -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: Date())
    }

    // MARK: - Inventory field accessors

    /// Extract device name from a jamf-cli `computers list` record.
    ///
    /// Handles both the nested `{general: {name: …}}` shape produced by
    /// `jamf-cli pro computers list --output json` and the flat `{name: …}` shape
    /// that older snapshots or other sources may emit.
    func inventoryName(_ item: [String: Any]) -> String {
        if let general = item["general"] as? [String: Any],
           let name = general["name"] as? String, !name.isEmpty {
            return name
        }
        return item["name"] as? String ?? item["device_name"] as? String ?? ""
    }

    /// Extract serial number from a `computers list` record.
    func inventorySerial(_ item: [String: Any]) -> String {
        if let hardware = item["hardware"] as? [String: Any],
           let serial = hardware["serialNumber"] as? String, !serial.isEmpty {
            return serial
        }
        return item["serial_number"] as? String ?? item["serial"] as? String ?? ""
    }

    /// Extract last contact/check-in time string from a `computers list` record.
    /// v4 renamed `lastContactTime` to `lastCheckIn`; v4's `lastContact` is a different field.
    func inventoryLastContact(_ item: [String: Any]) -> String {
        if let general = item["general"] as? [String: Any] {
            if let ts = general["lastCheckIn"] as? String, !ts.isEmpty { return ts }
            if let ts = general["lastContactTime"] as? String, !ts.isEmpty { return ts }
            if let ts = general["reportDate"] as? String, !ts.isEmpty { return ts }
        }
        return item["last_check_in"] as? String ?? item["last_contact"] as? String ?? ""
    }

    /// Extract department name from a `computers list` record.
    func inventoryDepartment(_ item: [String: Any]) -> String {
        if let ual = item["userAndLocation"] as? [String: Any] {
            if let dept = ual["department"] as? String, !dept.isEmpty { return dept }
            if let dept = ual["departmentName"] as? String, !dept.isEmpty { return dept }
        }
        if let dept = item["department"] as? String, !dept.isEmpty { return dept }
        if let dept = item["departmentName"] as? String, !dept.isEmpty { return dept }
        return "—"
    }

    /// Extract building name from a `computers list` record.
    func inventoryBuilding(_ item: [String: Any]) -> String {
        if let ual = item["userAndLocation"] as? [String: Any] {
            if let bld = ual["building"] as? String, !bld.isEmpty { return bld }
            if let bld = ual["buildingName"] as? String, !bld.isEmpty { return bld }
        }
        if let bld = item["building"] as? String, !bld.isEmpty { return bld }
        if let bld = item["buildingName"] as? String, !bld.isEmpty { return bld }
        return "—"
    }

    /// Extract primary username from a `computers list` record.
    func inventoryUsername(_ item: [String: Any]) -> String {
        if let ual = item["userAndLocation"] as? [String: Any] {
            if let user = ual["username"] as? String, !user.isEmpty { return user }
            if let user = ual["email"] as? String, !user.isEmpty { return user }
        }
        if let user = item["username"] as? String, !user.isEmpty { return user }
        if let user = item["last_logged_in_user"] as? String, !user.isEmpty { return user }
        return "—"
    }

    /// Extract purchase date string from a `computers list` record.
    func inventoryPurchaseDate(_ item: [String: Any]) -> String {
        if let purchasing = item["purchasing"] as? [String: Any] {
            if let d = purchasing["purchaseDate"] as? String, !d.isEmpty { return d }
            if let d = purchasing["purchase_date"] as? String, !d.isEmpty { return d }
        }
        return item["purchase_date"] as? String ?? item["purchaseDate"] as? String ?? ""
    }

    /// Fill each record's department and building name from its `departmentId` and
    /// `buildingId`: `computers list` carries only the ids, the names live in the
    /// `departments` and `buildings` snapshots (`{id, name}`). A record that already names
    /// its department or building keeps it, and an id no snapshot lists stays unassigned.
    func resolvingLocationNames(
        _ inventory: [[String: Any]],
        buildings: [[String: Any]],
        departments: [[String: Any]]
    ) -> [[String: Any]] {
        func names(_ rows: [[String: Any]]) -> [String: String] {
            rows.reduce(into: [:]) { acc, row in
                guard let id = row["id"].map({ "\($0)" }),
                      let name = row["name"] as? String, !name.isEmpty else { return }
                acc[id] = name
            }
        }
        let buildingNames = names(buildings)
        let departmentNames = names(departments)
        guard !buildingNames.isEmpty || !departmentNames.isEmpty else { return inventory }
        return inventory.map { item in
            guard var location = item["userAndLocation"] as? [String: Any] else { return item }
            func fill(_ key: String, id idKey: String, from lookup: [String: String]) {
                let named = (location[key] as? String) ?? (location[key + "Name"] as? String)
                guard (named ?? "").isEmpty, let id = location[idKey].map({ "\($0)" }),
                      let name = lookup[id] else { return }
                location[key] = name
            }
            fill("department", id: "departmentId", from: departmentNames)
            fill("building", id: "buildingId", from: buildingNames)
            var resolved = item
            resolved["userAndLocation"] = location
            return resolved
        }
    }
}
