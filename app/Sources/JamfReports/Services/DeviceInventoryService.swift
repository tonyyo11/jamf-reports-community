import Foundation

/// Read-only loader for the Devices screen.
///
/// All file reads are constrained to `<workspaces-root>/<profile>/`. The service
/// never shells out; it uses current inventory CSV output plus cached jamf-cli
/// JSON snapshots that the Python tool already writes.
enum DeviceInventoryService {

    fileprivate struct ConfigHints {
        var jamfCLIDataDir: URL
        var outputDir: URL
        var historicalCSVDir: URL
        /// `thresholds.stale_device_days` (default 30). Drives `record.stale`
        /// so the Devices/Outreach screens agree with the Overview/Fleet tiles
        /// and the summary writer at any configured threshold.
        var staleDeviceDays: Int
    }

    static func load(profile: String, demoMode: Bool) -> DeviceInventorySnapshot {
        if demoMode { return DemoData.deviceSnapshot }
        guard let root = validatedWorkspaceRoot(profile: profile) else {
            return emptySnapshot(
                warning: "Workspace is missing or not contained in "
                    + "\(WorkspaceRootStore.displayPath(profile: profile))/"
            )
        }

        var warnings: [String] = []
        let config = loadConfigHints(root: root, warnings: &warnings)
        var merger = DeviceRecordMerger()
        var sourceFiles: [String] = []
        var newestSourceDate: Date?

        if let csv = resolveInventoryCSV(config: config, root: root, now: Date()) {
            if csv.isCurrent {
                loadCSVInventory(csv.url, root: root, into: &merger, warnings: &warnings,
                                 staleThresholdDays: config.staleDeviceDays)
                sourceFiles.append(displayPath(csv.url, root: root))
                newestSourceDate = maxDate(newestSourceDate, modificationDate(csv.url))
            } else {
                warnings.append(agedInventoryCSVWarning(csv, root: root, config: config))
            }
        }

        if let computers = latestCachedJSON(
            dataDir: config.jamfCLIDataDir,
            names: ["computers-list", "computers_list", "computers"],
            root: root
        ) {
            loadComputersList(computers, root: root, into: &merger, warnings: &warnings,
                              staleThresholdDays: config.staleDeviceDays)
            sourceFiles.append(displayPath(computers, root: root))
            newestSourceDate = maxDate(newestSourceDate, modificationDate(computers))
        }

        if let compliance = latestCachedJSON(
            dataDir: config.jamfCLIDataDir,
            names: ["device-compliance", "device_compliance"],
            root: root
        ) {
            loadDeviceCompliance(compliance, root: root, into: &merger, warnings: &warnings,
                                 staleThresholdDays: config.staleDeviceDays)
            sourceFiles.append(displayPath(compliance, root: root))
            newestSourceDate = maxDate(newestSourceDate, modificationDate(compliance))
        }

        if let patchFailures = latestCachedJSON(
            dataDir: config.jamfCLIDataDir,
            names: ["patch-device-failures", "patch_device_failures"],
            root: root
        ) {
            loadPatchFailures(patchFailures, root: root, into: &merger, warnings: &warnings)
            sourceFiles.append(displayPath(patchFailures, root: root))
            newestSourceDate = maxDate(newestSourceDate, modificationDate(patchFailures))
        }

        let patchTitles = loadPatchTitles(
            dataDir: config.jamfCLIDataDir,
            root: root,
            sourceFiles: &sourceFiles,
            newestSourceDate: &newestSourceDate,
            warnings: &warnings
        )

        let devices = merger.records.sorted { lhs, rhs in
            if lhs.risk != rhs.risk { return riskRank(lhs.risk) > riskRank(rhs.risk) }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        let uniqueSources = sourceFiles.reduce(into: [String]()) { acc, item in
            if !acc.contains(item) { acc.append(item) }
        }

        return DeviceInventorySnapshot(
            devices: devices,
            patchTitles: patchTitles,
            sourceFiles: uniqueSources,
            warnings: warnings,
            generatedAt: formattedDate(newestSourceDate),
            generatedDate: newestSourceDate,
            isDemo: false
        )
    }

    private static func emptySnapshot(warning: String) -> DeviceInventorySnapshot {
        DeviceInventorySnapshot(
            devices: [],
            patchTitles: [],
            sourceFiles: [],
            warnings: [warning],
            generatedAt: "No current device data",
            generatedDate: nil,
            isDemo: false
        )
    }

    /// Per-kind newest-file dates for the Devices freshness chip row. Keyed by
    /// on-disk kind name — computed separately from `load` because
    /// `DeviceInventorySnapshot` collapses every source to one `generatedDate`.
    /// Returns an empty map in demo mode or when the workspace is missing.
    static func sourceDates(profile: String, demoMode: Bool) -> [String: Date] {
        if demoMode { return [:] }
        guard let root = validatedWorkspaceRoot(profile: profile) else { return [:] }
        var warnings: [String] = []
        let config = loadConfigHints(root: root, warnings: &warnings)
        var dates: [String: Date] = [:]

        if let csv = resolveInventoryCSV(config: config, root: root, now: Date()),
           csv.isCurrent, let d = modificationDate(csv.url) {
            dates["inventory-csv"] = d
        }
        let jsonKinds: [(kind: String, names: [String])] = [
            ("computers", ["computers-list", "computers_list", "computers"]),
            ("device-compliance", ["device-compliance", "device_compliance"]),
            ("patch-device-failures", ["patch-device-failures", "patch_device_failures"]),
            ("patch-status", ["patch-status", "patch_status"]),
        ]
        for entry in jsonKinds {
            if let url = latestCachedJSON(dataDir: config.jamfCLIDataDir, names: entry.names, root: root),
               let d = modificationDate(url) {
                dates[entry.kind] = d
            }
        }
        return dates
    }
}

// MARK: - Workspace validation

fileprivate extension DeviceInventoryService {

    static func validatedWorkspaceRoot(profile: String) -> URL? {
        guard ProfileService.isValid(profile),
              let declared = ProfileService.workspaceURL(for: profile) else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: declared.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        let standardized = declared.standardizedFileURL
        let resolved = declared.resolvingSymlinksInPath().standardizedFileURL
        return isInside(resolved, root: standardized) ? resolved : nil
    }

    static func validatedDirectory(_ url: URL, root: URL) -> URL? {
        guard let resolved = secureURL(url, root: root),
              let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return nil
        }
        return resolved
    }

    static func validatedFile(_ url: URL, root: URL) -> URL? {
        guard let resolved = secureURL(url, root: root),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return nil
        }
        return resolved
    }

    static func secureURL(_ url: URL, root: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return isInside(resolved, root: root) ? resolved : nil
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    static func displayPath(_ url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        let suffix = path.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return WorkspaceRootStore.displayPath(profile: root.lastPathComponent, subpath: suffix)
    }
}

// MARK: - Config/path discovery

fileprivate extension DeviceInventoryService {

    static func loadConfigHints(root: URL, warnings: inout [String]) -> ConfigHints {
        var values: [String: [String: String]] = [:]
        let configURL = root.appendingPathComponent("config.yaml")
        if let configFile = validatedFile(configURL, root: root),
           let text = readText(configFile, root: root, maxBytes: 256 * 1024, warnings: &warnings) {
            values = parseSimpleYAML(text)
        }

        let profile = root.lastPathComponent
        let jamfCLIDataDir = (try? WorkspacePaths.dataDir(for: profile))
            ?? resolvedDirectory("jamf-cli-data", fallback: "jamf-cli-data", root: root)
        let historicalCSVDir = (try? WorkspacePaths.historicalDir(for: profile))
            ?? resolvedDirectory("snapshots", fallback: "snapshots", root: root)

        return ConfigHints(
            jamfCLIDataDir: jamfCLIDataDir,
            outputDir: resolvedDirectory(
                values["output"]?["output_dir"],
                fallback: "Generated Reports",
                root: root
            ),
            historicalCSVDir: historicalCSVDir,
            staleDeviceDays: Int(values["thresholds"]?["stale_device_days"] ?? "") ?? 30
        )
    }

    static func resolvedDirectory(_ raw: String?, fallback: String, root: URL) -> URL {
        let value = (raw.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
            .replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        let candidate = value.hasPrefix("/")
            ? URL(fileURLWithPath: value, isDirectory: true)
            : root.appendingPathComponent(value, isDirectory: true)
        return secureURL(candidate, root: root) ?? root.appendingPathComponent(fallback, isDirectory: true)
    }

    static func parseSimpleYAML(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if !rawLine.hasPrefix(" "), trimmed.hasSuffix(":") {
                section = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                result[section] = result[section] ?? [:]
                continue
            }
            guard !section.isEmpty, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let comment = value.firstIndex(of: "#") {
                value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            result[section]?[key] = value
        }
        return result
    }
}

// MARK: - Current source lookup

private extension DeviceInventoryService {

    /// Resolve the inventory CSV together with the verdict on whether it is
    /// still current. Kept separate from `latestInventoryCSV` so the "which file"
    /// and "is it usable" questions stay independently testable.
    static func resolveInventoryCSV(
        config: ConfigHints,
        root: URL,
        now: Date
    ) -> (url: URL, isCurrent: Bool, ageDays: Int?)? {
        guard let url = latestInventoryCSV(config: config, root: root) else { return nil }
        let exportDate = inventoryCSVExportDate(
            filename: url.lastPathComponent,
            modified: modificationDate(url)
        )
        return (
            url: url,
            isCurrent: inventoryCSVIsCurrent(
                exportDate: exportDate, now: now, staleDeviceDays: config.staleDeviceDays
            ),
            ageDays: exportDate.map { inventoryCSVAgeDays(exportDate: $0, now: now) }
        )
    }

    /// Names the file, its age and the remedy. An ignored file the operator
    /// dropped themselves must never be a silent skip.
    ///
    /// ponytail: the unknown-age wording is unreachable by construction — an
    /// undatable file is reported as current, so this only ever runs with a
    /// known age. Kept so a future change to that rule degrades to vague copy
    /// rather than a crash or a silent skip.
    static func agedInventoryCSVWarning(
        _ csv: (url: URL, isCurrent: Bool, ageDays: Int?),
        root: URL,
        config: ConfigHints
    ) -> String {
        let age = csv.ageDays.map { "\($0) days old" } ?? "older than the stale threshold"
        return "Ignoring \(displayPath(csv.url, root: root)) — it is \(age), past the "
            + "\(config.staleDeviceDays)-day stale threshold. A CSV export cannot report a "
            + "check-in newer than the day it ran, so at that age it marks devices stale that "
            + "are still checking in and re-adds devices already retired. Drop a current export "
            + "in csv-inbox/ or delete this one."
    }

    static func latestInventoryCSV(config: ConfigHints, root: URL) -> URL? {
        let primary = latestFile(
            in: config.outputDir,
            root: root,
            extensions: ["csv"],
            predicate: { name in
                name.hasPrefix("automation_inventory_") || name.hasPrefix("jamf_inventory")
            }
        )
        if let primary { return primary }

        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        if let inboxLatest = latestFile(in: inbox, root: root, extensions: ["csv"]) {
            return inboxLatest
        }
        return latestFile(in: config.historicalCSVDir, root: root, extensions: ["csv"], maxDepth: 2)
    }

    static func latestCachedJSON(dataDir: URL, names: [String], root: URL) -> URL? {
        var candidates: [URL] = []
        for name in names {
            let reportDir = dataDir.appendingPathComponent(name, isDirectory: true)
            if let direct = latestFile(in: reportDir, root: root, extensions: ["json"]) {
                candidates.append(direct)
            }
            if let flat = latestFile(
                in: dataDir,
                root: root,
                extensions: ["json"],
                predicate: { $0 == "\(name).json" || $0.hasPrefix("\(name)_") }
            ) {
                candidates.append(flat)
            }
        }
        return newest(candidates)
    }

    static func latestFile(
        in directory: URL,
        root: URL,
        extensions: Set<String>,
        maxDepth: Int = 1,
        predicate: (String) -> Bool = { _ in true }
    ) -> URL? {
        guard let dir = validatedDirectory(directory, root: root) else { return nil }
        var files: [URL] = []
        collectFiles(in: dir, root: root, extensions: extensions, maxDepth: maxDepth, into: &files)
        // manifest.json is integrity metadata, never a device source — and
        // ReportEngine writes it *after* the snapshot it describes, so it always
        // sorts newest by mtime. Without this, turning on `jamf_cli.require_manifest`
        // would resolve every kind to the manifest and read zero devices, leaving
        // an inventory CSV as the only source. Mirrors the exclusion
        // FileManager.newestJSONFile has applied since 2.6; this file has its own
        // picker and never received it.
        return newest(files.filter {
            let name = $0.lastPathComponent
            return predicate(name)
                && !name.contains(".partial")
                && name.lowercased() != "manifest.json"
        })
    }

    static func collectFiles(
        in directory: URL,
        root: URL,
        extensions: Set<String>,
        maxDepth: Int,
        into files: inout [URL]
    ) {
        guard maxDepth >= 1,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for entry in entries {
            if let file = validatedFile(entry, root: root),
               extensions.contains(file.pathExtension.lowercased()) {
                files.append(file)
                continue
            }
            if maxDepth > 1, let childDir = validatedDirectory(entry, root: root) {
                collectFiles(in: childDir, root: root, extensions: extensions, maxDepth: maxDepth - 1, into: &files)
            }
        }
    }
}

// MARK: - Inventory sources

private extension DeviceInventoryService {

    static func loadCSVInventory(
        _ url: URL,
        root: URL,
        into merger: inout DeviceRecordMerger,
        warnings: inout [String],
        staleThresholdDays: Int = 30
    ) {
        guard let text = readText(url, root: root, maxBytes: 40 * 1024 * 1024, warnings: &warnings) else {
            return
        }
        let rows = parseCSVRows(text)
        for row in rows.prefix(10_000) {
            merger.upsert(recordFromCSV(row, source: url.lastPathComponent,
                                        staleThresholdDays: staleThresholdDays))
        }
    }

    static func loadComputersList(
        _ url: URL,
        root: URL,
        into merger: inout DeviceRecordMerger,
        warnings: inout [String],
        staleThresholdDays: Int = 30
    ) {
        for item in jsonArray(from: url, root: root, warnings: &warnings) {
            merger.upsert(recordFromComputer(item, source: url.lastPathComponent,
                                             staleThresholdDays: staleThresholdDays))
        }
    }

    static func loadDeviceCompliance(
        _ url: URL,
        root: URL,
        into merger: inout DeviceRecordMerger,
        warnings: inout [String],
        staleThresholdDays: Int = 30
    ) {
        for item in jsonArray(from: url, root: root, warnings: &warnings) {
            merger.upsert(recordFromCompliance(item, source: url.lastPathComponent,
                                               staleThresholdDays: staleThresholdDays))
        }
    }

    static func loadPatchFailures(
        _ url: URL,
        root: URL,
        into merger: inout DeviceRecordMerger,
        warnings: inout [String]
    ) {
        for item in jsonArray(from: url, root: root, warnings: &warnings) {
            merger.upsert(recordFromPatchFailure(item, source: url.lastPathComponent))
        }
    }
}

// MARK: - Record mapping

extension DeviceInventoryService {

    static func recordFromCSV(
        _ row: [String: String],
        source: String,
        staleThresholdDays: Int = 30
    ) -> DeviceInventoryRecord {
        let name = cell(row, ["Computer Name", "Device Name", "Name"])
        let serial = cell(row, ["Serial Number", "Serial"])
        let jamfID = cell(row, ["Jamf ID", "Computer ID", "ID"])
        var record = DeviceInventoryRecord.empty(id: recordID(name: name, serial: serial, jamfID: jamfID), source: source)
        record.jamfID = jamfID
        record.name = name
        record.serial = serial
        record.osVersion = cell(row, ["Operating System", "Operating System Version", "OS Version", "macOS"])
        record.model = cell(row, ["Model", "Model Identifier"])
        record.user = cell(row, ["Username", "User Last Logged in - Computer", "Full Name", "User"])
        record.email = cell(row, ["Email Address", "Email", "Primary Email"])
        record.department = cell(row, ["Department"])
        record.building = cell(row, ["Building"])
        record.site = cell(row, ["Site"])
        record.ipAddress = cell(row, ["IP Address", "Last IP Address"])
        record.assetTag = cell(row, ["Asset Tag"])
        record.managedState = cell(row, ["Managed"])
        record.lastContact = cell(row, ["Last Check-in", "Last Contact", "Last Contact Date"])
        record.lastInventory = cell(row, ["Last Inventory Update", "Last Report", "Report Date"])
        record.daysSinceContact = daysSince(row: row, dateLabel: record.lastContact)
        record.stale = (record.daysSinceContact ?? 0) >= staleThresholdDays
        record.fileVault = cell(row, ["FileVault Status", "FileVault 2 Status", "FileVault 2 Enabled"])
        record.sip = cell(row, ["System Integrity Protection", "SIP"])
        record.firewall = cell(row, ["Firewall Enabled", "Firewall"])
        record.gatekeeper = cell(row, ["Gatekeeper"])
        record.bootstrapToken = cell(row, ["Bootstrap Token Escrowed", "Bootstrap Token Allowed"])
        record.diskUsage = cell(row, ["Boot Drive Percentage Full", "Disk Usage %"])
        record.failedRules = failureCount(row)
        return record
    }

    static func recordFromComputer(
        _ item: [String: Any],
        source: String,
        staleThresholdDays: Int = 30
    ) -> DeviceInventoryRecord {
        let flat = flattened(item)
        let name = first(flat, ["general.name", "name", "general.displayName"])
        let serial = first(flat, ["hardware.serialNumber", "serialNumber", "general.serialNumber"])
        let jamfID = firstNumericID(
            flat,
            ["general.id", "id", "computerId", "computer_id", "general.computerId"]
        )
        var record = DeviceInventoryRecord.empty(id: recordID(name: name, serial: serial, jamfID: jamfID), source: source)
        record.jamfID = jamfID
        record.name = name
        record.serial = serial
        record.osVersion = first(flat, ["operatingSystem.version", "operatingSystemVersion", "general.osVersion"])
        record.model = first(flat, ["hardware.modelIdentifier", "hardware.model", "modelIdentifier", "general.model"])
        record.user = first(flat, ["userAndLocation.username", "location.username", "username"])
        record.email = first(flat, ["userAndLocation.email", "userAndLocation.emailAddress", "location.emailAddress"])
        record.department = first(flat, ["userAndLocation.department", "location.department", "department"])
        record.building = first(flat, ["userAndLocation.building", "location.building", "building"])
        record.site = first(flat, ["general.site.name", "site.name", "site"])
        record.ipAddress = first(flat, ["general.lastIpAddress", "general.lastReportedIp", "general.ipAddress", "ipAddress"])
        record.assetTag = first(flat, ["general.assetTag", "assetTag"])
        record.managedState = managedLabel(first(flat, ["general.remoteManagement.managed", "general.managed", "isManaged", "managed"]))
        record.lastContact = first(flat, ["general.lastContactTime", "general.lastContactDate", "lastContactDate"])
        record.lastInventory = first(flat, ["general.reportDate", "general.lastReportDate", "lastReportDate"])
        record.daysSinceContact = daysSince(label: record.lastContact)
        record.stale = (record.daysSinceContact ?? 0) >= staleThresholdDays
        record.fileVault = first(flat, ["diskEncryption.bootPartitionEncryptionDetails.partitionFileVault2State", "operatingSystem.fileVault2Status", "diskEncryption.fileVault2Enabled"])
        record.sip = first(flat, ["security.sipStatus", "security.systemIntegrityProtection"])
        record.firewall = first(flat, ["security.firewallEnabled", "operatingSystem.activeDirectoryStatus.firewallEnabled"])
        record.gatekeeper = first(flat, ["security.gatekeeperStatus"])
        record.bootstrapToken = first(flat, ["security.bootstrapTokenEscrowed", "security.bootstrapTokenAllowed"])
        return record
    }

    static func recordFromCompliance(
        _ item: [String: Any],
        source: String,
        staleThresholdDays: Int = 30
    ) -> DeviceInventoryRecord {
        let name = clean(item["name"]) ?? clean(item["device"]) ?? ""
        let serial = clean(item["serial"]) ?? clean(item["serial_number"]) ?? ""
        let jamfID = firstNumericID(item, ["id", "jamf_id", "device_id"])
        var record = DeviceInventoryRecord.empty(id: recordID(name: name, serial: serial, jamfID: jamfID), source: source)
        record.jamfID = jamfID
        record.name = name
        record.serial = serial
        record.osVersion = clean(item["os_version"]) ?? clean(item["operating_system"]) ?? ""
        record.lastContact = clean(item["last_contact"]) ?? clean(item["last_checkin"]) ?? ""
        record.daysSinceContact = intValue(item["days_since_contact"]) ?? daysSince(label: record.lastContact)
        record.managedState = managedLabel(clean(item["managed"]) ?? "")
        record.stale = boolValue(item["stale"]) || (record.daysSinceContact ?? 0) >= staleThresholdDays
        return record
    }

    static func recordFromPatchFailure(_ item: [String: Any], source: String) -> DeviceInventoryRecord {
        let name = clean(item["device"]) ?? clean(item["name"]) ?? ""
        let serial = clean(item["serial"]) ?? ""
        let jamfID = firstNumericID(
            item,
            ["device_id", "deviceId", "computer_id", "computerId"]
        )
        let title = clean(item["policy"]) ?? clean(item["title"]) ?? clean(item["patch_title"]) ?? "Patch title"
        let status = clean(item["last_action"]) ?? clean(item["status"]) ?? clean(item["state"]) ?? "Needs attention"
        let failure = DevicePatchFailure(
            title: title,
            status: status,
            date: clean(item["status_date"]) ?? clean(item["updated"]) ?? clean(item["last_event"]) ?? "",
            latestVersion: clean(item["latest"]) ?? clean(item["version"]) ?? ""
        )
        var record = DeviceInventoryRecord.empty(id: recordID(name: name, serial: serial, jamfID: jamfID), source: source)
        record.jamfID = jamfID
        record.name = name
        record.serial = serial
        record.osVersion = clean(item["os_version"]) ?? ""
        record.user = clean(item["username"]) ?? ""
        record.patchFailures = [failure]
        return record
    }
}

// MARK: - Inventory CSV freshness

extension DeviceInventoryService {

    /// Export date of an inventory CSV: the date stamped in the filename first,
    /// modification time only as a fallback.
    ///
    /// mtime is not trustworthy here. A sync provider restamps a file when it
    /// materializes it, so on a shared workspace a months-old export downloads
    /// as "modified today" — which is exactly the deployment this bound exists
    /// to protect. The filename is the only durable record of when the export ran.
    static func inventoryCSVExportDate(filename: String, modified: Date?) -> Date? {
        lastDateStamp(in: filename) ?? modified
    }

    /// Whether a CSV export is still current inventory.
    ///
    /// A CSV is a point-in-time roster: it can never report a check-in newer than
    /// the day it ran. Once it ages past the stale threshold every device it
    /// contributes reads as stale, and devices retired since the export are
    /// resurrected — at that point it is history, not inventory.
    ///
    /// An unknown export date or a disabled threshold means no bound: fail toward
    /// loading the operator's file rather than silently dropping it.
    static func inventoryCSVIsCurrent(exportDate: Date?, now: Date, staleDeviceDays: Int) -> Bool {
        guard staleDeviceDays > 0, let exportDate else { return true }
        return inventoryCSVAgeDays(exportDate: exportDate, now: now) <= staleDeviceDays
    }

    /// Whole days between the export and `now`. Negative for a future stamp,
    /// which reads as current rather than infinitely stale.
    static func inventoryCSVAgeDays(exportDate: Date, now: Date) -> Int {
        Int((now.timeIntervalSince(exportDate) / 86_400).rounded(.towardZero))
    }

    /// Last `yyyy-MM-dd` or `yyyy_MM_dd` in the name — last, not first, because
    /// export names commonly carry a config stamp ahead of the run stamp
    /// (`automation_inventory_config_2026_04_28_090007_2026-04-28_090526.csv`).
    static func lastDateStamp(in filename: String) -> Date? {
        let chars = Array(filename)
        guard chars.count >= 10 else { return nil }
        var found: Date?
        var i = 0
        while i + 10 <= chars.count {
            let window = Array(chars[i..<(i + 10)])
            if isDateStampShape(window), let parsed = dateFromStamp(String(window)) {
                found = parsed
                i += 10
            } else {
                i += 1
            }
        }
        return found
    }

    private static func isDateStampShape(_ w: [Character]) -> Bool {
        func digit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        func sep(_ c: Character) -> Bool { c == "-" || c == "_" }
        return digit(w[0]) && digit(w[1]) && digit(w[2]) && digit(w[3])
            && sep(w[4]) && digit(w[5]) && digit(w[6])
            && sep(w[7]) && digit(w[8]) && digit(w[9])
    }

    private static func dateFromStamp(_ stamp: String) -> Date? {
        csvStampFormatter.date(from: stamp.replacingOccurrences(of: "_", with: "-"))
    }

    /// Local time zone, matching `dateFromSnapshotFilename` — the comparison is
    /// whole days, so the zone only shifts the boundary by under a day.
    static let csvStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
}

// MARK: - Patch title summary

private extension DeviceInventoryService {

    static func loadPatchTitles(
        dataDir: URL,
        root: URL,
        sourceFiles: inout [String],
        newestSourceDate: inout Date?,
        warnings: inout [String]
    ) -> [PatchTitleSummary] {
        guard let url = latestCachedJSON(
            dataDir: dataDir,
            names: ["patch-status", "patch_status"],
            root: root
        ) else {
            return []
        }
        sourceFiles.append(displayPath(url, root: root))
        newestSourceDate = maxDate(newestSourceDate, modificationDate(url))

        return jsonArray(from: url, root: root, warnings: &warnings).map { item in
            let total = intValue(item["total"]) ?? 0
            let latestCount = intValue(item["on_latest"]) ?? intValue(item["installed"]) ?? 0
            return PatchTitleSummary(
                title: clean(item["title"]) ?? clean(item["name"]) ?? "Patch title",
                latestVersion: clean(item["latest"]) ?? clean(item["latest_version"]) ?? "",
                compliant: latestCount,
                total: total,
                complianceLabel: clean(item["compliance_pct"]) ?? percentLabel(latestCount, total)
            )
        }
    }
}

// MARK: - JSON and CSV parsing

private extension DeviceInventoryService {

    static func jsonArray(
        from url: URL,
        root: URL,
        warnings: inout [String]
    ) -> [[String: Any]] {
        guard let file = validatedFile(url, root: root),
              let data = readData(file, root: root, maxBytes: 60 * 1024 * 1024, warnings: &warnings) else {
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            warnings.append("Could not parse \(url.lastPathComponent)")
            return []
        }
        if let rows = object as? [[String: Any]] { return rows }
        if let dict = object as? [String: Any] {
            for key in ["results", "computers", "devices", "data", "error_devices", "failed_plans"] {
                if let rows = dict[key] as? [[String: Any]] { return rows }
            }
        }
        return []
    }

    static func readText(
        _ url: URL,
        root: URL,
        maxBytes: Int,
        warnings: inout [String]
    ) -> String? {
        guard let data = readData(url, root: root, maxBytes: maxBytes, warnings: &warnings) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    static func readData(
        _ url: URL,
        root: URL,
        maxBytes: Int,
        warnings: inout [String]
    ) -> Data? {
        guard let file = validatedFile(url, root: root),
              let values = try? file.resourceValues(forKeys: [.fileSizeKey]) else {
            return nil
        }
        if let size = values.fileSize, size > maxBytes {
            warnings.append("Skipped \(file.lastPathComponent); file is larger than \(maxBytes / 1_048_576) MB")
            return nil
        }
        return try? Data(contentsOf: file)
    }

    static func parseCSVRows(_ text: String) -> [[String: String]] {
        let table = parseCSVTable(text)
        guard let header = table.first else { return [] }
        let headers = header.map { $0.replacingOccurrences(of: "\u{feff}", with: "") }
        return table.dropFirst().map { row in
            var dict: [String: String] = [:]
            for idx in headers.indices {
                dict[headers[idx]] = idx < row.count ? row[idx] : ""
            }
            return dict
        }
    }

    static func parseCSVTable(_ text: String) -> [[String]] {
        let chars = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" {
                    field.append("\"")
                    i += 1
                } else {
                    inQuotes.toggle()
                }
            } else if ch == "," && !inQuotes {
                row.append(field)
                field = ""
            } else if (ch == "\n" || ch == "\r") && !inQuotes {
                row.append(field)
                if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                row = []
                field = ""
                if ch == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
            } else {
                field.append(ch)
            }
            i += 1
        }
        row.append(field)
        if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
        return rows
    }
}

// MARK: - Value helpers

private extension DeviceInventoryService {

    static func cell(_ row: [String: String], _ candidates: [String]) -> String {
        // Two CSV headers can normalize to the same key ("Serial Number" and
        // "serial_number" both become "serialnumber"), which traps. A duplicate
        // column is a messy export, not a reason to crash — first wins.
        let normalized = Dictionary(
            row.map { (normalizeHeader($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        for key in candidates {
            let value = row[key] ?? normalized[normalizeHeader(key)] ?? ""
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    static func failureCount(_ row: [String: String]) -> Int {
        let exact = cell(row, ["Failed Rules", "Failed Rules Count", "Failures", "Compliance Failures"])
        if let value = Int(exact.trimmingCharacters(in: CharacterSet(charactersIn: " %"))) {
            return value
        }
        for (key, value) in row {
            let normalized = normalizeHeader(key)
            if normalized.contains("fail") && (normalized.contains("count") || normalized.contains("rules")),
               let parsed = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: " %"))) {
                return parsed
            }
        }
        return 0
    }

    static func daysSince(row: [String: String], dateLabel: String) -> Int? {
        let exact = cell(row, ["Days Since Contact", "Days Since Check-in", "Days Since Inventory"])
        return Int(exact) ?? daysSince(label: dateLabel)
    }

    static func daysSince(label: String) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.split(separator: " ").first, let days = Int(first) {
            return days
        }
        guard let date = parseDate(trimmed) else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }

    static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MM/dd/yyyy HH:mm", "MM/dd/yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func flattened(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        flatten(dict, prefix: "", into: &out)
        return out
    }

    static func flatten(_ dict: [String: Any], prefix: String, into out: inout [String: Any]) {
        for (key, value) in dict {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                flatten(nested, prefix: fullKey, into: &out)
            } else {
                out[fullKey] = value
            }
        }
    }

    static func first(_ flat: [String: Any], _ candidates: [String]) -> String {
        for key in candidates {
            if let value = clean(flat[key]), !value.isEmpty { return value }
        }
        return ""
    }

    static func firstNumericID(_ values: [String: Any], _ candidates: [String]) -> String? {
        for key in candidates {
            if let value = numericID(values[key]) { return value }
        }
        return nil
    }

    static func numericID(_ value: Any?) -> String? {
        let raw: String?
        switch value {
        case let value as String:
            raw = value
        case _ as Bool:
            raw = nil
        case let value as NSNumber:
            raw = value.stringValue
        default:
            raw = nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        return trimmed
    }

    static func clean(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as Bool:
            return value ? "true" : "false"
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let text = clean(value) {
            return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: " %")))
        }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        let text = clean(value)?.lowercased() ?? ""
        return ["true", "yes", "1", "managed", "stale"].contains(text)
    }

    static func managedLabel(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["true", "yes", "1", "managed"].contains(text) { return "Managed" }
        if ["false", "no", "0", "unmanaged"].contains(text) { return "Unmanaged" }
        return value
    }

    static func normalizeHeader(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Misc helpers

fileprivate extension DeviceInventoryService {

    static func recordID(name: String, serial: String, jamfID: String? = nil) -> String {
        let serialKey = normalizedKey(serial)
        if !serialKey.isEmpty { return "serial:\(serialKey)" }
        if let jid = jamfID?.trimmingCharacters(in: .whitespacesAndNewlines), !jid.isEmpty {
            return "jamf:\(jid)"
        }
        let nameKey = normalizedKey(name)
        return nameKey.isEmpty ? "device:unknown" : "name:\(nameKey)"
    }

    static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func percentLabel(_ numerator: Int, _ denominator: Int) -> String {
        guard denominator > 0 else { return "N/A" }
        return String(format: "%.1f%%", Double(numerator) / Double(denominator) * 100)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func newest(_ urls: [URL]) -> URL? {
        urls.max { (modificationDate($0) ?? .distantPast) < (modificationDate($1) ?? .distantPast) }
    }

    static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let a), .some(let b)): max(a, b)
        case (.some(let a), .none): a
        case (.none, .some(let b)): b
        case (.none, .none): nil
        }
    }

    static func formattedDate(_ date: Date?) -> String {
        guard let date else { return "No current device data" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func riskRank(_ risk: DeviceInventoryRecord.Risk) -> Int {
        switch risk {
        case .critical: 3
        case .attention: 2
        case .unknown: 1
        case .ok: 0
        }
    }
}

// MARK: - Merge helper

private struct DeviceRecordMerger {
    private(set) var records: [DeviceInventoryRecord] = []
    private var jamfIDIndex: [String: Int] = [:]
    private var serialIndex: [String: Int] = [:]
    private var nameIndex: [String: Int] = [:]

    mutating func upsert(_ record: DeviceInventoryRecord) {
        let newJamfIDKey = record.numericJamfID
        let newSerialKey = DeviceInventoryService.normalizedKey(record.serial)
        let newNameKey = DeviceInventoryService.normalizedKey(record.name)

        if let idx = (!newSerialKey.isEmpty ? serialIndex[newSerialKey] : nil)
            ?? (newJamfIDKey.map { jamfIDIndex[$0] } ?? nil)
            ?? (!newNameKey.isEmpty ? nameIndex[newNameKey] : nil) {
            // Update existing record. Remove stale index entries, merge, then
            // add updated ones — O(1) instead of O(n) full rebuild.
            let existing = records[idx]
            let oldJamfIDKey = existing.numericJamfID
            let oldSerialKey = DeviceInventoryService.normalizedKey(existing.serial)
            let oldNameKey = DeviceInventoryService.normalizedKey(existing.name)

            records[idx].merge(record)

            let mergedJamfIDKey = records[idx].numericJamfID
            let mergedSerialKey = DeviceInventoryService.normalizedKey(records[idx].serial)
            let mergedNameKey = DeviceInventoryService.normalizedKey(records[idx].name)

            if oldJamfIDKey != mergedJamfIDKey {
                if let old = oldJamfIDKey { jamfIDIndex.removeValue(forKey: old) }
                if let new = mergedJamfIDKey { jamfIDIndex[new] = idx }
            }
            if oldSerialKey != mergedSerialKey {
                if !oldSerialKey.isEmpty { serialIndex.removeValue(forKey: oldSerialKey) }
                if !mergedSerialKey.isEmpty { serialIndex[mergedSerialKey] = idx }
            }
            if oldNameKey != mergedNameKey {
                if !oldNameKey.isEmpty { nameIndex.removeValue(forKey: oldNameKey) }
                if !mergedNameKey.isEmpty { nameIndex[mergedNameKey] = idx }
            }
        } else {
            // New record: append and index in O(1).
            let idx = records.count
            records.append(record)
            if let jamfIDKey = newJamfIDKey { jamfIDIndex[jamfIDKey] = idx }
            if !newSerialKey.isEmpty { serialIndex[newSerialKey] = idx }
            if !newNameKey.isEmpty { nameIndex[newNameKey] = idx }
        }
    }
}
