import Foundation

/// Read-only loader for the Devices screen.
///
/// All file reads are constrained to `~/Jamf-Reports/<profile>/`. The service
/// never shells out; it uses current inventory CSV output plus cached jamf-cli
/// JSON snapshots that the Python tool already writes.
enum DeviceInventoryService {

    fileprivate struct ConfigHints {
        var jamfCLIDataDir: URL
        var outputDir: URL
        var historicalCSVDir: URL
    }

    static func load(profile: String, demoMode: Bool) -> DeviceInventorySnapshot {
        if demoMode { return DemoData.deviceSnapshot }
        guard let root = validatedWorkspaceRoot(profile: profile) else {
            return emptySnapshot(
                warning: "Workspace is missing or not contained in ~/Jamf-Reports/\(profile)/"
            )
        }

        var warnings: [String] = []
        let config = loadConfigHints(root: root, warnings: &warnings)
        var merger = DeviceRecordMerger()
        var sourceFiles: [String] = []
        var newestSourceDate: Date?

        if let csv = latestInventoryCSV(config: config, root: root) {
            loadCSVInventory(csv, root: root, into: &merger, warnings: &warnings)
            sourceFiles.append(displayPath(csv, root: root))
            newestSourceDate = maxDate(newestSourceDate, modificationDate(csv))
        }

        if let computers = latestCachedJSON(
            dataDir: config.jamfCLIDataDir,
            names: ["computers-list", "computers_list"],
            root: root
        ) {
            loadComputersList(computers, root: root, into: &merger, warnings: &warnings)
            sourceFiles.append(displayPath(computers, root: root))
            newestSourceDate = maxDate(newestSourceDate, modificationDate(computers))
        }

        if let compliance = latestCachedJSON(
            dataDir: config.jamfCLIDataDir,
            names: ["device-compliance", "device_compliance"],
            root: root
        ) {
            loadDeviceCompliance(compliance, root: root, into: &merger, warnings: &warnings)
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
            isDemo: false
        )
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
        return "~/Jamf-Reports/\(root.lastPathComponent)/\(suffix)"
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

        return ConfigHints(
            jamfCLIDataDir: resolvedDirectory(
                values["jamf_cli"]?["data_dir"],
                fallback: "jamf-cli-data",
                root: root
            ),
            outputDir: resolvedDirectory(
                values["output"]?["output_dir"],
                fallback: "Generated Reports",
                root: root
            ),
            historicalCSVDir: resolvedDirectory(
                values["charts"]?["historical_csv_dir"],
                fallback: "snapshots",
                root: root
            )
        )
    }

    static func resolvedDirectory(_ raw: String?, fallback: String, root: URL) -> URL {
        let value = (raw?.isEmpty == false ? raw! : fallback)
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
        return newest(files.filter { predicate($0.lastPathComponent) && !$0.lastPathComponent.contains(".partial") })
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
        warnings: inout [String]
    ) {
        guard let text = readText(url, root: root, maxBytes: 40 * 1024 * 1024, warnings: &warnings) else {
            return
        }
        let rows = parseCSVRows(text)
        for row in rows.prefix(10_000) {
            merger.upsert(recordFromCSV(row, source: url.lastPathComponent))
        }
    }

    static func loadComputersList(
        _ url: URL,
        root: URL,
        into merger: inout DeviceRecordMerger,
        warnings: inout [String]
    ) {
        for item in jsonArray(from: url, root: root, warnings: &warnings) {
            merger.upsert(recordFromComputer(item, source: url.lastPathComponent))
        }
    }

    static func loadDeviceCompliance(
        _ url: URL,
        root: URL,
        into merger: inout DeviceRecordMerger,
        warnings: inout [String]
    ) {
        for item in jsonArray(from: url, root: root, warnings: &warnings) {
            merger.upsert(recordFromCompliance(item, source: url.lastPathComponent))
        }
    }

    static func loadPatchFailures(
        _ url: URL,
        root: URL,
        into merger: inout DeviceRecordMerger,
        warnings: inout [String]
    ) {
        for item in jsonArray(from: url, root: root, warnings: &warnings) {
            let name = clean(item["device"]) ?? clean(item["name"]) ?? ""
            let serial = clean(item["serial"]) ?? ""
            let title = clean(item["policy"]) ?? clean(item["title"]) ?? clean(item["patch_title"]) ?? "Patch title"
            let status = clean(item["last_action"]) ?? clean(item["status"]) ?? clean(item["state"]) ?? "Needs attention"
            let failure = DevicePatchFailure(
                title: title,
                status: status,
                date: clean(item["status_date"]) ?? clean(item["updated"]) ?? clean(item["last_event"]) ?? "",
                latestVersion: clean(item["latest"]) ?? clean(item["version"]) ?? ""
            )
            var record = DeviceInventoryRecord.empty(id: recordID(name: name, serial: serial), source: url.lastPathComponent)
            record.name = name
            record.serial = serial
            record.osVersion = clean(item["os_version"]) ?? ""
            record.user = clean(item["username"]) ?? ""
            record.patchFailures = [failure]
            merger.upsert(record)
        }
    }
}

// MARK: - Record mapping

private extension DeviceInventoryService {

    static func recordFromCSV(_ row: [String: String], source: String) -> DeviceInventoryRecord {
        let name = cell(row, ["Computer Name", "Device Name", "Name"])
        let serial = cell(row, ["Serial Number", "Serial"])
        var record = DeviceInventoryRecord.empty(id: recordID(name: name, serial: serial), source: source)
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
        record.stale = (record.daysSinceContact ?? 0) >= 30
        record.fileVault = cell(row, ["FileVault Status", "FileVault 2 Status", "FileVault 2 Enabled"])
        record.sip = cell(row, ["System Integrity Protection", "SIP"])
        record.firewall = cell(row, ["Firewall Enabled", "Firewall"])
        record.gatekeeper = cell(row, ["Gatekeeper"])
        record.bootstrapToken = cell(row, ["Bootstrap Token Escrowed", "Bootstrap Token Allowed"])
        record.diskUsage = cell(row, ["Boot Drive Percentage Full", "Disk Usage %"])
        record.failedRules = failureCount(row)
        return record
    }

    static func recordFromComputer(_ item: [String: Any], source: String) -> DeviceInventoryRecord {
        let flat = flattened(item)
        let name = first(flat, ["general.name", "name", "general.displayName"])
        let serial = first(flat, ["hardware.serialNumber", "serialNumber", "general.serialNumber"])
        var record = DeviceInventoryRecord.empty(id: recordID(name: name, serial: serial), source: source)
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
        record.stale = (record.daysSinceContact ?? 0) >= 30
        record.fileVault = first(flat, ["diskEncryption.bootPartitionEncryptionDetails.partitionFileVault2State", "operatingSystem.fileVault2Status", "diskEncryption.fileVault2Enabled"])
        record.sip = first(flat, ["security.sipStatus", "security.systemIntegrityProtection"])
        record.firewall = first(flat, ["security.firewallEnabled", "operatingSystem.activeDirectoryStatus.firewallEnabled"])
        record.gatekeeper = first(flat, ["security.gatekeeperStatus"])
        record.bootstrapToken = first(flat, ["security.bootstrapTokenEscrowed", "security.bootstrapTokenAllowed"])
        return record
    }

    static func recordFromCompliance(_ item: [String: Any], source: String) -> DeviceInventoryRecord {
        let name = clean(item["name"]) ?? clean(item["device"]) ?? ""
        let serial = clean(item["serial"]) ?? clean(item["serial_number"]) ?? ""
        var record = DeviceInventoryRecord.empty(id: recordID(name: name, serial: serial), source: source)
        record.name = name
        record.serial = serial
        record.osVersion = clean(item["os_version"]) ?? clean(item["operating_system"]) ?? ""
        record.lastContact = clean(item["last_contact"]) ?? clean(item["last_checkin"]) ?? ""
        record.daysSinceContact = intValue(item["days_since_contact"]) ?? daysSince(label: record.lastContact)
        record.managedState = managedLabel(clean(item["managed"]) ?? "")
        record.stale = boolValue(item["stale"]) || (record.daysSinceContact ?? 0) >= 30
        return record
    }
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
        let normalized = Dictionary(uniqueKeysWithValues: row.map { (normalizeHeader($0.key), $0.value) })
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

    static func recordID(name: String, serial: String) -> String {
        let serialKey = normalizedKey(serial)
        if !serialKey.isEmpty { return "serial:\(serialKey)" }
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
    private var serialIndex: [String: Int] = [:]
    private var nameIndex: [String: Int] = [:]

    mutating func upsert(_ record: DeviceInventoryRecord) {
        let serialKey = DeviceInventoryService.normalizedKey(record.serial)
        let nameKey = DeviceInventoryService.normalizedKey(record.name)
        if let idx = (!serialKey.isEmpty ? serialIndex[serialKey] : nil) ?? (!nameKey.isEmpty ? nameIndex[nameKey] : nil) {
            records[idx].merge(record)
        } else {
            records.append(record)
        }
        rebuildIndexes()
    }

    private mutating func rebuildIndexes() {
        serialIndex.removeAll(keepingCapacity: true)
        nameIndex.removeAll(keepingCapacity: true)
        for (idx, record) in records.enumerated() {
            let serialKey = DeviceInventoryService.normalizedKey(record.serial)
            if !serialKey.isEmpty { serialIndex[serialKey] = idx }
            let nameKey = DeviceInventoryService.normalizedKey(record.name)
            if !nameKey.isEmpty { nameIndex[nameKey] = idx }
        }
    }
}
