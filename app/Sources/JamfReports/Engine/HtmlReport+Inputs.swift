import Foundation

// MARK: - HtmlReport+Inputs
//
// What one HTML report reads, loaded once. The sections, the figures at the top and the
// appendix all take their numbers from the same values, so the report cannot say two
// different things about one snapshot.

extension HtmlReport {

    /// `profile-status` and `app-status`: the report window, the totals and one row per
    /// profile or app that errored.
    struct FailureReport {
        let days: Int?
        let totalErrors: Int
        let uniqueItems: Int
        let uniqueDevices: Int
        let failures: [[String: Any]]
    }

    /// One snapshot the report read and the date it stands for.
    struct DataSource {
        let label: String
        let kind: String
        let date: Date?
    }

    /// Every snapshot a report reads. A kind with no snapshot stays empty or nil.
    struct Inputs {
        var security: [[String: Any]] = []
        var overview: [[String: Any]] = []
        var patchStatus: [[String: Any]] = []
        var policyStatus: [[String: Any]] = []
        /// `classic-macos-profiles`: `{id, name}` only, so it counts profiles and nothing more.
        var profileList: [[String: Any]] = []
        var profileStatus: FailureReport?
        var appStatus: FailureReport?
        var deviceCompliance: [[String: Any]] = []
        /// `computers list`, with building and department names filled from their snapshots.
        var computers: [[String: Any]] = []
        var patchFailures: [[String: Any]] = []
        var updateFailures: [[String: Any]] = []
        var auditFindings: [[String: Any]] = []
        var eaRows: [EAResultRow]?
        var fleet: SecurityFleetCounts?
        /// Oldest first, as `SummaryJSONParser.parseDirectory` returns them.
        var summaries: [DailySummary] = []
        /// Catalog object counts, only the kinds the workspace has.
        var catalogCounts: [(label: String, count: Int)] = []
        var sources: [DataSource] = []

        /// Macs in the fleet: the security summary's count, else the overview's.
        var totalDevices: Int = 0
        /// Macs in `computers` with no check-in for `thresholds.stale_device_days` or more.
        var staleMacCount: Int = 0
        /// P0 gaps as the newest daily summary counts them, else from the security snapshot.
        /// One figure for the tile, the attention list and the group headline, so a summary
        /// written by an older build cannot make the top of the report disagree with itself.
        var p0: Int?
    }

    /// Loads what the sections in `sections` and the figures at the top need.
    func loadInputs(for sections: Set<SectionID>) -> Inputs {
        var inputs = Inputs()
        var sources: [DataSource] = []

        func track(_ label: String, _ kind: String) -> URL? {
            guard let url = newestSnapshotURL(kind: kind) else { return nil }
            sources.append(.init(label: label, kind: kind, date: FileManager.snapshotDate(of: url)))
            return url
        }
        func rows(_ label: String, _ kinds: [String]) -> [[String: Any]] {
            for kind in kinds {
                guard let url = newestSnapshotURL(kind: kind),
                      let data = try? Data(contentsOf: url),
                      let parsed = (try? JSONSerialization.jsonObject(with: data))
                        as? [[String: Any]], !parsed.isEmpty
                else { continue }
                sources.append(
                    .init(label: label, kind: kind, date: FileManager.snapshotDate(of: url)))
                return parsed
            }
            return []
        }

        inputs.security = rows("Security report", ["security"])
        inputs.overview = rows("Overview", ["overview"])
        inputs.patchStatus = rows("Patch status", ["patch-status"])
        inputs.policyStatus = rows("Policy status", ["policy-status"])
        inputs.profileList = rows("Configuration profiles", ["classic-macos-profiles"])
        inputs.profileStatus = failureReport(
            rows("Profile status", ["profile-status"]), uniqueKey: "unique_profiles")
        inputs.appStatus = failureReport(
            rows("App status", ["app-status"]), uniqueKey: "unique_apps")
        inputs.deviceCompliance = rows("Device compliance", ["device-compliance"])
        inputs.patchFailures = rows(
            "Patch device failures", ["patch-device-failures", "patch-failures"])
        inputs.updateFailures = Self.updateFailureRows(
            from: rows("Update device failures", ["update-device-failures", "update-failures"]))
        inputs.auditFindings = rows("Audit", ["audit-findings", "audit"])

        let buildings = rows("Buildings", ["buildings"])
        let departments = rows("Departments", ["departments"])
        inputs.computers = resolvingLocationNames(
            rows("Computers", ["computers", "computers-inventory"]),
            buildings: buildings, departments: departments)

        let secSummary = inputs.security.first { $0["section"] as? String == "summary" }
        let secData = secSummary?["data"] as? [String: Any] ?? [:]
        inputs.totalDevices = asInt(secData["total_devices"])
            ?? overviewDeviceCount(inputs.overview)
        inputs.staleMacCount = staleComputers(inputs.computers).count
        inputs.fleet = securityFleet()
        if !(config.securityAgents ?? []).isEmpty,
           let url = track("Extension attribute results", "ea-results"),
           let data = try? Data(contentsOf: url) {
            inputs.eaRows = EAResultRow.decodeSnapshot(data).rows
        }
        inputs.summaries = loadDailySummaries()
        inputs.p0 = inputs.summaries.last?.actionItemsP0 ?? inputs.fleet?.p0
        if let latest = inputs.summaries.last {
            sources.append(.init(
                label: "Daily summaries", kind: "snapshots/summaries", date: latest.parsedDate))
        }
        if sections.contains(.orgInfo) { inputs.catalogCounts = catalogCounts() }
        inputs.sources = sources
        return inputs
    }

    /// The `{summary, failures}` envelope of `profile-status` and `app-status`; nil for any
    /// other shape.
    func failureReport(_ snapshot: [[String: Any]], uniqueKey: String) -> FailureReport? {
        guard let envelope = snapshot.first,
              envelope["summary"] != nil || envelope["failures"] != nil else { return nil }
        let summary = envelope["summary"] as? [String: Any] ?? [:]
        let failures = envelope["failures"] as? [[String: Any]] ?? []
        return FailureReport(
            days: asInt(summary["days"]),
            totalErrors: asInt(summary["total_errors"]) ?? 0,
            uniqueItems: asInt(summary[uniqueKey]) ?? failures.count,
            uniqueDevices: asInt(summary["unique_devices"]) ?? 0,
            failures: failures)
    }

    /// The daily summaries beside the data directory, oldest first.
    func loadDailySummaries() -> [DailySummary] {
        let dir = dataDir.deletingLastPathComponent()
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        return SummaryJSONParser.parseDirectory(dir)
    }

    /// Object counts for the catalog: software titles, EAs, policies, groups and the rest,
    /// the kinds with at least one object.
    private func catalogCounts() -> [(label: String, count: Int)] {
        let kinds: [(String, [String])] = [
            ("Software Titles", ["software-installs"]),
            ("Extension Attributes", ["computer-extension-attributes"]),
            ("Policies", ["policies", "classic-policies"]),
            ("Smart Groups", ["smart-computer-groups", "computer-smart-groups", "smart-groups"]),
            ("Scripts", ["scripts"]),
            ("Packages", ["packages"]),
            ("Categories", ["categories"]),
            ("ADE Instances", [
                "device-enrollment-instances", "classic-device-enrollments", "device-enrollments",
            ]),
            ("Sites", ["sites"]),
            ("Buildings", ["buildings"]),
            ("Departments", ["departments"]),
            ("iOS Profiles", ["classic-ios-profiles", "ios-profiles"]),
        ]
        return kinds.compactMap { label, names in
            let count = loadJSONList(kinds: names).count
            return count > 0 ? (label, count) : nil
        }
    }
}
