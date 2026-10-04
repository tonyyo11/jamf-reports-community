import CryptoKit
import Foundation

/// A list entry as read from config.yaml. A save sets the editor's values on it, so its other
/// keys, their order and an earlier copy of a repeated key are written back as typed. Always
/// equal, so an entry's synthesized `==` compares only the values the editor shows: two
/// entries with the same values are the same edit.
struct ConfigEntryAsRead: Equatable, Sendable {
    var mapping = YAMLCodec.YAMLMapping(entries: [])

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

struct ConfigSecurityAgent: Identifiable, Equatable, Sendable {
    var id: String { "\(name)|\(column)|\(connectedValue)" }
    var name: String
    var column: String
    var connectedValue: String
    var source = ConfigEntryAsRead()
}

struct ConfigCustomEA: Identifiable, Equatable, Sendable {
    var id: String { "\(name)|\(column)|\(type)" }
    var name: String
    var column: String
    var type: String
    var trueValue: String
    var warningThreshold: String
    var criticalThreshold: String
    var currentVersions: [String]
    var warningDays: String
    var source = ConfigEntryAsRead()
}

struct ConfigState: Equatable, Sendable {
    var columns: [String: String]
    var mobileColumns: [String: String]
    var securityAgents: [ConfigSecurityAgent]
    var customEAs: [ConfigCustomEA]
    var staleDeviceDays: String
    var checkinOverdueDays: String
    var warningDiskPercent: String
    var criticalDiskPercent: String
    var certWarningDays: String
    var profileErrorCritical: String
    var profileErrorWarning: String
    var complianceEnabled: Bool
    var baselineLabel: String
    var failuresCountColumn: String
    var failuresListColumn: String
    var platformEnabled: Bool
    var complianceBenchmarks: [String]
    var outputDir: String
    var archiveDir: String
    var timestampOutputs: Bool
    var archiveEnabled: Bool
    var keepLatestRuns: String
    var jamfCLIUseCachedData: Bool
    var jamfCLIRequireManifest: Bool
    var orgName: String
    var logoPath: String
    var accentColor: String
    var accentDark: String

    /// The columns the Config screen has always listed. Each is written to config.yaml on
    /// every save, an empty one as `key: ""`.
    static let baseColumnKeys = [
        "computer_name", "serial_number", "operating_system", "last_checkin", "department",
        "manager", "email", "filevault", "sip", "firewall", "gatekeeper", "secure_boot",
        "bootstrap_token", "disk_percent_full", "architecture", "model", "model_identifier",
        "last_enrollment", "mdm_expiry",
    ]

    /// The rest of the `columns` keys the report engine reads (`ColumnConfig`). Written only
    /// when set: a cleared or never-typed one is left out of config.yaml, not written as `key: ""`.
    static let optionalColumnKeys = [
        "full_name", "asset_tag", "building", "position", "last_logged_in_user",
        "recovery_lock", "battery_health", "entra_sso_status", "purchase_date",
    ]

    /// Every key the Config screen's column list shows, in order.
    static let columnKeys = baseColumnKeys + optionalColumnKeys

    static let mobileColumnKeys = [
        "device_name", "serial_number", "operating_system", "last_checkin", "email",
        "model", "device_family", "managed", "supervised",
    ]

    static let defaultState = ConfigState(
        columns: [
            "computer_name": "Computer Name",
            "serial_number": "Serial Number",
            "operating_system": "Operating System Version",
            "last_checkin": "Last Check-in",
            "department": "Department",
            // No universal Jamf "Manager" column — it's an org-specific EA, so leave
            // it unmapped by default (matches Python DEFAULT_CONFIG).
            "manager": "",
            "email": "Email Address",
            "filevault": "FileVault 2 Status",
            "sip": "System Integrity Protection",
            "firewall": "Firewall Enabled",
            "gatekeeper": "Gatekeeper",
            "secure_boot": "Secure Boot Level",
            "bootstrap_token": "Bootstrap Token Escrowed",
            "disk_percent_full": "Boot Drive Percentage Full",
            "architecture": "Architecture Type",
            "model": "Model",
            "model_identifier": "Model Identifier",
            "last_enrollment": "Last Enrollment",
            "mdm_expiry": "MDM Profile Expiration Date",
            "full_name": "",
            "asset_tag": "",
            "building": "",
            "position": "",
            "last_logged_in_user": "",
            "recovery_lock": "",
            "battery_health": "",
            "entra_sso_status": "",
            "purchase_date": "",
        ],
        // Mobile is opt-in — seed empty so a Mac-only fleet doesn't trip the
        // config doctor with mappings it will never use (matches Python
        // DEFAULT_CONFIG, where mobile_columns is all "").
        mobileColumns: [
            "device_name": "",
            "serial_number": "",
            "operating_system": "",
            "last_checkin": "",
            "email": "",
            "model": "",
            "device_family": "",
            "managed": "",
            "supervised": "",
        ],
        securityAgents: [],
        customEAs: [],
        staleDeviceDays: "30",
        checkinOverdueDays: "7",
        warningDiskPercent: "80",
        criticalDiskPercent: "90",
        certWarningDays: "90",
        profileErrorCritical: "50",
        profileErrorWarning: "10",
        complianceEnabled: false,
        baselineLabel: "mSCP Compliance",
        failuresCountColumn: "",
        failuresListColumn: "",
        platformEnabled: false,
        complianceBenchmarks: [],
        outputDir: "Generated Reports",
        archiveDir: "",
        timestampOutputs: true,
        archiveEnabled: true,
        keepLatestRuns: "10",
        jamfCLIUseCachedData: true,
        jamfCLIRequireManifest: false,
        orgName: "",
        logoPath: "",
        accentColor: "#2D5EA2",
        accentDark: "#004165"
    )
}

struct LoadedConfig: Sendable {
    var document: YAMLCodec.YAMLDocument
    var state: ConfigState
    /// The file as it was read, for a save to tell whether it changed since.
    var stamp = ConfigFileStamp.absent
}

struct SavedConfig: Sendable {
    var document: YAMLCodec.YAMLDocument
    /// The state read back from what was written.
    var state: ConfigState
    var stamp: ConfigFileStamp
    var report = ConfigSaveReport()
}

/// What a save left as typed, for the Config screen to say.
struct ConfigSaveReport: Equatable, Sendable {
    /// `custom_eas`/`security_agents` left as typed: the value is not a list, so the editor
    /// read no entries from it and would have written its own list over it.
    var keptBlocks: [String] = []
    /// A block the save rewrote held a `#` comment, which the rewrite does not keep.
    var droppedComments = false
    /// A block the save rewrote held a line the reader did not read, which it does not keep.
    var droppedUnreadLines = false
    /// The copy of the file as it was, made before a save that dropped any of it.
    var backupName: String?

    /// One sentence for each thing the save left as typed or did not keep.
    var notes: [String] {
        var lines = keptBlocks.map { key in
            "\(key) in config.yaml is not a list, so it was left as typed and nothing was "
                + "written to it. Write each entry as a \"- name:\" list item so the app can "
                + "read and edit it."
        }
        guard let copy = backupName else { return lines }
        if droppedComments {
            lines.append("Comments inside the blocks this screen edits are not kept. A copy of "
                + "the file as it was is at \(copy).")
        }
        if droppedUnreadLines {
            lines.append("Lines this screen could not read inside the blocks it edits are not "
                + "kept. A copy of the file as it was is at \(copy).")
        }
        return lines
    }
}

/// A config file's modification date and size (both nil when there is no file), and the
/// SHA-256 of the text read with them.
struct ConfigFileStamp: Equatable, Sendable {
    static let absent = ConfigFileStamp(modified: nil, size: nil)

    var modified: Date?
    var size: Int?
    var digest: Data?

    /// Date and size only; the caller that read the text sets `digest`.
    static func of(_ url: URL) -> ConfigFileStamp {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .absent
        }
        return ConfigFileStamp(
            modified: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue)
    }

    /// Whether the file at `url` is still the one stamped: the same date and size, or, when a
    /// sync provider has restamped a file it did not change, the same text.
    func matches(_ url: URL) -> Bool {
        let now = Self.of(url)
        if now.modified == modified && now.size == size { return true }
        guard let digest, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        return Self.digest(text) == digest
    }

    static func digest(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }
}

enum ConfigService {
    enum ConfigError: Error, LocalizedError {
        case invalidProfile(String)
        case pathTraversal
        case symlinkDestination(URL)
        case missingConfig(URL)
        case credentialKey(String)
        case invalidTopLevel
        case changedOnDisk
        /// A scoped writer's block typed as a single value or a list.
        case notASettingsBlock(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            case .pathTraversal: "Refusing config path with a '..' component."
            case .symlinkDestination(let url): "Refusing to write symlink: \(url.path)"
            case .missingConfig(let url): "No config.yaml at \(url.path)"
            case .credentialKey(let key): "Refusing to load credential-shaped key: \(key)"
            case .invalidTopLevel: "config.yaml must contain a top-level mapping."
            case .changedOnDisk: "config.yaml changed on disk since this screen loaded it."
            case .notASettingsBlock(let key):
                "\(key) in config.yaml is not a set of settings, so it was left as typed and "
                    + "nothing was written. Write its settings indented under \"\(key):\", "
                    + "or remove that line."
            }
        }
    }

    private static let managedTopLevelKeys: Set<String> = [
        "columns", "mobile_columns", "security_agents", "custom_eas", "thresholds",
        "compliance", "platform", "output", "jamf_cli", "branding",
    ]

    static func load(profile: String, workspaceRoot: URL? = nil) throws -> LoadedConfig {
        let url = try configURL(for: profile, workspaceRoot: workspaceRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.missingConfig(url)
        }

        // Date and size are taken before the read, so a change made during it shows as one.
        var stamp = ConfigFileStamp.of(url)
        let text = try String(contentsOf: url, encoding: .utf8)
        stamp.digest = ConfigFileStamp.digest(text)
        let document = try YAMLCodec.decode(text)
        if !document.repairedKeys.isEmpty {
            AppLogger.collect.warning(
                "ConfigService: repaired malformed sequence(s) under \(document.repairedKeys.sorted().joined(separator: ", "), privacy: .public) in config.yaml — saving from the Config screen heals the file"
            )
        }
        try rejectCredentialKeys(in: document.root)
        return LoadedConfig(document: document, state: state(from: document), stamp: stamp)
    }

    /// `ifUnchangedSince`: the stamp of the file the state was read from. When the file on
    /// disk no longer matches it, nothing is written and `changedOnDisk` is thrown.
    static func save(
        profile: String,
        state: ConfigState,
        existingDocument: YAMLCodec.YAMLDocument?,
        workspaceRoot: URL? = nil,
        ifUnchangedSince stamp: ConfigFileStamp? = nil
    ) throws -> SavedConfig {
        let url = try configURL(for: profile, workspaceRoot: workspaceRoot)
        try rejectSymlinkDestination(url)
        if let stamp, !stamp.matches(url) { throw ConfigError.changedOnDisk }

        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var document: YAMLCodec.YAMLDocument
        if manager.fileExists(atPath: url.path) {
            document = try YAMLCodec.decode(String(contentsOf: url, encoding: .utf8))
            try rejectCredentialKeys(in: document.root)
        } else if let existingDocument {
            document = existingDocument
        } else {
            document = YAMLCodec.emptyDocument()
        }

        try rejectCredentialKeys(in: document.root)
        var report = ConfigSaveReport(keptBlocks: nonListBlocks(in: document.root))
        let keys = managedTopLevelKeys.subtracting(report.keptBlocks)
        apply(state: state, to: &document)
        try backUpDropped(from: document, rewriting: keys, at: url, into: &report)
        let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: keys)
        let writtenStamp = try replace(url, with: encoded)

        let written = try YAMLCodec.decode(encoded)
        return SavedConfig(
            document: written, state: Self.state(from: written), stamp: writtenStamp,
            report: report)
    }

    /// Writes the one top-level block a scoped writer owns (`charts`, `notify`, `ai`,
    /// `security_policy`) from what the file holds now; `apply` edits the root and every other
    /// line stays as typed. Like `save`, it refuses a symlink and credential-shaped keys and
    /// keeps a copy of the file when the rewritten block held a comment or an unread line.
    /// Writes nothing when `apply` leaves the block's settings as they were. A block typed as
    /// something other than settings is left as typed: `notASettingsBlock` is thrown. Returns
    /// the file's stamp afterwards, for a screen that loaded the file to adopt the write.
    static func saveBlock(
        key: String, profile: String, workspaceRoot: URL? = nil,
        apply: (inout YAMLCodec.YAMLMapping) -> Void
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        let url = try configURL(for: profile, workspaceRoot: workspaceRoot)
        try rejectSymlinkDestination(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var stamp = ConfigFileStamp.of(url)
        var document = YAMLCodec.emptyDocument()
        if FileManager.default.fileExists(atPath: url.path) {
            let text = try String(contentsOf: url, encoding: .utf8)
            stamp.digest = ConfigFileStamp.digest(text)
            document = try YAMLCodec.decode(text)
            try rejectCredentialKeys(in: document.root)
        }
        guard case .mapping(var root) = document.root else { throw ConfigError.invalidTopLevel }
        let before = root.value(for: key)
        if let before, before.mapping == nil, before != .scalar(.null) {
            throw ConfigError.notASettingsBlock(key)
        }
        apply(&root)
        let empty = YAMLCodec.YAMLMapping(entries: [])
        guard (root.value(for: key)?.mapping ?? empty) != (before?.mapping ?? empty) else {
            return (stamp, ConfigSaveReport())
        }
        document.root = .mapping(root)
        var report = ConfigSaveReport()
        try backUpDropped(from: document, rewriting: [key], at: url, into: &report)
        let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: [key])
        return (try replace(url, with: encoded), report)
    }

    /// Records what rewriting `keys` drops from the file `document` was read from (comments,
    /// lines the reader did not read), and copies the file first when it drops any.
    private static func backUpDropped(
        from document: YAMLCodec.YAMLDocument, rewriting keys: Set<String>, at url: URL,
        into report: inout ConfigSaveReport
    ) throws {
        let rewritten = YAMLCodec.replacedLines(document, replacingTopLevelKeys: keys)
        report.droppedComments = YAMLCodec.hasComment(document, onLines: rewritten)
        report.droppedUnreadLines = document.parseNotes.contains { note in
            note.isUnread && rewritten.contains { $0.contains(note.line) }
        }
        if report.droppedComments || report.droppedUnreadLines {
            report.backupName = try backUp(url)?.lastPathComponent
        }
    }

    /// Replaces the file at `url` with `encoded` through a temporary file beside it, and
    /// returns the stamp of what was written.
    private static func replace(_ url: URL, with encoded: String) throws -> ConfigFileStamp {
        let manager = FileManager.default
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".config.yaml.\(UUID().uuidString).tmp")
        try encoded.write(to: tempURL, atomically: true, encoding: .utf8)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: Data())
        }
        _ = try manager.replaceItemAt(url, withItemAt: tempURL)
        var stamp = ConfigFileStamp.of(url)
        stamp.digest = ConfigFileStamp.digest(encoded)
        return stamp
    }

    /// The list blocks whose value is a mapping or a scalar other than null.
    private static func nonListBlocks(in root: YAMLCodec.YAMLValue) -> [String] {
        ["custom_eas", "security_agents"].filter { key in
            guard let value = root.mapping?.value(for: key) else { return false }
            if case .sequence = value { return false }
            return value != .scalar(.null)
        }
    }

    /// Copies the file at `url` to `<name>.bak-<yyyyMMdd-HHmmss>` beside it, before the app
    /// replaces or rewrites it. A copy that already holds the same bytes is returned instead;
    /// a name taken by other text moves to the next free second. Keeps the returned copy and
    /// the newest four others. Nil when there is no file.
    static func backUp(_ url: URL, now: Date = Date()) throws -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".bak-"
        let text = try Data(contentsOf: url)
        let copies = try backupNames(in: directory, prefix: prefix)
        var backup: URL
        if let same = copies.sorted().last(where: {
            (try? Data(contentsOf: directory.appendingPathComponent($0))) == text
        }) {
            backup = directory.appendingPathComponent(same)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            var stamp = now
            backup = directory.appendingPathComponent(prefix + formatter.string(from: stamp))
            while manager.fileExists(atPath: backup.path) {
                stamp.addTimeInterval(1)
                backup = directory.appendingPathComponent(prefix + formatter.string(from: stamp))
            }
            try manager.copyItem(at: url, to: backup)
        }
        // Names carry local time, so the copy just made can sort before older ones.
        for old in copies.filter({ $0 != backup.lastPathComponent }).sorted().dropLast(4) {
            do {
                try manager.removeItem(at: directory.appendingPathComponent(old))
            } catch {
                let reason = error.localizedDescription
                AppLogger.collect.warning(
                    "ConfigService: kept an old config backup: \(reason, privacy: .private)")
            }
        }
        return backup
    }

    /// `<prefix><yyyyMMdd-HHmmss>` names in `directory`; nothing else that shares the prefix.
    private static func backupNames(in directory: URL, prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { name in
            guard name.hasPrefix(prefix) else { return false }
            let stamp = Array(name.dropFirst(prefix.count))
            return stamp.count == 15 && stamp.enumerated().allSatisfy {
                $0.offset == 8 ? $0.element == "-" : "0123456789".contains($0.element)
            }
        }
    }

    static func configURL(for profile: String, workspaceRoot: URL? = nil) throws -> URL {
        // ProfileName.pathComponent is the path-traversal control: it encodes `/`, and the
        // leading `.` of `.` and `..`, so the name is always one folder under the root.
        guard ProfileService.isValid(profile) else {
            throw ConfigError.invalidProfile(profile)
        }

        let root = (workspaceRoot ?? ProfileService.workspacesRoot())
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let workspace = root
            .appendingPathComponent(ProfileName.pathComponent(profile), isDirectory: true)
            .standardizedFileURL
        let config = workspace
            .appendingPathComponent("config.yaml", isDirectory: false)
            .standardizedFileURL

        return config
    }

    private static func rejectSymlinkDestination(_ url: URL) throws {
        // Use lstat (attributesOfItem) rather than URL.resourceValues so the check
        // is reliable on a freshly constructed URL — same fix as DiagnosticBundleService.
        // Returns nil for non-existent paths, so no separate fileExists guard needed;
        // dangling symlinks (exist as links but target absent) are also caught.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw ConfigError.symlinkDestination(url)
        }
    }

    private static func rejectCredentialKeys(in value: YAMLCodec.YAMLValue) throws {
        try walkCredentialKeys(in: value, path: [])
    }

    private static func walkCredentialKeys(in value: YAMLCodec.YAMLValue, path: [String]) throws {
        switch value {
        case .scalar:
            return
        case .sequence(let values):
            for item in values {
                try walkCredentialKeys(in: item, path: path)
            }
        case .mapping(let mapping):
            for entry in mapping.entries {
                let key = entry.key.lowercased()
                if key.contains("client_secret")
                    || key.contains("password")
                    || key.contains("api_key") {
                    throw ConfigError.credentialKey((path + [entry.key]).joined(separator: "."))
                }
                try walkCredentialKeys(in: entry.value, path: path + [entry.key])
            }
        }
    }

    private static func state(from document: YAMLCodec.YAMLDocument) -> ConfigState {
        guard case .mapping(let root) = document.root else {
            return .defaultState
        }

        var state = ConfigState.defaultState
        if let columns = root.value(for: "columns")?.mapping {
            for key in ConfigState.columnKeys {
                state.columns[key] = columns.value(for: key)?.stringValue ?? ""
            }
        }

        if let mobile = root.value(for: "mobile_columns")?.mapping {
            for key in ConfigState.mobileColumnKeys {
                state.mobileColumns[key] = mobile.value(for: key)?.stringValue ?? ""
            }
        }

        state.securityAgents = sequenceMappings(root, "security_agents").map {
            ConfigSecurityAgent(
                name: string($0, "name"),
                column: string($0, "column"),
                connectedValue: string($0, "connected_value"),
                source: ConfigEntryAsRead(mapping: $0)
            )
        }

        state.customEAs = sequenceMappings(root, "custom_eas").map {
            ConfigCustomEA(
                name: string($0, "name"),
                column: string($0, "column"),
                type: string($0, "type"),
                trueValue: string($0, "true_value"),
                warningThreshold: string($0, "warning_threshold"),
                criticalThreshold: string($0, "critical_threshold"),
                currentVersions: stringSequence($0, "current_versions"),
                warningDays: string($0, "warning_days"),
                source: ConfigEntryAsRead(mapping: $0)
            )
        }

        if let thresholds = root.value(for: "thresholds")?.mapping {
            state.staleDeviceDays = string(thresholds, "stale_device_days", fallback: state.staleDeviceDays)
            state.checkinOverdueDays = string(thresholds, "checkin_overdue_days", fallback: state.checkinOverdueDays)
            state.warningDiskPercent = string(
                thresholds,
                "warning_disk_percent",
                fallback: state.warningDiskPercent
            )
            state.criticalDiskPercent = string(
                thresholds,
                "critical_disk_percent",
                fallback: state.criticalDiskPercent
            )
            state.certWarningDays = string(thresholds, "cert_warning_days", fallback: state.certWarningDays)
            state.profileErrorCritical = string(thresholds, "profile_error_critical", fallback: state.profileErrorCritical)
            state.profileErrorWarning = string(thresholds, "profile_error_warning", fallback: state.profileErrorWarning)
        }

        if let compliance = root.value(for: "compliance")?.mapping {
            state.complianceEnabled = compliance.value(for: "enabled")?.boolValue ?? state.complianceEnabled
            state.baselineLabel = string(compliance, "baseline_label", fallback: state.baselineLabel)
            state.failuresCountColumn = string(compliance, "failures_count_column")
            state.failuresListColumn = string(compliance, "failures_list_column")
        }

        if let platform = root.value(for: "platform")?.mapping {
            state.platformEnabled = platform.value(for: "enabled")?.boolValue ?? state.platformEnabled
            state.complianceBenchmarks = stringSequence(platform, "compliance_benchmarks")
        }

        if let output = root.value(for: "output")?.mapping {
            state.outputDir = string(output, "output_dir", fallback: state.outputDir)
            state.archiveDir = string(output, "archive_dir", fallback: state.archiveDir)
            state.timestampOutputs = output.value(for: "timestamp_outputs")?.boolValue ?? state.timestampOutputs
            state.archiveEnabled = output.value(for: "archive_enabled")?.boolValue ?? state.archiveEnabled
            state.keepLatestRuns = string(output, "keep_latest_runs", fallback: state.keepLatestRuns)
        }

        if let jamfCLI = root.value(for: "jamf_cli")?.mapping {
            state.jamfCLIUseCachedData =
                jamfCLI.value(for: "use_cached_data")?.boolValue ?? state.jamfCLIUseCachedData
            state.jamfCLIRequireManifest =
                jamfCLI.value(for: "require_manifest")?.boolValue ?? state.jamfCLIRequireManifest
        }

        if let branding = root.value(for: "branding")?.mapping {
            state.orgName = string(branding, "org_name")
            state.logoPath = string(branding, "logo_path")
            state.accentColor = string(branding, "accent_color", fallback: state.accentColor)
            state.accentDark = string(branding, "accent_dark", fallback: state.accentDark)
        }

        return state
    }

    static func apply(state: ConfigState, to document: inout YAMLCodec.YAMLDocument) {
        var root = document.root.mapping ?? .init(entries: [])

        var columns = root.value(for: "columns")?.mapping ?? .init(entries: [])
        for key in ConfigState.baseColumnKeys {
            columns.set(key, value: scalar(state.columns[key] ?? ""))
        }
        for key in ConfigState.optionalColumnKeys {
            let value = state.columns[key] ?? ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                columns.entries.removeAll { $0.key == key }
            } else {
                columns.set(key, value: scalar(value))
            }
        }
        root.set("columns", value: .mapping(columns))

        var mobileColumns = root.value(for: "mobile_columns")?.mapping ?? .init(entries: [])
        for key in ConfigState.mobileColumnKeys {
            mobileColumns.set(key, value: scalar(state.mobileColumns[key] ?? ""))
        }
        root.set("mobile_columns", value: .mapping(mobileColumns))

        root.set("security_agents", value: .sequence(state.securityAgents.map { agent in
            var entry = agent.source.mapping
            entry.set("name", value: scalar(agent.name))
            entry.set("column", value: scalar(agent.column))
            entry.set("connected_value", value: scalar(agent.connectedValue))
            return .mapping(entry)
        }))

        root.set("custom_eas", value: .sequence(state.customEAs.map(customEAValue)))

        var thresholds = root.value(for: "thresholds")?.mapping ?? .init(entries: [])
        thresholds.set("stale_device_days", value: intScalar(state.staleDeviceDays))
        thresholds.set("checkin_overdue_days", value: intScalar(state.checkinOverdueDays))
        thresholds.set("warning_disk_percent", value: intScalar(state.warningDiskPercent))
        thresholds.set("critical_disk_percent", value: intScalar(state.criticalDiskPercent))
        thresholds.set("cert_warning_days", value: intScalar(state.certWarningDays))
        thresholds.set("profile_error_critical", value: intScalar(state.profileErrorCritical))
        thresholds.set("profile_error_warning", value: intScalar(state.profileErrorWarning))
        root.set("thresholds", value: .mapping(thresholds))

        var compliance = root.value(for: "compliance")?.mapping ?? .init(entries: [])
        compliance.set("enabled", value: .scalar(.bool(state.complianceEnabled)))
        compliance.set("baseline_label", value: scalar(state.baselineLabel))
        compliance.set("failures_count_column", value: scalar(state.failuresCountColumn))
        compliance.set("failures_list_column", value: scalar(state.failuresListColumn))
        root.set("compliance", value: .mapping(compliance))

        var platform = root.value(for: "platform")?.mapping ?? .init(entries: [])
        platform.set("enabled", value: .scalar(.bool(state.platformEnabled)))
        platform.set("compliance_benchmarks", value: .sequence(state.complianceBenchmarks.map { scalar($0) }))
        root.set("platform", value: .mapping(platform))

        var output = root.value(for: "output")?.mapping ?? .init(entries: [])
        output.set("output_dir", value: scalar(state.outputDir))
        output.set("archive_dir", value: scalar(state.archiveDir))
        output.set("timestamp_outputs", value: .scalar(.bool(state.timestampOutputs)))
        output.set("archive_enabled", value: .scalar(.bool(state.archiveEnabled)))
        output.set("keep_latest_runs", value: intScalar(state.keepLatestRuns))
        root.set("output", value: .mapping(output))

        var jamfCLI = root.value(for: "jamf_cli")?.mapping ?? .init(entries: [])
        jamfCLI.set("use_cached_data", value: .scalar(.bool(state.jamfCLIUseCachedData)))
        jamfCLI.set("require_manifest", value: .scalar(.bool(state.jamfCLIRequireManifest)))
        root.set("jamf_cli", value: .mapping(jamfCLI))

        var branding = root.value(for: "branding")?.mapping ?? .init(entries: [])
        branding.set("org_name", value: scalar(state.orgName))
        branding.set("logo_path", value: scalar(state.logoPath))
        branding.set("accent_color", value: scalar(state.accentColor))
        branding.set("accent_dark", value: scalar(state.accentDark))
        root.set("branding", value: .mapping(branding))

        document.root = .mapping(root)
    }

    /// The EA's values set on the entry as read. A key its type does not use, and an integer
    /// key left empty, are removed (every copy), so none of them is read.
    private static func customEAValue(_ ea: ConfigCustomEA) -> YAMLCodec.YAMLValue {
        var entry = ea.source.mapping
        entry.set("name", value: scalar(ea.name))
        entry.set("column", value: scalar(ea.column))
        entry.set("type", value: scalar(ea.type))
        let typed: [(key: String, value: YAMLCodec.YAMLValue?)] = [
            ("true_value", ea.type == "boolean" ? scalar(ea.trueValue) : nil),
            ("warning_threshold", ea.type == "percentage" ? optionalInt(ea.warningThreshold) : nil),
            ("critical_threshold",
             ea.type == "percentage" ? optionalInt(ea.criticalThreshold) : nil),
            ("current_versions",
             ea.type == "version" ? .sequence(ea.currentVersions.map { scalar($0) }) : nil),
            ("warning_days", ea.type == "date" ? optionalInt(ea.warningDays) : nil),
        ]
        for (key, value) in typed {
            if let value {
                entry.set(key, value: value)
            } else {
                entry.entries.removeAll { $0.key == key }
            }
        }
        return .mapping(entry)
    }

    private static func sequenceMappings(
        _ root: YAMLCodec.YAMLMapping,
        _ key: String
    ) -> [YAMLCodec.YAMLMapping] {
        root.value(for: key)?.sequence?.compactMap(\.mapping) ?? []
    }

    private static func string(
        _ mapping: YAMLCodec.YAMLMapping,
        _ key: String,
        fallback: String = ""
    ) -> String {
        mapping.value(for: key)?.stringValue ?? fallback
    }

    private static func stringSequence(_ mapping: YAMLCodec.YAMLMapping, _ key: String) -> [String] {
        mapping.value(for: key)?.sequence?.compactMap(\.stringValue) ?? []
    }

    private static func scalar(_ value: String) -> YAMLCodec.YAMLValue {
        .scalar(.string(value))
    }

    /// An integer-typed key's value ONLY when the string parses to an Int; nil (the key is
    /// left out) for an empty or non-numeric value rather than `key: ""` — the engine
    /// decoder types these as `Int?`, and an empty string fails its decode ("value has the
    /// wrong type"). Omitting lets the engine fall back to its default. (This is the
    /// recurring "Configuration file problem" banner after the EA walkthrough adopts a
    /// percentage EA with no threshold set.)
    private static func optionalInt(_ value: String) -> YAMLCodec.YAMLValue? {
        Int(value.trimmingCharacters(in: .whitespaces)).map { .scalar(.int($0)) }
    }

    private static func intScalar(_ value: String) -> YAMLCodec.YAMLValue {
        if let int = Int(value.trimmingCharacters(in: .whitespaces)) {
            return .scalar(.int(int))
        }
        return .scalar(.string(value))
    }
}
