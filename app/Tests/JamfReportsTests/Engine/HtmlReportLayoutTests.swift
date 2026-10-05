import Foundation
import PDFKit
import XCTest
@testable import JamfReports

// MARK: - HtmlReportLayoutTests
//
// The condensed HTML report: its order, the header's facts, the figures and their change,
// the attention list and its links, the dashboard's effect on what else is drawn, the
// depth each template sets, and the PDF and print paths. Every workspace is invented.

final class HtmlReportLayoutTests: XCTestCase {

    // MARK: - Fixture

    /// What the invented workspace holds. The defaults are a mid-sized fleet with something
    /// to say in every group.
    struct Fleet {
        var staleMacs = 14
        var freshMacs = 6
        var behindTitles = 12
        var weakTitles = 3
        var profileFailures = 2
        var appFailures = 1
        var patchFailures = 3
        var updateFailures = 2
        var dashboard = false
        var summaries = true
        var yaml = ""
        var eaResults: [[String: Any]] = []
    }

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private static let anchor = GoldenFleetClock.anchorNoon()

    private func write(_ kind: String, _ dataDir: URL, _ rows: [[String: Any]]) throws {
        try GoldenFleetWorkspace.writeSnapshot(
            kind: kind, dataDir: dataDir, at: Self.anchor, rows: rows)
    }

    /// A workspace on disk: `config.yaml`, `jamf-cli-data/` and the daily summaries.
    private func workspace(
        _ fleet: Fleet = Fleet()
    ) throws -> (config: ReportConfig, dataDir: URL) {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        let total = fleet.staleMacs + fleet.freshMacs
        try write("security", dataDir, GoldenFleetWorkspace.securitySummaryPayload(
            total: total, filevault: total - 1, sip: total, firewall: total - 2,
            gatekeeper: total) + [
                ["section": "os_version", "os_version": "26.1", "count": total - 4],
                ["section": "os_version", "os_version": "15.7", "count": 4],
            ])
        let stale = (0..<fleet.staleMacs).map { index -> [String: Any] in
            ["id": "\(index)",
             "general": ["name": "Stale-Mac-\(index)", "lastCheckIn": "2020-01-01"],
             "hardware": ["serialNumber": "STALE\(index)"],
             "userAndLocation": ["buildingId": "1", "departmentId": "7"]]
        }
        let fresh = (0..<fleet.freshMacs).map { index -> [String: Any] in
            ["id": "f\(index)",
             "general": ["name": "Fresh-Mac-\(index)", "lastCheckIn": "2999-01-01"],
             "hardware": ["serialNumber": "FRESH\(index)"],
             "userAndLocation": ["buildingId": "1", "departmentId": "7"]]
        }
        try write("computers", dataDir, stale + fresh)
        try write("buildings", dataDir, [["id": "1", "name": "Main Campus"]])
        try write("departments", dataDir, [["id": "7", "name": "Engineering"]])
        let behind = (0..<fleet.behindTitles).map { index -> [String: Any] in
            let onLatest = index < fleet.weakTitles ? 2 : 8
            return GoldenFleetWorkspace.patchRow(
                id: "\(index)", title: "Title-\(index)", onLatest: onLatest, total: 10)
        }
        try write("patch-status", dataDir, behind)
        try write("policy-status", dataDir, [[
            "summary": ["total_policies": 9, "enabled": 8, "disabled": 1,
                        "config_findings": 2, "warnings": 1],
            "config_findings": [
                ["severity": "warning", "policy": "Policy A", "check": "no_scope",
                 "detail": "No targets in scope", "policy_id": "1"],
                ["severity": "info", "policy": "Policy B", "check": "empty", "detail": "d",
                 "policy_id": "2"],
            ],
        ]])
        try write("classic-macos-profiles", dataDir, (0..<10).map { ["id": $0, "name": "P\($0)"] })
        func failures(_ count: Int, key: String) -> [[String: Any]] {
            [[
                "summary": ["days": 30, "total_errors": count * 3, key: count,
                            "unique_devices": count * 2],
                "failures": (0..<count).map {
                    ["device_type": "computer", "name": "Item-\($0)", "id": "\($0)",
                     "errors": 3, "devices": 2, "last_error": "e", "top_error": "boom"]
                },
                "device_failures": [], "device_pending": [],
            ]]
        }
        try write("profile-status", dataDir, failures(fleet.profileFailures,
                                                     key: "unique_profiles"))
        try write("app-status", dataDir, failures(fleet.appFailures, key: "unique_apps"))
        try write("patch-device-failures", dataDir, (0..<fleet.patchFailures).map {
            ["policy": "Zoom", "device": "Failing-\($0)", "serial": "F\($0)",
             "status_date": "2026-03-0\($0 + 1)"]
        })
        try write("update-device-failures", dataDir, [[
            "error_devices": NSNull(),
            "failed_plans": (0..<fleet.updateFailures).map {
                ["name": "Plan-\($0)", "serial": "P\($0)", "version": "26.1",
                 "updated": "2026-03-1\($0)"]
            },
        ]])
        try write("audit", dataDir, [
            ["name": "Stale check-in", "category": "compliance", "severity": "WARNING",
             "affected": 4, "recommendation": "Investigate"],
        ])
        try write("device-compliance", dataDir, [])
        if !fleet.eaResults.isEmpty { try write("ea-results", dataDir, fleet.eaResults) }
        if fleet.dashboard {
            let dir = dataDir.appendingPathComponent("dashboard", isDirectory: true)
            try GoldenFleetWorkspace.writeRaw(
                "<!DOCTYPE html><html><head></head><body>FLEET</body></html>",
                to: dir.appendingPathComponent(
                    "dashboard_\(GoldenFleetClock.stamp(Self.anchor)).html"))
        }
        try fleet.yaml.write(
            to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        if fleet.summaries { try writeSummaries(root) }
        return (try ConfigLoader.loadFromString(fleet.yaml).withDefaults(), dataDir)
    }

    /// Two daily summaries eight days apart, so the lookback finds the earlier one. Changes:
    /// score +2.0 (better), P0 +2 (worse), patch none, macOS +1.5 (better), stale +4
    /// (worse), compliance -5.0 (worse).
    private func writeSummaries(_ root: URL) throws {
        let dir = root.appendingPathComponent("snapshots/summaries", isDirectory: true)
        let today = Self.anchor
        let earlier = Calendar.current.date(byAdding: .day, value: -8, to: today)!
        func summary(
            _ date: Date, score: Double, p0: Int, patch: Double, os: Double, stale: Int,
            compliance: Double, basis: String? = DailySummary.deviceWeightedPatchBasis
        ) -> DailySummary {
            DailySummary(
                date: GoldenFleetClock.daySummaryString(date), totalDevices: 20,
                fileVaultPct: 95, compliancePct: compliance, staleCount: stale, osCurrentPct: os,
                crowdstrikePct: nil, patchPct: patch, source: "jamf-cli",
                provenance: nil, securityScore: score, actionItemsP0: p0,
                complianceIsProxy: true, patchPctBasis: basis)
        }
        let all = [
            summary(earlier, score: 80, p0: 10, patch: 70, os: 60, stale: 5, compliance: 90),
            summary(today, score: 82, p0: 12, patch: 70, os: 61.5, stale: 9, compliance: 85),
        ]
        for item in all {
            try GoldenFleetWorkspace.writeJSON(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)),
                to: dir.appendingPathComponent("summary_\(item.date).json"))
        }
    }

    private func render(
        _ fleet: Fleet = Fleet(),
        sections: [SectionID]? = nil,
        profile: String = "prod",
        configure: (inout HtmlReport) -> Void = { _ in }
    ) async throws -> String {
        let (config, dataDir) = try workspace(fleet)
        var report = HtmlReport(config: config, dataDir: dataDir)
        report.jamfCLIVersion = "1.31.1"
        configure(&report)
        let out = dataDir.deletingLastPathComponent().appendingPathComponent("report.html")
        try await report.generate(outputURL: out, profileName: profile, sections: sections)
        return try String(contentsOf: out, encoding: .utf8)
    }

    // MARK: - Helpers

    private func position(_ marker: String, in html: String) throws -> String.Index {
        try XCTUnwrap(html.range(of: marker), "no \(marker)").lowerBound
    }

    private func ids(in html: String) -> Set<String> {
        Set(matches(#"\sid="([^"]+)""#, in: html))
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The `<details ...>` opening tags outside the dashboard's own srcdoc, which is escaped.
    private func detailsTags(in html: String) -> [String] {
        matches(#"(<details[^>]*>)"#, in: html)
    }

    private func main(of html: String) throws -> String {
        let start = try XCTUnwrap(html.range(of: "<main id=\"main-content\">"))
        let end = try XCTUnwrap(html.range(of: "</main>"))
        return String(html[start.upperBound..<end.lowerBound])
    }

    private func isOpen(_ group: String, in html: String) -> Bool {
        guard let range = html.range(of: "<details class=\"group\" id=\"\(group)\"") else {
            return false
        }
        let tail = html[range.upperBound...]
        let end = tail.firstIndex(of: ">") ?? tail.endIndex
        return tail[..<end].contains("open")
    }

    // MARK: - Order

    func testTheReportReadsHeaderFiguresAttentionDashboardGroupsAppendix() async throws {
        let html = try await render(Fleet(dashboard: true))
        let order = [
            "<header>", "id=\"at-a-glance\"", "id=\"needs-attention\"", "id=\"jamf-dashboard\"",
            "id=\"grp-security\"", "id=\"grp-patching\"", "id=\"grp-devices\"",
            "id=\"grp-policies\"", "id=\"grp-trends\"", "id=\"grp-failures\"",
            "id=\"grp-breakdowns\"", "id=\"audit-appendix\"",
        ]
        var previous = html.startIndex
        for marker in order {
            let at = try position(marker, in: html)
            XCTAssertGreaterThan(at, previous, "\(marker) is out of order")
            previous = at
        }
    }

    /// A template's list says what is in the report, not where: a reversed list renders the
    /// same page.
    func testTheOrderOfATemplatesListDoesNotChangeThePage() async throws {
        let forward = try await render(sections: FullInstanceTemplate().htmlSections)
        let backward = try await render(sections: FullInstanceTemplate().htmlSections.reversed())
        let idsForward = try ids(in: main(of: forward))
        XCTAssertEqual(idsForward, try ids(in: main(of: backward)))
        let at = try position(#"id="at-a-glance""#, in: backward)
        XCTAssertLessThan(at, try position(#"id="grp-security""#, in: backward))
    }

    // MARK: - Header

    func testTheHeaderFillsProfileVersionAndMacCountFromWhatTheAppHas() async throws {
        let html = try await render(
            Fleet(yaml: "jamf_cli:\n  profile: \"acme-prod\"\n"), profile: ""
        ) { $0.templateName = "Full Instance Report" }
        let header = try XCTUnwrap(html.range(of: "<header>")).lowerBound
        let end = try XCTUnwrap(html.range(of: "</header>")).lowerBound
        let text = String(html[header..<end])
        XCTAssertTrue(text.contains("Profile: <strong>acme-prod</strong>"), text)
        XCTAssertTrue(text.contains("jamf-cli: <strong>1.31.1</strong>"), text)
        XCTAssertTrue(text.contains("Macs: <strong>20</strong>"), text)
        XCTAssertTrue(text.contains("Template: <strong>Full Instance Report</strong>"), text)
        XCTAssertTrue(text.contains("Data collected:"), text)
        XCTAssertTrue(text.contains("Reporting week:"), text)
        XCTAssertFalse(text.contains("—"), "a fact the app has is never a dash")
        XCTAssertFalse(text.contains("<h1></h1>"), "an unnamed organisation still has a title")
    }

    func testAProfileNamePassedInWinsOverTheConfigAndLineCountComesFromComputers() async throws {
        let html = try await render(
            Fleet(yaml: "jamf_cli:\n  profile: \"from-config\"\n"), profile: "from-caller")
        XCTAssertTrue(html.contains("Profile: <strong>from-caller</strong>"))
        XCTAssertFalse(html.contains("from-config"))
    }

    /// With no installed jamf-cli to ask, the version the newest summary recorded stands in.
    func testTheHeaderTakesTheJamfCLIVersionFromTheSummaryWhenNoneIsInstalled() async throws {
        let (config, dataDir) = try workspace()
        let dir = dataDir.deletingLastPathComponent()
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        let today = GoldenFleetClock.daySummaryString(Self.anchor)
        let url = dir.appendingPathComponent("summary_\(today).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        json["provenance"] = [
            "runID": "r", "generatedAt": "2026-10-01T00:00:00.000Z", "profile": "p",
            "jamfCLIVersion": "jamf-cli version 1.29.0 (abc123)", "operatorUserHost": "u@h",
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let out = dir.appendingPathComponent("report.html")
        try await HtmlReport(config: config, dataDir: dataDir).generate(outputURL: out)
        let html = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(html.contains("jamf-cli: <strong>1.29.0</strong>"), html)
    }

    func testAFactTheAppLacksIsLeftOutNotPrintedAsADash() async throws {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let out = root.appendingPathComponent("report.html")
        try await HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
            .generate(outputURL: out)
        let html = try String(contentsOf: out, encoding: .utf8)
        let header = try XCTUnwrap(html.range(of: "<header>")).lowerBound
        let end = try XCTUnwrap(html.range(of: "</header>")).lowerBound
        let text = String(html[header..<end])
        XCTAssertFalse(text.contains("—"))
        XCTAssertFalse(text.contains("Profile:"))
        XCTAssertFalse(text.contains("jamf-cli:"))
        XCTAssertFalse(text.contains("Macs:"))
    }

    func testVersionNumberIsTheNumberInTheText() {
        XCTAssertEqual(HtmlReport.versionNumber(in: "jamf-cli version 1.31.1 (abc)"), "1.31.1")
        XCTAssertEqual(HtmlReport.versionNumber(in: "1.30.0-rc1"), "1.30.0-rc1")
        XCTAssertEqual(HtmlReport.versionNumber(in: "dev build"), "dev build")
        XCTAssertNil(HtmlReport.versionNumber(in: "  \n"))
    }

    // MARK: - At a glance

    private func tile(
        _ label: String, in html: String
    ) throws -> (value: String, change: String, cls: String) {
        let blocks = html.components(separatedBy: "<div class=\"glance-tile\">").dropFirst()
        let block = try XCTUnwrap(blocks.first { $0.contains(">\(label)</div>") }, "no \(label)")
        let value = try XCTUnwrap(matches(#"glance-value">([^<]*)<"#, in: block).first)
        let cls = try XCTUnwrap(matches(#"class="glance-change ([a-z]+)""#, in: block).first)
        let change = try XCTUnwrap(
            matches(#"class="glance-change [a-z]+">([^<]*)<"#, in: block).first)
        return (value, change, cls)
    }

    func testTheSixFiguresShowTheirChangeWorkedAsTheTrendsScreenWordsIt() async throws {
        let html = try await render()
        let score = try tile("Security score", in: html)
        XCTAssertEqual(score.value, "82.0")
        XCTAssertEqual(score.change, "+2.0 pp · better")
        XCTAssertEqual(score.cls, "better")

        let p0 = try tile("P0 security gaps", in: html)
        XCTAssertEqual(p0.value, "12")
        XCTAssertEqual(p0.change, "+2 · worse", "a count is a signed integer; more gaps is worse")
        XCTAssertEqual(p0.cls, "worse")

        let patch = try tile("Patch compliance", in: html)
        XCTAssertEqual(patch.change, "No change")
        XCTAssertEqual(patch.cls, "flat")

        let os = try tile("On current macOS", in: html)
        XCTAssertEqual(os.value, "61.5%")
        XCTAssertEqual(os.change, "+1.5 pp · better")

        let stale = try tile("Stale Macs (30+ days)", in: html)
        XCTAssertEqual(stale.value, "9")
        XCTAssertEqual(stale.change, "+4 · worse", "more stale Macs is worse")

        let compliance = try tile("Compliance (4-control proxy)", in: html)
        XCTAssertEqual(compliance.value, "85.0%")
        XCTAssertEqual(compliance.change, "-5.0 pp · worse")
        XCTAssertEqual(html.components(separatedBy: "<div class=\"glance-tile\">").count - 1, 6)
    }

    func testTheCaptionNamesTheDateTheChangesCompareWith() async throws {
        let html = try await render()
        let today = GoldenFleetClock.daySummaryString(Self.anchor)
        let earlier = GoldenFleetClock.daySummaryString(
            Calendar.current.date(byAdding: .day, value: -8, to: Self.anchor)!)
        XCTAssertTrue(html.contains("As of \(today). Changes compare with \(earlier)."))
        XCTAssertTrue(html.contains("Reporting week: <strong>\(earlier) to \(today)</strong>"))
    }

    /// A summary written before the device-weighted patch definition cannot be compared with
    /// one written after it: the difference would be the definition changing.
    func testAFigureMeasuredDifferentlyShowsNoChange() async throws {
        let (config, dataDir) = try workspace()
        let dir = dataDir.deletingLastPathComponent()
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        let earlier = GoldenFleetClock.daySummaryString(
            Calendar.current.date(byAdding: .day, value: -8, to: Self.anchor)!)
        let url = dir.appendingPathComponent("summary_\(earlier).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "patchPctBasis")
        json["patchPct"] = 40.0
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let out = dir.appendingPathComponent("report.html")
        try await HtmlReport(config: config, dataDir: dataDir).generate(outputURL: out)
        let html = try String(contentsOf: out, encoding: .utf8)
        let patch = try tile("Patch compliance", in: html)
        XCTAssertEqual(patch.change, "Not comparable with the earlier figure")
        XCTAssertEqual(patch.cls, "none")
    }

    /// A score built from different inputs (`securityScoreBasis`) is not compared either.
    func testAScoreFromDifferentInputsShowsNoChange() async throws {
        let (config, dataDir) = try workspace()
        let dir = dataDir.deletingLastPathComponent()
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        let earlier = GoldenFleetClock.daySummaryString(
            Calendar.current.date(byAdding: .day, value: -8, to: Self.anchor)!)
        let url = dir.appendingPathComponent("summary_\(earlier).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        json["securityScoreBasis"] = "fileVault,sip,firewall,edrAgent,mscp"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let out = dir.appendingPathComponent("report.html")
        try await HtmlReport(config: config, dataDir: dataDir).generate(outputURL: out)
        let html = try String(contentsOf: out, encoding: .utf8)
        let score = try tile("Security score", in: html)
        XCTAssertEqual(score.change, "Not comparable with the earlier figure")
        XCTAssertEqual(score.cls, "none")
    }

    func testWithoutADailySummaryTheFiguresAreLeftOutAndListed() async throws {
        let html = try await render(Fleet(summaries: false))
        XCTAssertFalse(html.contains("id=\"at-a-glance\""))
        XCTAssertTrue(html.contains(
            "At a glance — no daily summary yet; a collect writes one"))
    }

    func testAFigureTheSummaryLacksIsNotDrawnAsADash() async throws {
        let (config, dataDir) = try workspace()
        let dir = dataDir.deletingLastPathComponent()
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        let today = GoldenFleetClock.daySummaryString(Self.anchor)
        let url = dir.appendingPathComponent("summary_\(today).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "securityScore")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let out = dir.appendingPathComponent("report.html")
        try await HtmlReport(config: config, dataDir: dataDir).generate(outputURL: out)
        let html = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(html.components(separatedBy: "<div class=\"glance-tile\">").count - 1, 5)
        XCTAssertTrue(html.contains(
            "At a glance: Security score — the daily summary has no value for it"))
    }

    // MARK: - Needs attention

    private func attention(_ html: String) -> [(text: String, href: String?)] {
        guard let start = html.range(of: "<ul class=\"attention-list\">"),
              let end = html.range(of: "</ul>", range: start.upperBound..<html.endIndex)
        else { return [] }
        let list = String(html[start.upperBound..<end.lowerBound])
        return list.components(separatedBy: "<li>").dropFirst().map { item in
            let href = matches(##"href="#([^"]+)""##, in: item).first
            let text = item
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text, href)
        }
    }

    func testEveryRuleFiresAboveZeroAndLinksToAnExistingAnchor() async throws {
        let agents = """
        security_agents:
          - name: "Falcon"
            column: "Falcon State"
            connected_value: "connected"
        """
        let html = try await render(Fleet(yaml: agents, eaResults: [
            ["computer_id": "1", "ea_name": "Falcon State", "value": "connected"],
            ["computer_id": "2", "ea_name": "Falcon State", "value": "connected"],
            ["computer_id": "3", "ea_name": "Falcon State", "value": "not installed"],
        ]))
        let items = attention(html)
        let texts = items.map(\.text)
        // The figure the "At a glance" tile shows (the summary's), not a second count.
        XCTAssertTrue(texts.contains("9 Macs have not checked in for 30 days or more."), "\(texts)")
        XCTAssertTrue(texts.contains {
            $0 == "12 P0 security gaps need action: FileVault, SIP or Firewall is off."
        }, "\(texts)")
        XCTAssertTrue(texts.contains("3 patch titles are under 50% on their latest version."))
        XCTAssertTrue(texts.contains("2 configuration profiles are failing to install on devices."))
        XCTAssertTrue(texts.contains("1 app is failing to install on devices."))
        XCTAssertTrue(texts.contains("5 devices have failed patch or software update runs."))
        XCTAssertTrue(texts.contains("Security agents are not on every Mac: Falcon 10.0%."),
                      "\(texts)")
        XCTAssertEqual(items.count, 7)
        let known = ids(in: html)
        for item in items {
            let href = try XCTUnwrap(item.href, "\(item.text) has no link")
            XCTAssertTrue(known.contains(href), "\(item.text) links to missing #\(href)")
        }
    }

    func testARuleWithNothingToCountIsAbsent() async throws {
        let html = try await render(Fleet(
            staleMacs: 0, behindTitles: 4, weakTitles: 0, profileFailures: 0, appFailures: 0,
            patchFailures: 0, updateFailures: 0, summaries: false))
        let texts = attention(html).map(\.text)
        XCTAssertFalse(texts.contains { $0.contains("checked in") }, "\(texts)")
        XCTAssertFalse(texts.contains { $0.contains("patch titles") })
        XCTAssertFalse(texts.contains { $0.contains("configuration profile") })
        XCTAssertFalse(texts.contains { $0.contains("app is") || $0.contains("apps are") })
        XCTAssertFalse(texts.contains { $0.contains("failed patch") })
    }

    func testWhenNothingFiresTheReportSaysSo() async throws {
        var fleet = Fleet(
            staleMacs: 0, behindTitles: 0, weakTitles: 0, profileFailures: 0, appFailures: 0,
            patchFailures: 0, updateFailures: 0)
        fleet.summaries = false
        let (config, dataDir) = try workspace(fleet)
        // A fleet with no gap: every control on.
        try write("security", dataDir, GoldenFleetWorkspace.securitySummaryPayload(
            total: 6, filevault: 6, sip: 6, firewall: 6, gatekeeper: 6))
        let out = dataDir.deletingLastPathComponent().appendingPathComponent("r.html")
        try await HtmlReport(config: config, dataDir: dataDir).generate(outputURL: out)
        let html = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(html.contains("Nothing needs attention right now."))
        XCTAssertFalse(html.contains("<ul class=\"attention-list\">"))
    }

    /// The Executive report has no detail groups, so its lines are plain sentences with no
    /// link to follow, never a link to nothing.
    func testWithoutDetailGroupsTheAttentionLinesCarryNoLinks() async throws {
        let html = try await render(sections: ExecutiveTemplate().htmlSections)
        let items = attention(html)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.href == nil }, "\(items)")
        let known = ids(in: html)
        for href in matches(##"href="#([^"]+)""##, in: html)
        where href != "main-content" {
            XCTAssertTrue(known.contains(href), "#\(href) has no target")
        }
    }

    // MARK: - Dashboard

    func testWithTheDashboardInTheReportItsDuplicatesLeaveAndAreListed() async throws {
        let html = try await render(Fleet(dashboard: true))
        XCTAssertTrue(html.contains("id=\"jrc-dashboard-frame\""))
        XCTAssertFalse(html.contains("id=\"os-chart\""), "the dashboard has the OS distribution")
        XCTAssertFalse(html.contains("id=\"audit-evidence\""), "and the audit findings")
        XCTAssertFalse(html.contains("id=\"catalog-overview\""), "and the environment counts")
        let reason = "shown in the Jamf fleet dashboard above"
        XCTAssertTrue(html.contains("OS version distribution — \(reason)"))
        XCTAssertTrue(html.contains("Audit findings — \(reason)"))
        XCTAssertTrue(html.contains("Catalog overview — \(reason)"))
        XCTAssertTrue(html.contains("id=\"patch-chart\""), "the dashboard has no patch titles")
    }

    func testWithoutTheDashboardOurSectionsAreThere() async throws {
        let html = try await render(Fleet(dashboard: false))
        XCTAssertFalse(html.contains("id=\"jrc-dashboard-frame\""))
        XCTAssertTrue(html.contains("id=\"os-chart\""))
        XCTAssertTrue(html.contains("id=\"audit-evidence\""))
        XCTAssertTrue(html.contains("id=\"catalog-overview\""))
        XCTAssertTrue(html.contains(
            "Jamf fleet dashboard — not collected yet; with jamf-cli 1.31.0 or later"))
    }

    /// A template that does not list the dashboard does not embed it, so nothing it repeats
    /// may leave.
    func testATemplateWithoutTheDashboardKeepsTheSectionsTheDashboardRepeats() async throws {
        let html = try await render(
            Fleet(dashboard: true), sections: AssetTemplate().htmlSections)
        XCTAssertFalse(html.contains("id=\"jrc-dashboard-frame\""))
        XCTAssertTrue(html.contains("id=\"catalog-overview\""))
    }

    // MARK: - No device inventory

    /// A report is forwarded: no template carries a Mac-by-Mac inventory. The fixture's fresh
    /// Macs are on no action list, so their names and serials must not appear at all.
    func testNoTemplateCarriesTheFullDeviceInventory() async throws {
        for template in TemplateResolver.allTemplates {
            let html = try await render(sections: template.htmlSections)
            XCTAssertFalse(html.contains("asset-map"), template.identifier)
            XCTAssertFalse(html.contains("Fresh-Mac-"), template.identifier)
            XCTAssertFalse(html.contains("FRESH0"), template.identifier)
        }
        XCTAssertFalse(SectionID.allCases.map(\.rawValue).contains("asset_map"))
    }

    // MARK: - Capped lists

    func testALongListShowsTenRowsAndKeepsTheRestBehindShowAll() async throws {
        let html = try await render(Fleet(staleMacs: 30, freshMacs: 2))
        let block = try XCTUnwrap(html.range(of: "id=\"intervention-list\""))
        let tail = String(html[block.lowerBound...])
        let (shown, rest) = HtmlSectionTests.splitAtShowAll(tail)
        XCTAssertEqual(HtmlSectionTests.bodyRows(shown), 10)
        XCTAssertTrue(tail.contains("<summary>Show all 30</summary>"))
        let behind = String(rest.prefix(upTo: rest.range(of: "</details>")?.lowerBound
                                        ?? rest.endIndex))
        XCTAssertEqual(HtmlSectionTests.bodyRows(behind), 20)
    }

    // MARK: - Empty sections

    func testEmptySectionsAreOmittedAndListedWithTheirReasons() async throws {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let out = root.appendingPathComponent("report.html")
        try await HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
            .generate(outputURL: out)
        let html = try String(contentsOf: out, encoding: .utf8)
        XCTAssertFalse(html.contains("id=\"grp-"), "no group is drawn around nothing")
        XCTAssertFalse(html.contains("empty-section"))
        for line in [
            "Protect alerts — not configured: protect.enabled is off in config.yaml",
            "Exception list — not configured: no exceptions: block in config.yaml",
            "Security agent health — not configured: no security_agents in config.yaml",
            "Purchase cohorts — no purchase dates in the inventory",
            "Cleanup analysis — no classic-policies snapshot",
        ] {
            XCTAssertTrue(html.contains(line), "appendix lacks: \(line)")
        }
        XCTAssertTrue(html.contains(
            "Device inventory — full device lists are in the workbook"))
    }

    func testAGroupWithNothingToShowIsNotDrawn() async throws {
        let html = try await render(Fleet(
            staleMacs: 0, profileFailures: 0, appFailures: 0, patchFailures: 0, updateFailures: 0))
        XCTAssertFalse(html.contains("id=\"grp-devices\""))
        XCTAssertFalse(html.contains("id=\"grp-failures\""))
    }

    // MARK: - Group summaries

    func testEachGroupSummaryCarriesItsHeadlineNumbers() async throws {
        let html = try await render(Fleet(behindTitles: 12, weakTitles: 3))
        func summary(_ group: String) throws -> String {
            let start = try XCTUnwrap(html.range(of: "id=\"grp-\(group)\""))
            let open = try XCTUnwrap(html.range(
                of: "<summary>", range: start.upperBound..<html.endIndex))
            let close = try XCTUnwrap(html.range(
                of: "</summary>", range: open.upperBound..<html.endIndex))
            return String(html[open.upperBound..<close.lowerBound])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        XCTAssertEqual(try summary("patching"), "Patching — 12 titles behind · 3 under 50%")
        XCTAssertEqual(try summary("failures"), "Recent failures — 3 patch · 2 update failures")
        XCTAssertTrue(
            try summary("devices").hasPrefix("Devices needing intervention — 14 Macs idle"))
        XCTAssertTrue(try summary("security").hasPrefix("Security and compliance — 12 P0 gaps"))
        XCTAssertTrue(try summary("policies").contains("2 policy findings"))
        XCTAssertTrue(try summary("policies").contains("2 profiles failing"))
    }

    /// Healthy profiles are counted, not listed: ten profiles, two failing.
    func testProfilesListOnlyTheFailingOnesAndCountTheRest() async throws {
        let html = try await render()
        let block = try XCTUnwrap(html.range(of: "id=\"profile-status\""))
        let text = String(html[block.lowerBound...].prefix(2500))
        XCTAssertTrue(text.contains("2 configuration profiles reported install errors"), text)
        XCTAssertTrue(text.contains("(8 of 10 had none)"), text)
        XCTAssertFalse(text.contains("<td>P3</td>"), "a healthy profile is not listed")
    }

    // MARK: - Depth by template

    func testTemplatesSetWhichGroupsStartOpen() async throws {
        let full = try await render(sections: FullInstanceTemplate().htmlSections)
        for group in ["security", "patching", "devices", "policies", "trends", "failures"] {
            XCTAssertFalse(isOpen("grp-\(group)", in: full), "full instance: \(group) is collapsed")
        }
        let operational = try await render(sections: OperationalTemplate().htmlSections) {
            $0.openSections = Set(OperationalTemplate().htmlOpenSections)
        }
        XCTAssertTrue(isOpen("grp-devices", in: operational))
        XCTAssertTrue(isOpen("grp-failures", in: operational))
        XCTAssertTrue(isOpen("grp-patching", in: operational))
        XCTAssertFalse(isOpen("grp-policies", in: operational))
        XCTAssertFalse(isOpen("grp-security", in: operational))
        let compliance = try await render(sections: ComplianceTemplate().htmlSections) {
            $0.openSections = Set(ComplianceTemplate().htmlOpenSections)
        }
        XCTAssertTrue(isOpen("grp-security", in: compliance))
        XCTAssertFalse(isOpen("grp-devices", in: compliance))
    }

    func testTheExecutiveTemplateHasNoDetailSection() async throws {
        let html = try await render(
            Fleet(dashboard: true), sections: ExecutiveTemplate().htmlSections)
        XCTAssertFalse(html.contains("id=\"grp-"))
        XCTAssertTrue(html.contains("id=\"at-a-glance\""))
        XCTAssertTrue(html.contains("id=\"needs-attention\""))
        XCTAssertTrue(html.contains("id=\"jamf-dashboard\""))
        XCTAssertTrue(html.contains("id=\"audit-appendix\""))
        XCTAssertFalse(html.contains("Stale-Mac-0"), "no Mac is named")
    }

    // MARK: - Controls, print and the PDF

    func testTheExpandAndCollapseButtonsAndThePrintHandlersAreThere() async throws {
        let html = try await render()
        XCTAssertTrue(html.contains("data-action=\"expand\">Expand all</button>"))
        XCTAssertTrue(html.contains("data-action=\"collapse\">Collapse all</button>"))
        XCTAssertTrue(html.contains("addEventListener('beforeprint'"))
        XCTAssertTrue(html.contains("addEventListener('afterprint'"))
        let print = try XCTUnwrap(html.range(of: "@media print"))
        XCTAssertTrue(html[print.upperBound...].contains(".controls"))
        XCTAssertTrue(html.contains("function jrReveal"), "a link opens the groups around it")
        XCTAssertTrue(html.contains("onclick=\"toggleTheme()\""), "the theme switch stays")
    }

    /// The PDF renderer runs no script, so the markup itself has every group open.
    func testThePDFRenderHasEveryDetailsOpenAndNoButtons() async throws {
        let html = try await render(Fleet(dashboard: true)) { $0.expandAll = true }
        let tags = detailsTags(in: html)
        XCTAssertGreaterThan(tags.count, 8, "groups, appendix, show-all and the daily table")
        for tag in tags {
            XCTAssertTrue(tag.contains(" open"), "\(tag) is closed in the PDF render")
        }
        XCTAssertFalse(html.contains("class=\"controls\""))
        XCTAssertFalse(html.contains("data-action="), "no buttons that need a script")
    }

    func testTheScreenRenderLeavesTheNestedBlocksClosed() async throws {
        let html = try await render()
        let closed = detailsTags(in: html).filter { !$0.contains(" open") }
        XCTAssertGreaterThan(closed.count, 6)
        XCTAssertTrue(detailsTags(in: html).contains {
            $0.contains("show-all") && !$0.contains(" open")
        })
    }

    /// End to end through the real exporter. `WKWebView.createPDF` is given one letter-sized
    /// rect, so the PDF holds the top of the report only (found while writing this test, and
    /// not changed here): with the new order that is the header, the figures and the attention
    /// list. The PDF render has no buttons to print.
    @MainActor
    func testThePDFOpensWithTheFiguresAndHasNoButtons() async throws {
        let (config, dataDir) = try workspace(Fleet(staleMacs: 30, freshMacs: 2))
        let out = dataDir.deletingLastPathComponent().appendingPathComponent("r.pdf")
        try await ReportEngine.generatePDF(
            config: config, dataDir: dataDir, outputURL: out, profileName: "prod",
            template: FullInstanceTemplate(), locateJamfCLI: { nil })
        let document = try XCTUnwrap(PDFDocument(url: out))
        let text = document.string ?? ""
        XCTAssertTrue(text.contains("At a glance"), String(text.prefix(300)))
        XCTAssertTrue(text.contains("Needs attention"))
        XCTAssertTrue(text.contains("Profile:"))
        XCTAssertFalse(text.contains("Expand all"))
    }

    // MARK: - Appendix

    func testTheAppendixListsSourcesDefinitionsPolicyAndOmissions() async throws {
        let html = try await render(Fleet(yaml: """
        security_policy:
          controls:
            sip: warning
            firewall: ignore
          filevault_off_hardware_encrypted: warning
        thresholds:
          stale_device_days: 45
        """))
        let appendix = try XCTUnwrap(html.range(of: "id=\"audit-appendix\""))
        let text = String(html[appendix.lowerBound...])
        XCTAssertTrue(text.contains("Security report (security)"))
        XCTAssertTrue(text.contains("Patch status (patch-status)"))
        XCTAssertTrue(text.contains("Daily summaries (snapshots/summaries)"))
        XCTAssertTrue(text.contains("no check-in for 45 days or more"))
        // Firewall is not counted, so it is not a factor; the check-in label names the window.
        XCTAssertTrue(text.contains(
            "Factors and weights: FileVault 15, SIP 10, Gatekeeper 5, "
                + "Secure Boot at full security 5, Bootstrap token escrowed 5, "), text)
        XCTAssertTrue(text.contains("Checked in within 45 days 5"))
        XCTAssertFalse(text.contains("Firewall 10"))
        XCTAssertTrue(text.contains("<td>Score factors</td><td>Defaults</td>"))
        XCTAssertTrue(text.contains("<td>System Integrity Protection</td><td>Warning</td>"))
        XCTAssertTrue(text.contains("<td>Firewall</td><td>Not counted</td>"))
        XCTAssertTrue(text.contains(
            "<td>FileVault off on a hardware-encrypted Mac</td><td>Warning</td>"))
        XCTAssertTrue(text.contains("Device inventory — full device lists are in the workbook"))
    }

    // MARK: - Escaping

    func testEveryNewTextIsEscaped() async throws {
        let evil = "<script>alert(1)</script>"
        let html = try await render(Fleet(yaml: """
        branding:
          org_name: "\(evil)"
        compliance:
          baseline_label: "\(evil)"
        security_agents:
          - name: "\(evil)"
            column: "\(evil)"
            connected_value: "x"
        """, eaResults: [
            ["computer_id": "1", "ea_name": evil, "value": "x"],
        ]), profile: evil) {
            $0.templateName = evil
            $0.jamfCLIVersion = "1.31.1 \(evil)"
        }
        XCTAssertFalse(html.contains("<script>alert(1)"), "unescaped script in the report")
        XCTAssertFalse(html.contains("alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    // MARK: - Size

    /// The report's own content for the default fleet (20 Macs, 14 of them stale). Measured
    /// on this fixture: 24,007 bytes of content with the dashboard and 25,632 bytes for the
    /// whole Executive report; the bounds leave a quarter to a third of headroom, so a table
    /// or a repeated section coming back fails here.
    func testTheReportsOwnContentStaysWithinItsMeasuredSize() async throws {
        let full = try await render(Fleet(dashboard: true))
        let content = try main(of: full).utf8.count
        XCTAssertLessThan(content, 30_000, "main content grew to \(content) bytes")
        let executive = try await render(
            Fleet(dashboard: true), sections: ExecutiveTemplate().htmlSections)
        XCTAssertLessThan(executive.utf8.count, 35_000, "Executive report: \(executive.utf8.count)")
    }
}
