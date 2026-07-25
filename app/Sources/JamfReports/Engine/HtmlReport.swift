import CryptoKit
import Foundation

// MARK: - HtmlReport

/// T-13 integrity envelope: placeholder for the self-attesting SHA-256 hash.
/// Same shape as a real hex digest (64 chars) so HTML structure is identical
/// pre- and post-substitution. A verifier reproduces the digest by replacing
/// the embedded hash with this placeholder and re-hashing the bytes.
let HTMLReportSHA256Placeholder = String(repeating: "0", count: 64)

/// Swift port of the Python `HtmlReport` class.
///
/// Generates a self-contained `.html` instance report from cached jamf-cli JSON
/// snapshots. The report includes:
/// - Fleet summary tiles (total devices, filevault %, SIP %, firewall %)
/// - Chart.js charts (OS version donut, patch compliance bar) embedded via CDN
/// - Policy health table from `pro report policy-status`
/// - Profile status table from cached profiles JSON
/// - Policies, smart groups, scripts, packages, categories count cards + tables
/// - ADE/device enrollment count tile
/// - Sites, buildings, departments count tiles
/// - Mobile iOS profiles count tile
/// - Org info section (sites, buildings, departments)
/// - Optional history tracking: appends a metric snapshot to a JSON file and
///   renders an inline SVG trend chart
/// - Dark/light mode toggle
///
/// Design adapted from @DevliegereM's JamfDash.
struct HtmlReport: Sendable {
    let config: ReportConfig
    let dataDir: URL
    /// GUI-generate-only AI executive narrative (F3). nil (the default) omits
    /// the `.aiNarrative` section entirely — headless callers never set it.
    var aiNarrative: String? = nil

    // MARK: - HTML local config

    /// Local representation of `html:` config block, read from YAML if present.
    /// Avoids touching ConfigDecoder (another agent's territory).
    private struct HtmlConfig: Sendable {
        var trackHistory: Bool = false
        var historyFile: String = ""
    }

    private func htmlConfig() -> HtmlConfig {
        // Read the raw YAML map via YAMLCodec if it exposed a general accessor,
        // but since it doesn't, we fall back to loading the raw file ourselves.
        // This keeps the footprint minimal and avoids touching ConfigDecoder.
        guard let configURL = dataDir.deletingLastPathComponent()
                .appendingPathComponent("config.yaml") as URL?,
              FileManager.default.fileExists(atPath: configURL.path),
              let text = try? String(contentsOf: configURL, encoding: .utf8)
        else { return HtmlConfig() }

        var result = HtmlConfig()
        var inHtmlBlock = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            // Detect the `html:` top-level block
            if line.hasPrefix("html:") {
                inHtmlBlock = true
                continue
            }
            // Leave block when we hit a new top-level key
            if inHtmlBlock && !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.isEmpty {
                inHtmlBlock = false
            }
            guard inHtmlBlock else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("track_history:") {
                let val = trimmed.components(separatedBy: ":").dropFirst()
                    .joined(separator: ":").trimmingCharacters(in: .whitespaces)
                result.trackHistory = val == "true"
            } else if trimmed.hasPrefix("history_file:") {
                let val = trimmed.components(separatedBy: ":").dropFirst()
                    .joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                result.historyFile = val
            }
        }
        return result
    }

    // MARK: - Public API

    /// Generate the HTML report and write it atomically to `outputURL`.
    ///
    /// - Parameters:
    ///   - outputURL: Destination file URL.
    ///   - profileName: Active workspace profile slug (shown in provenance footer).
    ///   - sections: Ordered list of section IDs to include. When `nil`, renders the
    ///     full legacy layout (all sections). When provided, renders only the listed
    ///     sections in that order, matching the active `ReportTemplate.htmlSections`.
    /// Generate the HTML report and return the embedded SHA-256 source fingerprint.
    ///
    /// The returned digest is the hash of the placeholder-version bytes (before
    /// the real hash is substituted in). Verifiers reproduce this digest by
    /// replacing the embedded hash with 64 zeros and re-hashing the file.
    @discardableResult
    func generate(
        outputURL: URL,
        profileName: String = "",
        sections: [SectionID]? = nil
    ) async throws -> String {
        let html: String
        if let sections {
            html = try await buildTemplatedHTML(
                outputURL: outputURL,
                profileName: profileName,
                sections: sections
            )
        } else {
            html = try await buildHTML(outputURL: outputURL, profileName: profileName)
        }
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

    // MARK: - Template-aware HTML construction

    /// Build an HTML document rendering only the sections in `sections`, in that order.
    ///
    /// Each `SectionID` maps to a rendered fragment from `buildSectionMap`. Unknown
    /// section IDs (i.e., not yet implemented) emit an HTML comment placeholder so
    /// the document remains valid and the gap is visible to reviewers.
    private func buildTemplatedHTML(
        outputURL: URL,
        profileName: String,
        sections: [SectionID]
    ) async throws -> String {
        let sectionMap = try await buildSectionMap(outputURL: outputURL, profileName: profileName)

        // F3: with no narrative the AI section is dropped BEFORE rendering (no
        // placeholder comment) so nil keeps the output byte-identical to today.
        let effectiveSections = (aiNarrative?.isEmpty ?? true)
            ? sections.filter { $0 != .aiNarrative }
            : sections

        // De-duplicate rendered fragments: when two SectionIDs map to the same HTML
        // block (e.g. .kpiTiles/.fleetSummary/.securityTiles all share tilesHTML, and
        // .osAdoptionChart/.patchBar share chartsHTML), emitting the same block twice
        // would produce duplicate canvas IDs that break Chart.js. Track which fragment
        // strings have already been emitted; identical aliases render as a comment.
        var emittedFragments: Set<String> = []
        let bodyParts = effectiveSections.map { id -> String in
            if let fragment = sectionMap[id] {
                let fragmentKey = fragment
                if emittedFragments.contains(fragmentKey) {
                    return "<!-- section: \(id.rawValue) aliased to earlier section -->"
                }
                emittedFragments.insert(fragmentKey)
                return fragment
            }
            // Unimplemented section: emit comment, not silence.
            return "<!-- section: \(id.rawValue) unimplemented -->"
        }
        let mainBody = bodyParts.joined(separator: "\n")

        let overview = loadJSON(kind: "overview") as? [[String: Any]] ?? []
        let orgName = config.branding?.resolvedOrgName ?? "Jamf Reports"
        let accentColor = HtmlReport.sanitizedHexColor(
            config.branding?.resolvedAccentColor ?? "#2D5EA2",
            fallback: "#2D5EA2"
        )
        let ts = formattedNow()
        let titleEscaped = HtmlSectionFormatters.escapeHTML(orgName)
        let css = buildCSS(accentColor: accentColor)
        let provenanceHTML = buildProvenanceBlock(overview: overview, profileName: profileName)
        let scriptHTML = buildScript()

        let verifyFilename = HtmlSectionFormatters.escapeHTML(outputURL.lastPathComponent)
        let placeholder = HTMLReportSHA256Placeholder
        return """
        <!DOCTYPE html>
        <html lang="en" data-theme="light">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta name="report-sha256" content="\(placeholder)">
        <title>\(titleEscaped) — Jamf Instance Report</title>
        <script>\(ChartJSBundle.inlineScript)</script>
        \(css)
        </head>
        <body>
        <a class="skip-link" href="#main-content">Skip to main content</a>
        <header>
          <div class="header-content">
            <div>
              <h1>\(titleEscaped)</h1>
              <p class="subtitle">Jamf Instance Report · \(ts)</p>
            </div>
            <button class="theme-toggle" onclick="toggleTheme()" aria-label="Toggle theme" aria-pressed="false">&#9728; / &#9790;</button>
          </div>
        </header>
        <main id="main-content">
        \(mainBody)
        </main>
        \(provenanceHTML)
        <footer>
          <p>Generated by Jamf Reports &middot; <a href="https://github.com/tonyyo11/jamf-reports-community">tonyyo11/jamf-reports-community</a></p>
          <p class="verify-footer" style="margin-top:8px;font-size:11px;opacity:0.7">
            Source fingerprint: <code>\(placeholder)</code>
            &middot; verify with <code>shasum -a 256 \(verifyFilename)</code>
            (see <code>report-sha256</code> meta tag; replace the hash field with 64 zeros to reproduce)
          </p>
        </footer>
        \(scriptHTML)
        </body>
        </html>
        """
    }

    /// Build a map of `SectionID` → rendered HTML fragment for all implemented sections.
    ///
    /// This is the bridge between the template system and HtmlReport's existing
    /// section-builder methods. Sections that HtmlReport cannot yet render are absent
    /// from the returned dictionary — callers insert comment placeholders for those.
    ///
    /// SectionID → builder mapping (matches the legacy body assembly order):
    /// - `.kpiTiles`        — fleet summary stat tiles (total devices, FileVault, SIP, Firewall, Gatekeeper)
    /// - `.fleetSummary`    — same tiles block (kpiTiles and fleetSummary share the summary tiles)
    /// - `.securityTiles`   — same tiles block (security sub-metrics are part of the tile row)
    /// - `.osAdoptionChart` — Chart.js OS version donut + patch bar charts section
    /// - `.patchBar`        — same charts block (patchBar and osAdoptionChart share chartsHTML)
    /// - `.policyTable`     — policy health table from policy-status
    /// - `.profileTable`    — profile status table
    /// - `.complianceBands` — compliance posture hero tile + top non-compliant table
    /// - `.orgInfo`         — catalog appendix (sites, buildings, departments, scripts, etc.)
    ///
    /// Sections listed above are the base map; `buildNewSectionEntries` adds the
    /// rest (`.execSummary`, operational, audit, asset, and Protect sections).
    /// `.aiNarrative` is added only when a narrative was passed in (F3).
    private func buildSectionMap(
        outputURL: URL,
        profileName: String
    ) async throws -> [SectionID: String] {
        let overview = loadJSON(kind: "overview") as? [[String: Any]] ?? []
        let security = loadJSON(kind: "security") as? [[String: Any]] ?? []
        let patchStatus = loadJSON(kind: "patch-status") as? [[String: Any]] ?? []
        let policyStatus = loadJSON(kind: "policy-status") as? [[String: Any]] ?? []
        let profiles = loadJSON(kind: "classic-macos-profiles") as? [[String: Any]] ?? []
        let softwareInstalls = loadJSON(kind: "software-installs") as? [[String: Any]] ?? []
        let eaDefs = loadJSON(kind: "computer-extension-attributes") as? [[String: Any]] ?? []
        let deviceCompliance = loadJSON(kind: "device-compliance") as? [[String: Any]] ?? []
        let computersInventory = loadJSONList(kinds: ["computers", "computers-inventory"])
        let classicPolicies = loadJSONList(kinds: ["policies", "classic-policies"])
        let smartGroups = loadJSONList(kinds: [
            "smart-computer-groups", "computer-smart-groups", "smart-groups",
        ])
        let scripts = loadJSONList(kinds: ["scripts"])
        let packages = loadJSONList(kinds: ["packages"])
        let categories = loadJSONList(kinds: ["categories"])
        let deviceEnrollments = loadJSONList(kinds: [
            "device-enrollment-instances", "classic-device-enrollments", "device-enrollments",
        ])
        let sites = loadJSONList(kinds: ["sites"])
        let buildings = loadJSONList(kinds: ["buildings"])
        let departments = loadJSONList(kinds: ["departments"])
        let iosProfiles = loadJSONList(kinds: ["classic-ios-profiles", "ios-profiles"])

        let secSummary = security.first { $0["section"] as? String == "summary" }
        let secData = secSummary?["data"] as? [String: Any] ?? [:]
        let totalDevices = asInt(secData["total_devices"]) ?? overviewDeviceCount(overview)
        let fileVaultPct = computePct(asInt(secData["filevault_encrypted"]), total: totalDevices)
        let sipPct = computePct(asInt(secData["sip_enabled"]), total: totalDevices)
        let firewallPct = computePct(asInt(secData["firewall_enabled"]), total: totalDevices)
        let gatekeeperPct = computePct(asInt(secData["gatekeeper_enabled"]), total: totalDevices)
        let osVersions = security.filter { $0["section"] as? String == "os_version" }
        let accentColor = HtmlReport.sanitizedHexColor(
            config.branding?.resolvedAccentColor ?? "#2D5EA2",
            fallback: "#2D5EA2"
        )

        let tilesHTML = buildSummaryTiles(
            total: totalDevices,
            fileVaultPct: fileVaultPct,
            sipPct: sipPct,
            firewallPct: firewallPct,
            gatekeeperPct: gatekeeperPct
        )
        let chartsHTML = buildChartsSection(
            osVersions: osVersions,
            patchStatus: patchStatus,
            accentColor: accentColor
        )
        let complianceTileHTML = buildComplianceTile(deviceCompliance: deviceCompliance)
        let topNonCompliantHTML = buildTopNonCompliantTable(
            deviceCompliance: deviceCompliance,
            computersInventory: computersInventory
        )
        let complianceBlock = [complianceTileHTML, topNonCompliantHTML]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let catalogHTML = buildCatalogSection(
            softwareInstalls: softwareInstalls,
            eaDefs: eaDefs,
            classicPolicies: classicPolicies,
            smartGroups: smartGroups,
            scripts: scripts,
            packages: packages,
            categories: categories,
            deviceEnrollments: deviceEnrollments,
            sites: sites,
            buildings: buildings,
            departments: departments,
            iosProfiles: iosProfiles
        )
        let orgInfoBlock = """
        <div class="appendix-section">
          <h2>Appendix: Jamf Pro Catalog Inventory</h2>
          \(catalogHTML)
        </div>
        """

        let patchFailures = loadJSONList(kinds: ["patch-device-failures", "patch-failures"])
        let updateFailures = loadJSONList(kinds: ["update-device-failures", "update-failures"])
        let auditFindings = loadJSONList(kinds: ["audit-findings", "audit"])

        var baseMap: [SectionID: String] = [
            .kpiTiles:        tilesHTML,
            .fleetSummary:    tilesHTML,
            .securityTiles:   tilesHTML,
            .osAdoptionChart: chartsHTML,
            .patchBar:        chartsHTML,
            .policyTable:     buildPolicyHealthSection(policyStatus),
            .profileTable:    buildProfileStatusSection(profiles),
            .complianceBands: complianceBlock,
            .orgInfo:         orgInfoBlock,
        ]
        // F3: present only when the GUI passed a narrative in; the model output
        // is escaped like any other dynamic string.
        if let narrative = aiNarrative, !narrative.isEmpty {
            baseMap[.aiNarrative] = buildAINarrativeSection(narrative)
        }

        let newEntries = buildNewSectionEntries(
            security: security,
            deviceCompliance: deviceCompliance,
            patchStatus: patchStatus,
            patchFailures: patchFailures,
            updateFailures: updateFailures,
            computersInventory: computersInventory,
            auditFindings: auditFindings,
            classicPolicies: classicPolicies,
            classicProfiles: profiles,
            packages: packages,
            scripts: scripts
        )

        return baseMap.merging(newEntries) { existing, _ in existing }
    }

    // MARK: - HTML construction

    private func buildHTML(outputURL: URL, profileName: String = "") async throws -> String {
        let overview = loadJSON(kind: "overview") as? [[String: Any]] ?? []
        let security = loadJSON(kind: "security") as? [[String: Any]] ?? []
        let patchStatus = loadJSON(kind: "patch-status") as? [[String: Any]] ?? []
        let policyStatus = loadJSON(kind: "policy-status") as? [[String: Any]] ?? []
        let profiles = loadJSON(kind: "classic-macos-profiles") as? [[String: Any]] ?? []
        let softwareInstalls = loadJSON(kind: "software-installs") as? [[String: Any]] ?? []
        let eaDefs = loadJSON(kind: "computer-extension-attributes") as? [[String: Any]] ?? []
        let deviceCompliance = loadJSON(kind: "device-compliance") as? [[String: Any]] ?? []
        let computersInventory = loadJSONList(kinds: ["computers", "computers-inventory"])

        // New sections: load from cached snapshots (live fetch only if absent)
        let classicPolicies = loadJSONList(kinds: ["policies", "classic-policies"])
        let smartGroups = loadJSONList(kinds: [
            "smart-computer-groups", "computer-smart-groups", "smart-groups",
        ])
        let scripts = loadJSONList(kinds: ["scripts"])
        let packages = loadJSONList(kinds: ["packages"])
        let categories = loadJSONList(kinds: ["categories"])
        let deviceEnrollments = loadJSONList(kinds: [
            "device-enrollment-instances", "classic-device-enrollments", "device-enrollments",
        ])
        let sites = loadJSONList(kinds: ["sites"])
        let buildings = loadJSONList(kinds: ["buildings"])
        let departments = loadJSONList(kinds: ["departments"])
        let iosProfiles = loadJSONList(kinds: ["classic-ios-profiles", "ios-profiles"])

        let secSummary = security.first { $0["section"] as? String == "summary" }
        let secData = secSummary?["data"] as? [String: Any] ?? [:]
        let totalDevices = asInt(secData["total_devices"]) ?? overviewDeviceCount(overview)
        let fileVaultPct = computePct(asInt(secData["filevault_encrypted"]), total: totalDevices)
        let sipPct = computePct(asInt(secData["sip_enabled"]), total: totalDevices)
        let firewallPct = computePct(asInt(secData["firewall_enabled"]), total: totalDevices)
        let gatekeeperPct = computePct(asInt(secData["gatekeeper_enabled"]), total: totalDevices)

        let osVersions = security.filter { $0["section"] as? String == "os_version" }
        let orgName = config.branding?.resolvedOrgName ?? "Jamf Reports"
        let accentColor = HtmlReport.sanitizedHexColor(
            config.branding?.resolvedAccentColor ?? "#2D5EA2",
            fallback: "#2D5EA2"
        )
        let ts = formattedNow()
        let titleEscaped = HtmlSectionFormatters.escapeHTML(orgName)
        let css = buildCSS(accentColor: accentColor)

        // Task 1: Compliance posture hero tile
        let complianceTileHTML = buildComplianceTile(deviceCompliance: deviceCompliance)

        // Task 2: Top non-compliant devices table
        let topNonCompliantHTML = buildTopNonCompliantTable(
            deviceCompliance: deviceCompliance,
            computersInventory: computersInventory
        )

        let tilesHTML = buildSummaryTiles(
            total: totalDevices,
            fileVaultPct: fileVaultPct,
            sipPct: sipPct,
            firewallPct: firewallPct,
            gatekeeperPct: gatekeeperPct
        )
        let chartsHTML = buildChartsSection(
            osVersions: osVersions,
            patchStatus: patchStatus,
            accentColor: accentColor
        )
        let policyHTML = buildPolicyHealthSection(policyStatus)
        let profileHTML = buildProfileStatusSection(profiles)

        // Task 5: Month-over-month delta
        let historyURL = resolvedHistoryPath(htmlConfig().historyFile, outputURL: outputURL)
        let momHTML = buildMonthOverMonthSection(
            historyURL: historyURL,
            currentSecurity: security,
            deviceCompliance: deviceCompliance,
            totalDevices: totalDevices,
            fileVaultPct: fileVaultPct
        )

        let policiesTableHTML = buildPoliciesTable(classicPolicies)
        let smartGroupsTableHTML = buildSmartGroupsTable(smartGroups)
        let scriptsTableHTML = buildScriptsTable(scripts)
        let packagesTableHTML = buildPackagesTable(packages)
        let categoriesTableHTML = buildCategoriesTable(categories)
        let historyHTML = buildHistorySection(
            security: security,
            outputURL: outputURL
        )

        // Task 6: Catalog moved to appendix
        let catalogHTML = buildCatalogSection(
            softwareInstalls: softwareInstalls,
            eaDefs: eaDefs,
            classicPolicies: classicPolicies,
            smartGroups: smartGroups,
            scripts: scripts,
            packages: packages,
            categories: categories,
            deviceEnrollments: deviceEnrollments,
            sites: sites,
            buildings: buildings,
            departments: departments,
            iosProfiles: iosProfiles
        )

        // Task 4: Data provenance footer block
        let provenanceHTML = buildProvenanceBlock(
            overview: overview,
            profileName: profileName
        )

        let scriptHTML = buildScript()

        let verifyFilename = HtmlSectionFormatters.escapeHTML(outputURL.lastPathComponent)
        let placeholder = HTMLReportSHA256Placeholder
        return """
        <!DOCTYPE html>
        <html lang="en" data-theme="light">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta name="report-sha256" content="\(placeholder)">
        <title>\(titleEscaped) — Jamf Instance Report</title>
        <script>\(ChartJSBundle.inlineScript)</script>
        \(css)
        </head>
        <body>
        <a class="skip-link" href="#main-content">Skip to main content</a>
        <header>
          <div class="header-content">
            <div>
              <h1>\(titleEscaped)</h1>
              <p class="subtitle">Jamf Instance Report · \(ts)</p>
            </div>
            <button class="theme-toggle" onclick="toggleTheme()" aria-label="Toggle theme" aria-pressed="false">&#9728; / &#9790;</button>
          </div>
        </header>
        <main id="main-content">
        \(complianceTileHTML)
        \(topNonCompliantHTML)
        \(momHTML)
        \(tilesHTML)
        \(chartsHTML)
        \(policyHTML)
        \(profileHTML)
        \(policiesTableHTML)
        \(smartGroupsTableHTML)
        \(scriptsTableHTML)
        \(packagesTableHTML)
        \(categoriesTableHTML)
        \(historyHTML)
        <div class="appendix-section">
          <h2>Appendix: Jamf Pro Catalog Inventory</h2>
          \(catalogHTML)
        </div>
        </main>
        \(provenanceHTML)
        <footer>
          <p>Generated by Jamf Reports &middot; <a href="https://github.com/tonyyo11/jamf-reports-community">tonyyo11/jamf-reports-community</a></p>
          <p class="verify-footer" style="margin-top:8px;font-size:11px;opacity:0.7">
            Source fingerprint: <code>\(placeholder)</code>
            &middot; verify with <code>shasum -a 256 \(verifyFilename)</code>
            (see <code>report-sha256</code> meta tag; replace the hash field with 64 zeros to reproduce)
          </p>
        </footer>
        \(scriptHTML)
        </body>
        </html>
        """
    }

    // MARK: - Section builders

    private func buildSummaryTiles(
        total: Int,
        fileVaultPct: Double,
        sipPct: Double,
        firewallPct: Double,
        gatekeeperPct: Double
    ) -> String {
        let tiles: [(String, String, Double?)] = [
            ("Total Devices", "\(total)", nil),
            ("FileVault", String(format: "%.1f%%", fileVaultPct), fileVaultPct),
            ("SIP", String(format: "%.1f%%", sipPct), sipPct),
            ("Firewall", String(format: "%.1f%%", firewallPct), firewallPct),
            ("Gatekeeper", String(format: "%.1f%%", gatekeeperPct), gatekeeperPct),
        ]
        let tileHTML = tiles.map { label, value, pct -> String in
            let statusClass = pct.map { colorClass($0) } ?? ""
            return """
            <div class="tile \(statusClass)">
              <div class="tile-value">\(HtmlSectionFormatters.escapeHTML(value))</div>
              <div class="tile-label">\(HtmlSectionFormatters.escapeHTML(label))</div>
            </div>
            """
        }.joined(separator: "\n")
        return """
        <section class="tiles-row">\n\(tileHTML)\n</section>
        """
    }

    // MARK: - Task 1: Compliance posture hero tile

    /// Renders a prominent compliance score tile from the device-compliance snapshot.
    /// Omitted gracefully when the snapshot is empty.
    func buildComplianceTile(deviceCompliance: [[String: Any]]) -> String {
        guard !deviceCompliance.isEmpty else { return "" }
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
        <section class="compliance-hero \(colorCls)">
          <div class="compliance-hero-value">\(pctStr)</div>
          <div class="compliance-hero-label">\(label)</div>
        </section>
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

        let rows = devices.prefix(10).map { d -> String in
            let daysLabel = d.daysSinceCheckin >= 0 ? "\(d.daysSinceCheckin)" : "—"
            return """
            <tr>
              <td>\(HtmlSectionFormatters.escapeHTML(d.name))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(d.serial))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(daysLabel))</td>
              <td>\(d.failureCount)</td>
              <td>\(HtmlSectionFormatters.escapeHTML(d.topFailure))</td>
            </tr>
            """
        }.joined(separator: "\n")

        return """
        <section class="content-section" id="top-noncompliant">
          <h2>Top Non-Compliant Devices</h2>
          <table class="data-table">
            <thead>
              <tr>
                <th>Device Name</th>
                <th>Serial</th>
                <th>Days Since Check-in</th>
                <th>Failure Count</th>
                <th>Top Failure</th>
              </tr>
            </thead>
            <tbody>\(rows)</tbody>
          </table>
        </section>
        """
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

    // MARK: - Task 4: Data provenance block

    /// Renders a metadata footer block above the page footer.
    ///
    /// When `provenance` is supplied (Swift-generated reports), additional fields are
    /// rendered: Run ID, Tenant URL, and Operator. Plain HTML reports generated without
    /// provenance show only the four original fields.
    func buildProvenanceBlock(
        overview: [[String: Any]],
        profileName: String,
        provenance: Provenance? = nil
    ) -> String {
        // Collection time: mtime of the newest JSON file in dataDir (approximation)
        let collectionTime = newestFileDate(in: dataDir).map { formattedDate($0) } ?? "unknown"

        // Enrolled count from overview
        let enrolledCount = overviewDeviceCount(overview)
        let enrolledStr = enrolledCount > 0 ? "\(enrolledCount)" : "—"

        // jamf-cli version: prefer provenance (captured at run time), fall back to overview
        let jamfCLIVersion: String = provenance?.jamfCLIVersion ?? {
            for item in overview {
                if let ver = item["jamf_cli_version"] as? String { return ver }
                if let meta = item["metadata"] as? [String: Any],
                   let ver = meta["version"] as? String { return ver }
            }
            return "—"
        }()

        let profileDisplay = profileName.isEmpty ? "—" : profileName

        var spans = [
            "<span>Data collected: \(HtmlSectionFormatters.escapeHTML(collectionTime))</span>",
            "<span>&middot;</span>",
            "<span>Profile: \(HtmlSectionFormatters.escapeHTML(profileDisplay))</span>",
            "<span>&middot;</span>",
            "<span>jamf-cli: \(HtmlSectionFormatters.escapeHTML(jamfCLIVersion))</span>",
            "<span>&middot;</span>",
            "<span>Enrolled: \(HtmlSectionFormatters.escapeHTML(enrolledStr)) devices</span>",
        ]

        if let prov = provenance {
            spans.append("<span>&middot;</span>")
            spans.append("<span>Run ID: \(HtmlSectionFormatters.escapeHTML(prov.runID))</span>")
            if let tenantURL = prov.jamfTenantURL {
                spans.append("<span>&middot;</span>")
                spans.append("<span>Tenant URL: \(HtmlSectionFormatters.escapeHTML(tenantURL))</span>")
            }
            spans.append("<span>&middot;</span>")
            spans.append("<span>Operator: \(HtmlSectionFormatters.escapeHTML(prov.operatorUserHost))</span>")
        }

        let inner = spans.map { "  \($0)" }.joined(separator: "\n")
        return "<div class=\"provenance-block\">\n\(inner)\n</div>"
    }

    private func newestFileDate(in dir: URL) -> Date? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files.compactMap { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }

    private func formattedDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    // MARK: - Task 5: Month-over-month delta

    /// Renders a "What changed since last month" 3-row block comparing current metrics
    /// to the history entry closest to 30 days ago.
    func buildMonthOverMonthSection(
        historyURL: URL,
        currentSecurity: [[String: Any]],
        deviceCompliance: [[String: Any]],
        totalDevices: Int,
        fileVaultPct: Double
    ) -> String {
        let history = loadHistory(path: historyURL)
        guard !history.isEmpty else { return "" }

        // Find the entry closest to 30 days ago
        let targetDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let iso = ISO8601DateFormatter()

        let entriesWithDates: [(HistoryEntry, Date)] = history.compactMap { entry in
            guard let date = iso.date(from: entry.timestamp) else { return nil }
            return (entry, date)
        }

        guard !entriesWithDates.isEmpty else { return "" }

        let closest = entriesWithDates.min { lhs, rhs in
            abs(lhs.1.timeIntervalSince(targetDate)) < abs(rhs.1.timeIntervalSince(targetDate))
        }

        guard let (pastEntry, pastDate) = closest else { return "" }

        // Require the closest entry to be at least 20 days old
        let daysDiff = Calendar.current.dateComponents([.day], from: pastDate, to: Date()).day ?? 0
        guard daysDiff >= 20 else {
            return """
            <section class="content-section mom-section">
              <h2>What Changed Since Last Month</h2>
              <p class="empty-note">Insufficient history — need 30+ days of runs.</p>
            </section>
            """
        }

        let pastTotal = pastEntry.versions.reduce(0) { $0 + $1.count }

        // Compliance % from current deviceCompliance snapshot
        let currentCompliancePct = compliancePct(from: deviceCompliance)
        // History does not store compliance %; show device count delta instead
        let deviceDelta = totalDevices - pastTotal
        let deviceSign = deviceDelta >= 0 ? "+" : ""

        // FileVault % delta: history only stores OS versions, so we can only show N/A
        // unless we store more fields. Show what we have.
        let deltaTuples: [(String, String)] = [
            ("Total Devices", "\(deviceSign)\(deviceDelta) (now \(totalDevices))"),
            ("Compliance Rate", currentCompliancePct >= 0
                ? String(format: "%.0f%% (current snapshot)", currentCompliancePct)
                : "—"),
            ("FileVault", String(format: "%.1f%% (current snapshot)", fileVaultPct)),
        ]

        let rows = deltaTuples.map { label, value in
            "<tr><td>\(HtmlSectionFormatters.escapeHTML(label))</td><td>\(HtmlSectionFormatters.escapeHTML(value))</td></tr>"
        }.joined(separator: "\n")

        let sinceLabel = HtmlSectionFormatters.escapeHTML(String(pastEntry.timestamp.prefix(10)))
        return """
        <section class="content-section mom-section">
          <h2>What Changed Since Last Month</h2>
          <p class="mom-since">Compared to snapshot from \(sinceLabel)</p>
          <table class="summary-table">
            <thead><tr><th>Metric</th><th>Change</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </section>
        """
    }

    private func compliancePct(from deviceCompliance: [[String: Any]]) -> Double {
        guard !deviceCompliance.isEmpty else { return -1 }
        let total = deviceCompliance.count
        let passing = deviceCompliance.filter { item -> Bool in
            let failCount = asInt(item["failure_count"]) ?? asInt(item["failures_count"]) ?? 0
            return failCount == 0
        }.count
        return Double(passing) / Double(total) * 100
    }

    func buildChartsSection(
        osVersions: [[String: Any]],
        patchStatus: [[String: Any]],
        accentColor: String
    ) -> String {
        // Use JSONSerialization for all JS-context array injection. HtmlSectionFormatters.escapeHTML() is wrong
        // here — it escapes for HTML attribute/text context, not JavaScript string literals.
        // JSON encoding is the only correct escape: it handles backslash, U+2028/U+2029,
        // </script>, and all other JS-literal break sequences.
        let osLabels = osVersions.map { $0["os_version"] as? String ?? "" }
        let osCounts = osVersions.map { asInt($0["count"]) ?? 0 }
        let osLabelsJS = jsonArray(osLabels)
        let osCountsJS = jsonArray(osCounts)

        let patchTitles = patchStatus.prefix(10).map { $0["title"] as? String ?? "" }
        let patchPcts = patchStatus.prefix(10).map { item -> Double in
            let s = item["compliance_pct"] as? String ?? "0"
            return Double(s.replacingOccurrences(of: "%", with: "")) ?? 0
        }
        let patchLabelsJS = jsonArray(Array(patchTitles))
        let patchPctsJS = jsonArray(Array(patchPcts))

        guard !osVersions.isEmpty || !patchStatus.isEmpty else { return "" }

        return """
        <section class="charts-section">
          <h2>Fleet Distribution</h2>
          <div class="charts-grid">
        \(osVersions.isEmpty ? "" : """
            <div class="chart-card">
              <h3>OS Version Distribution</h3>
              <canvas id="osChart" height="260"></canvas>
            </div>
        """)
        \(patchStatus.isEmpty ? "" : """
            <div class="chart-card">
              <h3>Patch Compliance (Top 10)</h3>
              <canvas id="patchChart" height="260"></canvas>
            </div>
        """)
          </div>
        </section>
        <script>
        (function() {
          \(osVersions.isEmpty ? "" : """
          const osCtx = document.getElementById('osChart');
          if (osCtx) {
            new Chart(osCtx, {
              type: 'doughnut',
              data: {
                labels: \(osLabelsJS),
                datasets: [{ data: \(osCountsJS), borderWidth: 1 }]
              },
              options: { responsive: true, plugins: { legend: { position: 'right' } } }
            });
          }
          """)
          \(patchStatus.isEmpty ? "" : """
          const patchCtx = document.getElementById('patchChart');
          if (patchCtx) {
            new Chart(patchCtx, {
              type: 'bar',
              data: {
                labels: \(patchLabelsJS),
                datasets: [{
                  label: 'Compliance %',
                  data: \(patchPctsJS),
                  backgroundColor: '\(accentColor)'
                }]
              },
              options: {
                indexAxis: 'y',
                responsive: true,
                scales: { x: { min: 0, max: 100 } }
              }
            });
          }
          """)
        })();
        </script>
        """
    }

    private func buildPolicyHealthSection(_ policyStatus: [[String: Any]]) -> String {
        guard let first = policyStatus.first else {
            return HtmlSectionFormatters.emptySection(title: "Policy Health", dataKind: "policy-status")
        }
        let summary = first["summary"] as? [String: Any] ?? [:]
        let findings = first["config_findings"] as? [[String: Any]] ?? []

        let summaryRows = [
            ("Total Policies", "\(asInt(summary["total_policies"]) ?? 0)"),
            ("Enabled", "\(asInt(summary["enabled"]) ?? 0)"),
            ("Disabled", "\(asInt(summary["disabled"]) ?? 0)"),
            ("Config Findings", "\(asInt(summary["config_findings"]) ?? 0)"),
            ("Warnings", "\(asInt(summary["warnings"]) ?? 0)"),
        ].map { label, value in
            "<tr><td>\(HtmlSectionFormatters.escapeHTML(label))</td><td>\(HtmlSectionFormatters.escapeHTML(value))</td></tr>"
        }.joined(separator: "\n")

        let findingRows = findings.prefix(50).map { f -> String in
            let sev = f["severity"] as? String ?? ""
            let cls = sev.lowercased() == "error" ? "class=\"row-error\"" : "class=\"row-warn\""
            return """
            <tr \(cls)>
              <td>\(HtmlSectionFormatters.escapeHTML(sev))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(f["policy"] as? String ?? ""))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(f["check"] as? String ?? ""))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(f["detail"] as? String ?? ""))</td>
            </tr>
            """
        }.joined(separator: "\n")

        return """
        <section class="content-section">
          <h2>Policy Health</h2>
          <table class="summary-table">
            <thead><tr><th>Metric</th><th>Count</th></tr></thead>
            <tbody>\(summaryRows)</tbody>
          </table>
          \(findings.isEmpty ? "" : """
          <h3>Config Findings</h3>
          <table class="data-table">
            <thead><tr><th>Severity</th><th>Policy</th><th>Check</th><th>Detail</th></tr></thead>
            <tbody>\(findingRows)</tbody>
          </table>
          """)
        </section>
        """
    }

    private func buildProfileStatusSection(_ profiles: [[String: Any]]) -> String {
        guard !profiles.isEmpty else {
            return HtmlSectionFormatters.emptySection(
                title: "Profile Status", dataKind: "profile-status"
            )
        }
        let rows = profiles.prefix(100).map { p -> String in
            let errors = asInt(p["error_count"]) ?? 0
            let cls = errors > 0 ? "class=\"row-warn\"" : ""
            return """
            <tr \(cls)>
              <td>\(HtmlSectionFormatters.escapeHTML(p["id"].map { "\($0)" } ?? ""))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(p["name"] as? String ?? ""))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(p["category"] as? String ?? ""))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(p["management_status"] as? String ?? ""))</td>
              <td>\(errors)</td>
            </tr>
            """
        }.joined(separator: "\n")
        return """
        <section class="content-section">
          <h2>Profile Status</h2>
          <table class="data-table">
            <thead>
              <tr><th>ID</th><th>Name</th><th>Category</th><th>Management Status</th><th>Errors</th></tr>
            </thead>
            <tbody>\(rows)</tbody>
          </table>
        </section>
        """
    }

    // MARK: - Catalog overview (count cards for all catalog items)

    private func buildCatalogSection(
        softwareInstalls: [[String: Any]],
        eaDefs: [[String: Any]],
        classicPolicies: [[String: Any]],
        smartGroups: [[String: Any]],
        scripts: [[String: Any]],
        packages: [[String: Any]],
        categories: [[String: Any]],
        deviceEnrollments: [[String: Any]],
        sites: [[String: Any]],
        buildings: [[String: Any]],
        departments: [[String: Any]],
        iosProfiles: [[String: Any]]
    ) -> String {
        var items: [(String, String)] = [
            ("Software Titles", "\(softwareInstalls.count)"),
            ("Extension Attributes", "\(eaDefs.count)"),
        ]
        if !classicPolicies.isEmpty { items.append(("Policies", "\(classicPolicies.count)")) }
        if !smartGroups.isEmpty { items.append(("Smart Groups", "\(smartGroups.count)")) }
        if !scripts.isEmpty { items.append(("Scripts", "\(scripts.count)")) }
        if !packages.isEmpty { items.append(("Packages", "\(packages.count)")) }
        if !categories.isEmpty { items.append(("Categories", "\(categories.count)")) }
        if !deviceEnrollments.isEmpty {
            items.append(("ADE Instances", "\(deviceEnrollments.count)"))
        }
        if !sites.isEmpty { items.append(("Sites", "\(sites.count)")) }
        if !buildings.isEmpty { items.append(("Buildings", "\(buildings.count)")) }
        if !departments.isEmpty { items.append(("Departments", "\(departments.count)")) }
        if !iosProfiles.isEmpty { items.append(("iOS Profiles", "\(iosProfiles.count)")) }

        let cards = items.map { label, value in
            "<div class=\"count-card\"><div class=\"count-value\">\(value)</div>"
            + "<div class=\"count-label\">\(HtmlSectionFormatters.escapeHTML(label))</div></div>"
        }.joined(separator: "\n")

        return """
        <section class="content-section">
          <h2>Catalog Overview</h2>
          <div class="count-cards">\n\(cards)\n</div>
        </section>
        """
    }

    // MARK: - New section builders

    /// Render a table of classic policies (name + category, up to 200 rows).
    func buildPoliciesTable(_ policies: [[String: Any]]) -> String {
        guard !policies.isEmpty else {
            return HtmlSectionFormatters.emptySection(title: "Policies", dataKind: "policies")
        }
        let rows = policies.prefix(200).map { p -> String in
            let name = p["name"] as? String ?? ""
            let cat = categoryName(from: p["category"])
            let enabled = p["enabled"] as? Bool ?? true
            let cls = enabled ? "" : "class=\"row-warn\""
            return """
            <tr \(cls)>
              <td>\(HtmlSectionFormatters.escapeHTML(name))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(cat))</td>
              <td>\(enabled ? "Enabled" : "Disabled")</td>
            </tr>
            """
        }.joined(separator: "\n")
        return """
        <section class="content-section">
          <h2>Policies (\(policies.count))</h2>
          <table class="data-table">
            <thead><tr><th>Name</th><th>Category</th><th>State</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </section>
        """
    }

    /// Render a table of computer smart groups (name + criteria count).
    func buildSmartGroupsTable(_ groups: [[String: Any]]) -> String {
        guard !groups.isEmpty else {
            return HtmlSectionFormatters.emptySection(
                title: "Smart Groups", dataKind: "smart-computer-groups"
            )
        }
        let rows = groups.prefix(200).map { g -> String in
            let name = g["name"] as? String ?? ""
            let criteria = (g["criteria"] as? [[String: Any]])?.count
                ?? asInt(g["criteria_count"]) ?? 0
            return """
            <tr>
              <td>\(HtmlSectionFormatters.escapeHTML(name))</td>
              <td>\(criteria)</td>
            </tr>
            """
        }.joined(separator: "\n")
        return """
        <section class="content-section">
          <h2>Smart Groups (\(groups.count))</h2>
          <table class="data-table">
            <thead><tr><th>Name</th><th>Criteria Count</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </section>
        """
    }

    /// Render a table of scripts (name + category, up to 200 rows).
    func buildScriptsTable(_ scripts: [[String: Any]]) -> String {
        guard !scripts.isEmpty else {
            return HtmlSectionFormatters.emptySection(title: "Scripts", dataKind: "scripts")
        }
        let rows = scripts.prefix(200).map { s -> String in
            let name = s["name"] as? String ?? s["displayName"] as? String ?? ""
            let cat = categoryName(from: s["category"])
            return """
            <tr>
              <td>\(HtmlSectionFormatters.escapeHTML(name))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(cat))</td>
            </tr>
            """
        }.joined(separator: "\n")
        return """
        <section class="content-section">
          <h2>Scripts (\(scripts.count))</h2>
          <table class="data-table">
            <thead><tr><th>Name</th><th>Category</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </section>
        """
    }

    /// Render a table of packages (name + category, up to 200 rows).
    func buildPackagesTable(_ packages: [[String: Any]]) -> String {
        guard !packages.isEmpty else {
            return HtmlSectionFormatters.emptySection(title: "Packages", dataKind: "packages")
        }
        let rows = packages.prefix(200).map { p -> String in
            let name = p["name"] as? String ?? p["fileName"] as? String ?? ""
            let cat = categoryName(from: p["category"])
            return """
            <tr>
              <td>\(HtmlSectionFormatters.escapeHTML(name))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(cat))</td>
            </tr>
            """
        }.joined(separator: "\n")
        return """
        <section class="content-section">
          <h2>Packages (\(packages.count))</h2>
          <table class="data-table">
            <thead><tr><th>Name</th><th>Category</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </section>
        """
    }

    /// Render a table of categories (name only, up to 200 rows).
    func buildCategoriesTable(_ categories: [[String: Any]]) -> String {
        guard !categories.isEmpty else {
            return HtmlSectionFormatters.emptySection(title: "Categories", dataKind: "categories")
        }
        let rows = categories.prefix(200).map { c -> String in
            let name = c["name"] as? String ?? ""
            let priority = c["priority"].map { "\($0)" } ?? ""
            return """
            <tr>
              <td>\(HtmlSectionFormatters.escapeHTML(name))</td>
              <td>\(HtmlSectionFormatters.escapeHTML(priority))</td>
            </tr>
            """
        }.joined(separator: "\n")
        return """
        <section class="content-section">
          <h2>Categories (\(categories.count))</h2>
          <table class="data-table">
            <thead><tr><th>Name</th><th>Priority</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </section>
        """
    }

    // MARK: - History tracking + inline SVG trend

    /// Append a metric snapshot to the history file (when `html.track_history: true`)
    /// and render an inline SVG trend chart from recent history entries.
    func buildHistorySection(
        security: [[String: Any]],
        outputURL: URL
    ) -> String {
        let cfg = htmlConfig()
        guard cfg.trackHistory else { return "" }

        let histPath = resolvedHistoryPath(cfg.historyFile, outputURL: outputURL)
        appendHistoryEntry(security: security, path: histPath)

        let history = loadHistory(path: histPath)
        guard history.count >= 2 else {
            return """
            <section class="content-section">
              <h2>OS Adoption Trend</h2>
              <p class="empty-note">Not enough history yet (\(history.count) snapshot(s)). Run again after collecting more data.</p>
            </section>
            """
        }
        let svgHTML = renderHistorySVG(history: history)
        return """
        <section class="content-section">
          <h2>OS Adoption Trend</h2>
          \(svgHTML)
        </section>
        """
    }

    // MARK: History helpers

    /// Resolve the history file path. Relative paths are resolved next to the output file.
    func resolvedHistoryPath(_ configured: String, outputURL: URL) -> URL {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return outputURL.deletingLastPathComponent()
                .appendingPathComponent("html_history.json")
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath:
                NSString(string: trimmed).expandingTildeInPath)
        }
        return outputURL.deletingLastPathComponent().appendingPathComponent(trimmed)
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

    // MARK: - CSS

    /// Testable wrapper — returns the raw `<style>` block for a given accent color.
    func buildCSSPublic(accentColor: String) -> String { buildCSS(accentColor: accentColor) }

    private func buildCSS(accentColor: String) -> String {
        """
        <style>
        /* Light mode is the default; dark mode is opt-in via data-theme="dark". */
        :root {
          --accent: \(accentColor);
          --bg: #f5f7fa;
          --bg2: #ffffff;
          --card: #ffffff;
          --text: #1a1a2e;
          --subtext: #555;
          --border: #dde;
          --green: #2e7d32;
          --yellow: #e65100;
          --red: #c62828;
        }
        [data-theme="dark"] {
          --bg: #1a1a2e;
          --bg2: #16213e;
          --card: #0f3460;
          --text: #e0e0e0;
          --subtext: #a0a0b0;
          --border: #2a3a5e;
          --green: #4caf50;
          --yellow: #ff9800;
          --red: #f44336;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
               background: var(--bg); color: var(--text); line-height: 1.5; }
        header { background: var(--bg2); border-bottom: 1px solid var(--border);
                 padding: 1.2rem 2rem; }
        .header-content { display: flex; justify-content: space-between; align-items: center; }
        h1 { font-size: 1.6rem; color: var(--accent); }
        .subtitle { color: var(--subtext); font-size: 0.85rem; margin-top: 0.2rem; }
        main { max-width: 1300px; margin: 0 auto; padding: 2rem; }
        section { margin-bottom: 2.5rem; }
        h2 { font-size: 1.2rem; margin-bottom: 1rem; color: var(--text);
             border-bottom: 1px solid var(--border); padding-bottom: 0.4rem; }
        h3 { font-size: 1rem; margin: 1rem 0 0.5rem; color: var(--subtext); }
        .tiles-row { display: flex; flex-wrap: wrap; gap: 1rem; }
        .tile { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
                padding: 1.2rem 1.5rem; min-width: 140px; text-align: center; }
        .tile.ok { border-color: var(--green); }
        .tile.warn { border-color: var(--yellow); }
        .tile.bad { border-color: var(--red); }
        .tile-value { font-size: 2rem; font-weight: 700; }
        .tile-label { font-size: 0.8rem; color: var(--subtext); margin-top: 0.3rem; }
        .charts-section h2 { margin-bottom: 1rem; }
        .charts-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(380px, 1fr));
                       gap: 1.5rem; }
        .chart-card { background: var(--card); border: 1px solid var(--border);
                      border-radius: 10px; padding: 1.2rem; }
        .content-section { overflow-x: auto; }
        .content-section table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
        table th, table td { padding: 0.6rem 1rem; text-align: left;
                             border-bottom: 1px solid var(--border); }
        table th { background: var(--bg2); font-weight: 600; }
        .summary-table { max-width: 400px; margin-bottom: 1.5rem; }
        tr.row-error td { color: #c62828; }
        tr.row-warn td { color: #e65100; }
        [data-theme="dark"] tr.row-error td { color: #ff6b6b; }
        [data-theme="dark"] tr.row-warn td { color: #ffd166; }
        .count-cards { display: flex; flex-wrap: wrap; gap: 1rem; }
        .count-card { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
                      padding: 1rem 1.5rem; min-width: 160px; text-align: center; }
        .count-value { font-size: 1.8rem; font-weight: 700; color: var(--accent); }
        .count-label { font-size: 0.8rem; color: var(--subtext); margin-top: 0.25rem; }
        .theme-toggle { background: none; border: 1px solid var(--border); border-radius: 6px;
                        padding: 0.4rem 0.8rem; color: var(--text); cursor: pointer; }
        footer { text-align: center; padding: 2rem; font-size: 0.8rem; color: var(--subtext); }
        footer a { color: var(--accent); }
        .history-svg { display: block; width: 100%; max-width: 620px; height: auto; overflow: visible; }
        .empty-note { color: var(--subtext); font-size: 0.85rem; margin-top: 0.5rem; }
        /* Task 1: Compliance hero tile */
        .compliance-hero {
          padding: 1.8rem 2rem; border-radius: 12px; margin-bottom: 2rem;
          text-align: center; border: 2px solid transparent;
        }
        .compliance-hero-green { background: #e8f5e9; border-color: var(--green); }
        .compliance-hero-amber { background: #fff3e0; border-color: var(--yellow); }
        .compliance-hero-red   { background: #ffebee; border-color: var(--red); }
        [data-theme="dark"] .compliance-hero-green { background: #1b3a1e; }
        [data-theme="dark"] .compliance-hero-amber { background: #3e2a00; }
        [data-theme="dark"] .compliance-hero-red   { background: #3b0d0d; }
        .compliance-hero-value { font-size: 3.5rem; font-weight: 800; color: var(--text); }
        .compliance-hero-label { font-size: 1rem; color: var(--subtext); margin-top: 0.4rem; }
        /* Task 4: Provenance block */
        .provenance-block {
          display: flex; flex-wrap: wrap; gap: 0.5rem 1rem; justify-content: center;
          padding: 0.8rem 2rem; background: var(--bg2); border-top: 1px solid var(--border);
          font-size: 0.8rem; color: var(--subtext);
        }
        /* Task 5: Month-over-month */
        .mom-section .mom-since { font-size: 0.8rem; color: var(--subtext); margin-bottom: 0.75rem; }
        /* Task 6: Appendix */
        .appendix-section { border-top: 2px dashed var(--border); padding-top: 1.5rem;
                            margin-top: 2rem; }
        .appendix-section > h2 { color: var(--subtext); font-size: 1rem; }
        /* Empty section placeholder */
        .empty-section { border: 1px dashed var(--border); border-radius: 8px;
                         padding: 1rem 1.5rem; background: var(--bg2); }
        .empty-note { color: var(--subtext); font-size: 0.85rem; font-style: italic;
                      margin-top: 0.4rem; }
        /* Finding #6: device deep-link anchors */
        .device-link { color: inherit; text-decoration: underline dotted; }
        .device-anchor { display: block; visibility: hidden; height: 0; }
        :target { background: rgba(255,234,0,0.18); transition: background 0.4s ease; }
        /* Skip-link: visually hidden until focused */
        .skip-link {
          position: absolute;
          top: -999px;
          left: 0;
          background: #004165;
          color: #fff;
          padding: 8px 16px;
          border-radius: 0 0 6px 0;
          font-size: 0.85rem;
          font-weight: 600;
          z-index: 9999;
          text-decoration: none;
        }
        .skip-link:focus { top: 0; }
        /* Reduced motion */
        @media (prefers-reduced-motion: reduce) {
          :target { transition: none; }
        }
        /* Print media query — force light backgrounds/dark text; hide interactive controls */
        @media print {
          :root, [data-theme="dark"] {
            --bg: #ffffff !important;
            --bg2: #ffffff !important;
            --card: #ffffff !important;
            --text: #000000 !important;
            --subtext: #444 !important;
            --border: #bbb !important;
          }
          body { background: #fff !important; color: #000 !important; }
          header { background: #fff !important; }
          .compliance-hero-green { background: #e8f5e9 !important; }
          .compliance-hero-amber { background: #fff3e0 !important; }
          .compliance-hero-red   { background: #ffebee !important; }
          .theme-toggle { display: none; }
          .skip-link { display: none; }
          a { color: #000 !important; text-decoration: none; }
        }
        </style>
        """
    }

    // MARK: - JavaScript

    func buildScript() -> String {
        """
        <script>
        (function() {
          // Restore persisted theme preference; default is light.
          const saved = localStorage.getItem('jr-theme');
          if (saved === 'dark') {
            document.documentElement.setAttribute('data-theme', 'dark');
          }
        })();
        function toggleTheme() {
          const html = document.documentElement;
          const next = html.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
          html.setAttribute('data-theme', next);
          localStorage.setItem('jr-theme', next);
          const btn = document.querySelector('.theme-toggle');
          if (btn) btn.setAttribute('aria-pressed', next === 'dark' ? 'true' : 'false');
        }
        // Cleanup Analysis tab navigation.
        // Buttons have class="cleanup-tab" and data-target="cpane-<id>".
        // Panes have id="cpane-<id>" and class="cleanup-pane [active]".
        document.addEventListener('click', function(e) {
          var btn = e.target.closest('.cleanup-tab');
          if (!btn) return;
          var container = btn.closest('.cleanup-tabs');
          if (!container) return;
          // Deactivate all sibling tabs.
          container.querySelectorAll('.cleanup-tab').forEach(function(t) {
            t.classList.remove('active');
            t.setAttribute('aria-selected', 'false');
            t.setAttribute('tabindex', '-1');
          });
          // Activate the clicked tab.
          btn.classList.add('active');
          btn.setAttribute('aria-selected', 'true');
          btn.setAttribute('tabindex', '0');
          // Deactivate all panes in the same section, then activate the target.
          var section = btn.closest('section');
          if (section) {
            section.querySelectorAll('.cleanup-pane').forEach(function(p) {
              p.classList.remove('active');
            });
            var target = document.getElementById(btn.getAttribute('data-target'));
            if (target) target.classList.add('active');
          }
        });
        </script>
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
        let fm = FileManager.default
        let subdir = dataDir.appendingPathComponent(kind, isDirectory: true)
        var candidates: [URL] = []
        if fm.fileExists(atPath: subdir.path),
           let files = try? fm.contentsOfDirectory(
            at: subdir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
           ) {
            candidates.append(contentsOf: files.filter {
                $0.pathExtension == "json"
                && $0.lastPathComponent.lowercased() != SnapshotManifest.fileName
            })
        }
        // Also check flat pattern under dataDir
        if let files = try? fm.contentsOfDirectory(
            at: dataDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: files.filter {
                $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(kind + "_")
            })
        }
        guard let newest = candidates.max(by: { lhs, rhs in
            let a = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let b = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return a < b
        }), let data = try? Data(contentsOf: newest) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
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
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }

    /// Serialize an array to a JSON literal for injection into a JavaScript context.
    ///
    /// This is the ONLY correct escape for user-controlled data inside JS string literals
    /// or array positions. `HtmlSectionFormatters.escapeHTML()` is wrong in JS context: it does not escape
    /// backslash, U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR, or `</script>`.
    /// JSON encoding handles all of these correctly.
    ///
    /// - Parameter array: An array of `String`, `Int`, or `Double` values.
    /// - Returns: A JSON array literal (e.g. `["foo","bar"]`) safe for direct injection
    ///   into a `<script>` block. Falls back to `[]` on serialization failure.
    func jsonArray<T>(_ array: [T]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: []),
              var result = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        // Foundation's JSONSerialization does not escape U+2028 (LINE SEPARATOR) or
        // U+2029 (PARAGRAPH SEPARATOR). Both are legal JSON but they are treated as
        // line terminators inside a JavaScript <script> block, breaking string literals.
        // Escape them manually so the JSON array is safe in any JS context.
        result = result
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            // Foundation does not escape `/`, so a JSON string containing
            // `</script>` would close the surrounding <script> block. Escape
            // the closing-tag sequence so user-controlled chart labels
            // (e.g. patch policy names) cannot break out into HTML context.
            .replacingOccurrences(of: "</", with: "<\\/")
        return result
    }

    /// P9-A-02: validate a brand accent color string before interpolating it into
    /// CSS or a JS string literal. A user-supplied value like `red; }` would
    /// otherwise close the `--accent:` declaration and inject arbitrary CSS, and
    /// a value containing a single quote would break out of the Chart.js
    /// `backgroundColor: '...'` JS literal. Accept only conventional hex colors;
    /// fall back to `fallback` (which the caller controls and is hard-coded).
    static func sanitizedHexColor(_ raw: String, fallback: String) -> String {
        let pattern = "^#[0-9A-Fa-f]{3,8}$"
        return raw.range(of: pattern, options: .regularExpression) != nil ? raw : fallback
    }

    private func formattedNow() -> String {
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
    func inventoryLastContact(_ item: [String: Any]) -> String {
        if let general = item["general"] as? [String: Any] {
            if let ts = general["lastContactTime"] as? String, !ts.isEmpty { return ts }
            if let ts = general["reportDate"] as? String, !ts.isEmpty { return ts }
        }
        return item["last_check_in"] as? String ?? item["last_contact"] as? String ?? ""
    }

    /// Extract asset tag from a `computers list` record.
    func inventoryAssetTag(_ item: [String: Any]) -> String {
        if let general = item["general"] as? [String: Any],
           let tag = general["assetTag"] as? String, !tag.isEmpty {
            return tag
        }
        return item["asset_tag"] as? String ?? "—"
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

    /// Extract a warranty expiry date string from a `computers list` record.
    func inventoryWarrantyExpires(_ item: [String: Any]) -> String {
        if let purchasing = item["purchasing"] as? [String: Any] {
            if let w = purchasing["warrantyExpirationDate"] as? String, !w.isEmpty { return w }
            if let w = purchasing["warranty_expires"] as? String, !w.isEmpty { return w }
        }
        return item["warranty_expires"] as? String ?? ""
    }

    /// Extract purchase date string from a `computers list` record.
    func inventoryPurchaseDate(_ item: [String: Any]) -> String {
        if let purchasing = item["purchasing"] as? [String: Any] {
            if let d = purchasing["purchaseDate"] as? String, !d.isEmpty { return d }
            if let d = purchasing["purchase_date"] as? String, !d.isEmpty { return d }
        }
        return item["purchase_date"] as? String ?? item["purchaseDate"] as? String ?? ""
    }

    /// Extract a named EA column value from a `computers list` record.
    ///
    /// `computers list` stores extension attributes as `extensionAttributes` in `general`
    /// or as a top-level array. Returns the matched value or `""`.
    func inventoryEAValue(_ item: [String: Any], column: String) -> String {
        // Primary: flat string at the column key (legacy / inventory-csv shape)
        if let v = item[column] as? String { return v }
        // Search extensionAttributes arrays (both top-level and in general)
        let sources: [Any?] = [
            item["extensionAttributes"],
            (item["general"] as? [String: Any])?["extensionAttributes"],
        ]
        for source in sources {
            guard let arr = source as? [[String: Any]] else { continue }
            for ea in arr {
                let name = ea["name"] as? String ?? ""
                guard name == column else { continue }
                if let values = ea["values"] as? [String], let first = values.first {
                    return first
                }
                if let value = ea["value"] as? String { return value }
            }
        }
        return ""
    }

    /// Extract a category name from a jamf-cli category field (string or dict).
    func categoryName(from raw: Any?) -> String {
        switch raw {
        case let s as String where !s.isEmpty: return s
        case let d as [String: Any]: return d["name"] as? String ?? ""
        default: return ""
        }
    }
}
