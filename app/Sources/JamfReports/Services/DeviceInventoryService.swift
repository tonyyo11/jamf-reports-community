import Foundation

/// Read-only loader for the Devices screen.
///
/// All file reads are constrained to `<workspaces-root>/<profile>/`. The service
/// never shells out; it reads the cached jamf-cli JSON snapshots that collect writes.
enum DeviceInventoryService {

    fileprivate struct ConfigHints {
        var jamfCLIDataDir: URL
        /// `thresholds.stale_device_days` (default 30). Drives `record.stale`
        /// so the Devices/Outreach screens agree with the Overview/Fleet tiles
        /// and the summary writer at any configured threshold.
        var staleDeviceDays: Int
        /// `thresholds.stale_basis`: which dates make a Mac stale.
        var staleBasis: [StaleBasis]
        var contactGapDays: Int
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
        warnings.append(contentsOf: linkedFolderWarnings(config: config, root: root))
        var merger = DeviceRecordMerger()
        var sourceFiles: [String] = []
        var newestSourceDate: Date?

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

        warnings.append(contentsOf: leftOutWarnings(merger.leftOutRows))

        let policy = SecurityPolicyConfigLoader.load(profile: profile)
        let staleRule = StaleRule(days: config.staleDeviceDays, basis: config.staleBasis)
        // Scored once per device: scoring reads several values, and the sort compares many
        // times. The Devices screen re-scores with the security agent's status.
        let devices = merger.records
            .map { restatingStale($0, rule: staleRule) }
            .map {
                let risk = RiskScoringService.risk(for: $0, policy: policy, staleRule: staleRule)
                return (record: $0, score: risk.score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.record.displayName
                    .localizedStandardCompare(rhs.record.displayName) == .orderedAscending
            }
            .map(\.record)
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
            isDemo: false,
            securityPolicy: policy,
            staleDays: config.staleDeviceDays,
            staleBasis: staleRule.basis,
            contactGapDays: config.contactGapDays
        )
    }

    /// A merged record's `stale` from the stale rule. The merge keeps the newest source's
    /// dates but ORs the flags, so a Mac an older snapshot saw past the threshold would stay
    /// stale after a newer one saw it check in. A record with none of the rule's dates keeps
    /// the flag its sources set.
    static func restatingStale(
        _ record: DeviceInventoryRecord, rule: StaleRule, now: Date = Date()
    ) -> DeviceInventoryRecord {
        var record = record
        record.stale = record.isStale(rule, now: now)
        return record
    }

    /// The managed flag of one `computers` element as text, read from the first of
    /// `general.remoteManagement.managed`, `general.managed`, `isManaged` and `managed` that
    /// is set; blank when none is. The one reader, for the Devices record and the HTML report.
    static func managedFlag(ofComputer item: [String: Any]) -> String {
        let general = item["general"] as? [String: Any] ?? [:]
        let remote = general["remoteManagement"] as? [String: Any] ?? [:]
        return [remote["managed"], general["managed"], item["isManaged"], item["managed"]]
            .lazy.compactMap { clean($0) }.first ?? ""
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

        // The filename stamp is when the collect ran, mtime only when there is no stamp to read.
        for entry in snapshotKinds {
            if let url = latestCachedJSON(
                   dataDir: config.jamfCLIDataDir, names: entry.names, root: root
               ),
               let d = FileManager.snapshotDate(of: url) {
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

    /// A folder inside the workspace, refused when the entry itself is a link: another Mac on a
    /// shared workspace can plant one, and resolving it first hid that (#207 M4).
    /// The snapshot kinds Devices reads, with the folder names each may have.
    static let snapshotKinds: [(kind: String, names: [String])] = [
        ("computers", ["computers-list", "computers_list", "computers"]),
        ("device-compliance", ["device-compliance", "device_compliance"]),
        ("patch-device-failures", ["patch-device-failures", "patch_device_failures"]),
        ("patch-status", ["patch-status", "patch_status"]),
    ]

    /// One warning per folder Devices reads that is a link: `validatedDirectory` refuses it,
    /// and without this the screen would go blank with no reason given.
    static func linkedFolderWarnings(config: ConfigHints, root: URL) -> [String] {
        let folders = snapshotKinds.flatMap(\.names).map {
            config.jamfCLIDataDir.appendingPathComponent($0, isDirectory: true)
        }
        return folders.filter(isLink).map {
            "Ignoring \(displayPath($0, root: root)) — it is a symbolic link, and Computers reads "
                + "only real folders, since another Mac on a shared folder could plant a link. "
                + "Replace it with the folder itself."
        }
    }

    static func validatedDirectory(_ url: URL, root: URL) -> URL? {
        guard !isLink(url),
              let resolved = secureURL(url, root: root),
              let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return nil
        }
        return resolved
    }

    /// A regular file inside the workspace, refused when the entry itself is a link unless
    /// `followingLink` (config.yaml, which `ConfigLoader` also reads through a link).
    static func validatedFile(_ url: URL, root: URL, followingLink: Bool = false) -> URL? {
        guard followingLink || !isLink(url),
              let resolved = secureURL(url, root: root),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }
        return resolved
    }

    /// Whether the entry at `url` is a symbolic link, judged with `lstat` before anything
    /// resolves it.
    static func isLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
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
        return WorkspaceRootStore.displayPath(
            profile: profileName(ofWorkspace: root), subpath: suffix
        )
    }

    /// The profile a workspace folder belongs to: its name decoded (`a%2Fb` is `a/b`).
    static func profileName(ofWorkspace root: URL) -> String {
        ProfileName.name(fromPathComponent: root.lastPathComponent) ?? root.lastPathComponent
    }
}

// MARK: - Config/path discovery

fileprivate extension DeviceInventoryService {

    /// Reads config.yaml through the engine's loader, so a value reads as the decoder would
    /// read it.
    static func loadConfigHints(root: URL, warnings: inout [String]) -> ConfigHints {
        var values: [String: Any] = [:]
        let configURL = root.appendingPathComponent("config.yaml")
        if let configFile = validatedFile(configURL, root: root, followingLink: true),
           let text = readText(configFile, root: root, maxBytes: 256 * 1024, warnings: &warnings) {
            values = (try? ConfigLoader.rawMapping(fromYAML: text)) ?? [:]
        }

        let profile = profileName(ofWorkspace: root)
        let jamfCLIDataDir = (try? WorkspacePaths.dataDir(for: profile))
            ?? resolvedDirectory("jamf-cli-data", fallback: "jamf-cli-data", root: root)

        return ConfigHints(
            jamfCLIDataDir: jamfCLIDataDir,
            // Read as the decoder reads it (`WholeNumberSetting`), so a quoted "45" is 45 here too.
            staleDeviceDays: WholeNumberSetting(
                raw: ConfigLoader.rawValue(at: ["thresholds", "stale_device_days"], in: values))?
                .value ?? 30,
            staleBasis: StaleBasisSetting(
                raw: ConfigLoader.rawValue(at: ["thresholds", "stale_basis"], in: values)).resolved,
            contactGapDays: WholeNumberSetting(
                raw: ConfigLoader.rawValue(at: ["thresholds", "contact_gap_days"], in: values))?
                .value.flatMap { ContactGap.dayRange.contains($0) ? $0 : nil }
                ?? ContactGap.defaultDays
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
}

// MARK: - Current source lookup

private extension DeviceInventoryService {

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
        // `newest` applies the shared exclusions (manifest.json, `.partial`,
        // sync-conflict copies) and the shared ordering, so this picker can no
        // longer drift from the workbook's. Only the caller-supplied name
        // predicate stays local.
        return newest(files.filter { predicate($0.lastPathComponent) })
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
                collectFiles(
                    in: childDir, root: root, extensions: extensions, maxDepth: maxDepth - 1,
                    into: &files)
            }
        }
    }
}

// MARK: - Inventory sources

private extension DeviceInventoryService {

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
        record.managementID = nilIfEmpty(first(flat, ["general.managementId", "managementId"]))
        // The MDM UDID, not `hardware.provisioningUdid`, which is a different identifier.
        record.udid = nilIfEmpty(first(flat, ["udid", "general.udid", "hardware.udid"]))
        record.name = name
        record.serial = serial
        record.osVersion = first(flat, ["operatingSystem.version", "operatingSystemVersion", "general.osVersion"])
        record.model = first(flat, ["hardware.modelIdentifier", "hardware.model", "modelIdentifier", "general.model"])
        record.user = first(flat, ["userAndLocation.username", "location.username", "username"])
        record.email = first(flat, ["userAndLocation.email", "userAndLocation.emailAddress", "location.emailAddress"])
        // Tenants that keep the address in "Username" and leave "Email" blank
        // (2.8.0 field pass) would otherwise give Offline Outreach nothing to mail.
        if record.email.isEmpty, record.user.contains("@") { record.email = record.user }
        record.department = first(flat, ["userAndLocation.department", "location.department", "department"])
        record.building = first(flat, ["userAndLocation.building", "location.building", "building"])
        record.site = first(flat, ["general.site.name", "site.name", "site"])
        record.ipAddress = first(flat, ["general.lastIpAddress", "general.lastReportedIpV4", "general.lastReportedIp", "general.ipAddress", "ipAddress"])
        record.assetTag = first(flat, ["general.assetTag", "assetTag"])
        record.managedState = managedLabel(managedFlag(ofComputer: item))
        // Jamf Pro's v4 inventory renamed lastContactTime to lastCheckIn. Its general.lastContact
        // is a separate field, null on most Macs, so it is not a substitute.
        record.lastContact = first(flat, ["general.lastCheckIn", "general.lastContactTime", "general.lastContactDate", "lastContactDate"])
        record.lastInventory = first(flat, ["general.reportDate", "general.lastReportDate", "lastReportDate"])
        let dates = ComputerDates(item: item)
        record.checkInDate = dates.checkIn
        record.inventoryDate = dates.inventory
        record.contactDate = dates.contact
        record.carriesDates = true
        record.daysSinceContact = daysSince(label: record.lastContact)
        record.stale = (record.daysSinceContact ?? 0) > staleThresholdDays
        record.fileVault = first(flat, ["diskEncryption.bootPartitionEncryptionDetails.partitionFileVault2State", "operatingSystem.fileVault2Status", "diskEncryption.fileVault2Enabled"])
        record.sip = first(flat, ["security.sipStatus", "security.systemIntegrityProtection"])
        record.firewall = first(flat, ["security.firewallEnabled", "operatingSystem.activeDirectoryStatus.firewallEnabled"])
        record.gatekeeper = first(flat, ["security.gatekeeperStatus"])
        // Jamf Pro reports escrow as bootstrapTokenEscrowedStatus; the older key only for
        // snapshots that carry it. bootstrapTokenAllowed says escrow is allowed, not done.
        record.bootstrapToken = first(
            flat, ["security.bootstrapTokenEscrowedStatus", "security.bootstrapTokenEscrowed"])
        record.hardwareEncrypted = HardwareEncryption.isHardwareEncrypted(computer: item)
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
        record.checkInDate = parseDate(record.lastContact)
        record.daysSinceContact = intValue(item["days_since_contact"]) ?? daysSince(label: record.lastContact)
        record.managedState = managedLabel(clean(item["managed"]) ?? "")
        // jamf-cli's own `stale` flag is a 14-day cut: it decides only a row with no day count.
        if let days = record.daysSinceContact {
            record.stale = days > staleThresholdDays
        } else {
            record.stale = boolValue(item["stale"])
        }
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

// MARK: - JSON parsing

private extension DeviceInventoryService {

    static func jsonArray(
        from url: URL,
        root: URL,
        warnings: inout [String]
    ) -> [[String: Any]] {
        guard let file = validatedFile(url, root: root),
              let data = readData(file, root: root, maxBytes: BoundedFile.limit(for: file), warnings: &warnings) else {
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
        guard let file = validatedFile(url, root: root) else { return nil }
        // One descriptor for the type check and the read, opened below the workspace, so neither a
        // file nor a folder swapped for a link after the check is what gets read.
        do {
            return try BoundedFile.read(file, limit: maxBytes, followSymlinks: false, inside: root)
        } catch BoundedFile.Failure.tooLarge {
            warnings.append("Skipped \(file.lastPathComponent); file is larger than \(maxBytes / 1_048_576) MB")
        } catch BoundedFile.Failure.notRegular {
            warnings.append("Skipped \(file.lastPathComponent); it is not a regular file")
        } catch {
            warnings.append("Could not read \(file.lastPathComponent)")
        }
        return nil
    }
}

// MARK: - Timestamps

extension DeviceInventoryService {

    /// The one reader of a device timestamp, shared by Devices and Offline Outreach: ISO 8601
    /// with or without a fraction of any length, then the CSV export forms.
    static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        if let date = isoFormatter.date(from: text) { return date }
        // Jamf Pro timestamps can carry milliseconds (device-compliance's do:
        // "2015-02-17T21:33:23.712Z"), which the default options reject. Such a
        // Mac had no contact age unless device-compliance supplied a day count.
        if let date = isoFractionalFormatter.date(from: text) { return date }
        for formatter in exportDateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // Built once: this runs several times per computer. As for
    // `StateFileStore.formatter`, a configured formatter's `date(from:)` is safe to share.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    nonisolated(unsafe) private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let exportDateFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MM/dd/yyyy HH:mm", "MM/dd/yyyy",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // A formatter built per call read the zone at that moment; this one follows changes.
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - Value helpers

private extension DeviceInventoryService {

    static func daysSince(label: String) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.split(separator: " ").first, let days = Int(first) {
            return days
        }
        guard let date = parseDate(trimmed) else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
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

    static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    static func percentLabel(_ numerator: Int, _ denominator: Int) -> String {
        guard denominator > 0 else { return "N/A" }
        return String(format: "%.1f%%", Double(numerator) / Double(denominator) * 100)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The one snapshot-ordering rule (`FileManager.newestSnapshot`): filename
    /// stamp first, mtime only for files that carry no stamp.
    static func newest(_ urls: [URL]) -> URL? {
        FileManager.newestSnapshot(among: urls)
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
}

// MARK: - Device identity

/// What says two inventory rows are one Mac, strongest first. A computer name is not
/// here: two Macs can share one.
enum DeviceIdentifier: CaseIterable, Sendable {
    case jamfID, managementID, udid, platformID, serial

    /// A serial is the weak one: it can sit on two Jamf records after a logic-board swap.
    var isStrong: Bool { self != .serial }
}

extension DeviceInventoryRecord {

    /// The record's value for `kind`, trimmed and lowercased; nil when no source carried one.
    func identifier(_ kind: DeviceIdentifier) -> String? {
        let raw: String? = switch kind {
        case .jamfID: numericJamfID
        case .managementID: managementID
        case .udid: udid
        case .platformID: platformID
        case .serial: serial
        }
        let key = DeviceInventoryService.normalizedKey(raw ?? "")
        return key.isEmpty ? nil : key
    }

    var identifiers: [(kind: DeviceIdentifier, value: String)] {
        DeviceIdentifier.allCases.compactMap { kind in identifier(kind).map { (kind, $0) } }
    }

    /// True when some identifier both records carry has two values.
    func disagrees(with other: DeviceInventoryRecord) -> Bool {
        DeviceIdentifier.allCases.contains { kind in
            guard let mine = identifier(kind), let theirs = other.identifier(kind) else {
                return false
            }
            return mine != theirs
        }
    }
}

extension DeviceInventoryService {

    /// The Macs in the newest `computers` snapshot alone, unmerged, for the Protect match; nil
    /// when the workspace has no such snapshot. The merged Devices load reads far more.
    static func cachedComputerRecords(profile: String) -> [DeviceInventoryRecord]? {
        guard let root = validatedWorkspaceRoot(profile: profile) else { return nil }
        var warnings: [String] = []
        let config = loadConfigHints(root: root, warnings: &warnings)
        guard let url = latestCachedJSON(
            dataDir: config.jamfCLIDataDir,
            names: ["computers-list", "computers_list", "computers"],
            root: root
        ) else { return nil }
        return jsonArray(from: url, root: root, warnings: &warnings)
            .map { recordFromComputer($0, source: url.lastPathComponent) }
    }

    /// One line per source whose rows could not be tied to a single Mac. Counts only: the
    /// warning must not carry a device name.
    static func leftOutWarnings(_ rows: [String: Int]) -> [String] {
        rows.sorted { $0.key < $1.key }.map { source, count in
            "\(source): left out \(count) \(count == 1 ? "row" : "rows") that could not be "
                + "matched to one Mac, because the serial, ID or name they carry fits more than one."
        }
    }
}

// MARK: - Merge helper

/// Folds the inventory sources into one record per Mac.
///
/// A row joins an existing record only when they share an identifier (Jamf ID, management
/// ID, UDID, Platform ID, serial) and no identifier they both carry differs. A computer name
/// never decides that alone, so two Macs that share a name stay two. A serial does not
/// outrank a differing Jamf ID either: one serial can sit on two records.
///
/// An identifier value carried by more than `maxRecordsPerSharedIdentifier` records is a
/// placeholder (a blank-ish serial such as `0`), not an identity: it stays on the records but
/// no longer joins rows, which keeps the merge linear. A row left with no other identifier
/// is placed by its name, like a row that carries none.
struct DeviceRecordMerger {
    /// The most records one identifier value may sit on and still join rows.
    static let maxRecordsPerSharedIdentifier = 50

    /// The records carrying one identifier value. Past the cap it keeps no members: the value
    /// is shared, and listing thousands of records would cost O(n) per later upsert.
    private struct Holders {
        var members: [Int] = []
        var isShared = false

        mutating func add(_ idx: Int) {
            guard !isShared, !members.contains(idx) else { return }
            members.append(idx)
            if members.count > DeviceRecordMerger.maxRecordsPerSharedIdentifier {
                members = []
                isShared = true
            }
        }
    }

    private(set) var records: [DeviceInventoryRecord] = []
    /// Rows left out per source file because nothing told which Mac they described.
    private(set) var leftOutRows: [String: Int] = [:]
    private var identifierIndex: [DeviceIdentifier: [String: Holders]] = [:]
    /// Records by name, kept to two: callers only ask for none, one or several.
    private var nameIndex: [String: [Int]] = [:]
    private var usedIDs: Set<String> = []
    /// Per base id, the highest `#n` suffix `uniqueID` has handed out; every smaller one is used.
    private var lastSuffix: [String: Int] = [:]

    private enum Placement { case merge(Int), append, leaveOut }

    mutating func upsert(_ record: DeviceInventoryRecord) {
        var record = record
        record.osVersion = OSVersionName.normalized(record.osVersion)
        switch placement(of: record) {
        case .merge(let idx):
            records[idx].merge(record)
            index(idx)
        case .append:
            record.id = uniqueID(for: record)
            records.append(record)
            index(records.count - 1)
        case .leaveOut:
            leftOutRows[record.source, default: 0] += 1
        }
    }

    private func placement(of record: DeviceInventoryRecord) -> Placement {
        let nameKey = DeviceInventoryService.normalizedKey(record.name)
        let identifiers = record.identifiers.filter { !isShared($0.kind, $0.value) }
        if identifiers.isEmpty {
            // A row the cap left with no identifier still carries them, so the named record
            // must not contradict one (another serial or Jamf ID is another Mac).
            let byName = placementByName(nameKey)
            if !record.identifiers.isEmpty, case .merge(let index) = byName,
               records[index].disagrees(with: record) {
                return .append
            }
            return byName
        }
        let candidates = compatibleRecords(sharing: identifiers, with: record)
        if candidates.isEmpty {
            // A name-only record made earlier is this Mac's only trace: take it over, but only
            // when it is the one record with that name.
            let named = nameKey.isEmpty ? [] : nameIndex[nameKey] ?? []
            if named.count == 1, records[named[0]].identifiers.isEmpty { return .merge(named[0]) }
            return .append
        }
        // Prefer the records that share something other than a serial.
        let strong = candidates.filter { $0.value }.keys
        let pool = (strong.isEmpty ? Array(candidates.keys) : Array(strong)).sorted()
        if pool.count == 1 { return .merge(pool[0]) }
        // Several records fit (one serial on two Jamf records). The name only chooses among
        // them because an identifier already ties the row to each.
        let named = pool.filter {
            !nameKey.isEmpty && DeviceInventoryService.normalizedKey(records[$0].name) == nameKey
        }
        return named.count == 1 ? .merge(named[0]) : .leaveOut
    }

    /// A row with no identifier joins the one record with its name. With no such record it is
    /// the only evidence of that Mac. With several, it is one of them and nothing says which, so
    /// it is left out rather than counted as another Mac.
    private func placementByName(_ nameKey: String) -> Placement {
        guard !nameKey.isEmpty else { return .append }
        let named = nameIndex[nameKey] ?? []
        switch named.count {
        case 0: return .append
        case 1: return .merge(named[0])
        default: return .leaveOut
        }
    }

    /// Records sharing an identifier with `record` and disagreeing on none, each marked with
    /// whether the shared identifier is more than a serial.
    private func compatibleRecords(
        sharing identifiers: [(kind: DeviceIdentifier, value: String)],
        with record: DeviceInventoryRecord
    ) -> [Int: Bool] {
        var sharesStrong: [Int: Bool] = [:]
        for (kind, value) in identifiers {
            for idx in identifierIndex[kind]?[value]?.members ?? [] {
                sharesStrong[idx] = (sharesStrong[idx] ?? false) || kind.isStrong
            }
        }
        return sharesStrong.filter { !records[$0.key].disagrees(with: record) }
    }

    private func isShared(_ kind: DeviceIdentifier, _ value: String) -> Bool {
        identifierIndex[kind]?[value]?.isShared ?? false
    }

    /// Adds record `idx` to the identifier and name indexes. A merge only fills a blank, never
    /// changes a value, so nothing needs removing: O(1) per upsert.
    private mutating func index(_ idx: Int) {
        for (kind, value) in records[idx].identifiers {
            identifierIndex[kind, default: [:]][value, default: Holders()].add(idx)
        }
        let nameKey = DeviceInventoryService.normalizedKey(records[idx].name)
        if !nameKey.isEmpty {
            var holders = nameIndex[nameKey] ?? []
            if holders.count < 2, !holders.contains(idx) {
                holders.append(idx)
                nameIndex[nameKey] = holders
            }
        }
    }

    /// `Identifiable` needs a distinct id per row, and two Macs can share the serial or name
    /// the id is built from. Returns an id no earlier row has and records it as used.
    private mutating func uniqueID(for record: DeviceInventoryRecord) -> String {
        let base = record.id
        guard usedIDs.contains(base) else { usedIDs.insert(base); return base }
        let tie = record.identifier(.jamfID) ?? record.identifier(.managementID)
            ?? record.identifier(.udid) ?? "2"
        var candidate = "\(base)#\(tie)"
        var count = lastSuffix[base] ?? 2
        while usedIDs.contains(candidate) {
            count += 1
            candidate = "\(base)#\(count)"
            lastSuffix[base] = count
        }
        usedIDs.insert(candidate)
        return candidate
    }
}
