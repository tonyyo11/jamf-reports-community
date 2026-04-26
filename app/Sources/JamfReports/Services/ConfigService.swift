import Foundation

struct ConfigSecurityAgent: Identifiable, Equatable, Sendable {
    var id: String { "\(name)|\(column)|\(connectedValue)" }
    var name: String
    var column: String
    var connectedValue: String
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
}

struct ConfigState: Equatable, Sendable {
    var columns: [String: String]
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
    var exportPptx: Bool
    var orgName: String
    var logoPath: String
    var accentColor: String
    var accentDark: String

    static let columnKeys = [
        "computer_name", "serial_number", "operating_system", "last_checkin", "department",
        "manager", "email", "filevault", "sip", "firewall", "gatekeeper", "secure_boot",
        "bootstrap_token", "disk_percent_full", "architecture", "model", "last_enrollment",
        "mdm_expiry",
    ]

    static let defaultState = ConfigState(
        columns: [
            "computer_name": "Computer Name",
            "serial_number": "Serial Number",
            "operating_system": "Operating System Version",
            "last_checkin": "Last Check-in",
            "department": "Department",
            "manager": "Manager",
            "email": "Email Address",
            "filevault": "FileVault 2 - Status",
            "sip": "System Integrity Protection",
            "firewall": "Firewall Enabled",
            "gatekeeper": "Gatekeeper",
            "secure_boot": "Secure Boot Level",
            "bootstrap_token": "Bootstrap Token Escrowed",
            "disk_percent_full": "Boot Drive Percentage Full",
            "architecture": "Architecture",
            "model": "Model",
            "last_enrollment": "Last Enrollment",
            "mdm_expiry": "MDM Profile Expiration Date",
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
        exportPptx: false,
        orgName: "",
        logoPath: "",
        accentColor: "#2D5EA2",
        accentDark: "#004165"
    )
}

struct LoadedConfig: Sendable {
    var document: YAMLCodec.YAMLDocument
    var state: ConfigState
}

enum ConfigService {
    enum ConfigError: Error, LocalizedError {
        case invalidProfile(String)
        case pathTraversal
        case symlinkDestination(URL)
        case missingConfig(URL)
        case credentialKey(String)
        case invalidTopLevel

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            case .pathTraversal: "Refusing config path with a '..' component."
            case .symlinkDestination(let url): "Refusing to write symlink: \(url.path)"
            case .missingConfig(let url): "No config.yaml at \(url.path)"
            case .credentialKey(let key): "Refusing to load credential-shaped key: \(key)"
            case .invalidTopLevel: "config.yaml must contain a top-level mapping."
            }
        }
    }

    private static let managedTopLevelKeys: Set<String> = [
        "columns", "security_agents", "custom_eas", "thresholds", "compliance",
        "platform", "output", "branding",
    ]

    static func load(profile: String) throws -> LoadedConfig {
        let url = try configURL(for: profile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.missingConfig(url)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let document = try YAMLCodec.decode(text)
        try rejectCredentialKeys(in: document.root)
        return LoadedConfig(document: document, state: state(from: document))
    }

    static func save(
        profile: String,
        state: ConfigState,
        existingDocument: YAMLCodec.YAMLDocument?
    ) throws -> YAMLCodec.YAMLDocument {
        let url = try configURL(for: profile)
        try rejectSymlinkDestination(url)

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
        apply(state: state, to: &document)
        let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: managedTopLevelKeys)

        let tempURL = directory.appendingPathComponent(".config.yaml.\(UUID().uuidString).tmp")
        try encoded.write(to: tempURL, atomically: true, encoding: .utf8)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: Data())
        }
        _ = try manager.replaceItemAt(url, withItemAt: tempURL)

        return try YAMLCodec.decode(encoded)
    }

    static func configURL(for profile: String) throws -> URL {
        guard ProfileService.isValid(profile) else {
            throw ConfigError.invalidProfile(profile)
        }

        let root = ProfileService.workspacesRoot()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let workspace = root
            .appendingPathComponent(profile, isDirectory: true)
            .standardizedFileURL
        let config = workspace
            .appendingPathComponent("config.yaml", isDirectory: false)
            .standardizedFileURL

        guard !config.pathComponents.contains(where: { $0.contains("..") }) else {
            throw ConfigError.pathTraversal
        }
        return config
    }

    private static func rejectSymlinkDestination(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
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

        state.securityAgents = sequenceMappings(root, "security_agents").map {
            ConfigSecurityAgent(
                name: string($0, "name"),
                column: string($0, "column"),
                connectedValue: string($0, "connected_value")
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
                warningDays: string($0, "warning_days")
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
            state.exportPptx = output.value(for: "export_pptx")?.boolValue ?? state.exportPptx
        }

        if let branding = root.value(for: "branding")?.mapping {
            state.orgName = string(branding, "org_name")
            state.logoPath = string(branding, "logo_path")
            state.accentColor = string(branding, "accent_color", fallback: state.accentColor)
            state.accentDark = string(branding, "accent_dark", fallback: state.accentDark)
        }

        return state
    }

    private static func apply(state: ConfigState, to document: inout YAMLCodec.YAMLDocument) {
        var root = document.root.mapping ?? .init(entries: [])

        var columns = root.value(for: "columns")?.mapping ?? .init(entries: [])
        for key in ConfigState.columnKeys {
            columns.set(key, value: scalar(state.columns[key] ?? ""))
        }
        root.set("columns", value: .mapping(columns))

        root.set("security_agents", value: .sequence(state.securityAgents.map { agent in
            .mapping(.init(entries: [
                .init(key: "name", value: scalar(agent.name)),
                .init(key: "column", value: scalar(agent.column)),
                .init(key: "connected_value", value: scalar(agent.connectedValue)),
            ]))
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
        output.set("export_pptx", value: .scalar(.bool(state.exportPptx)))
        root.set("output", value: .mapping(output))

        var branding = root.value(for: "branding")?.mapping ?? .init(entries: [])
        branding.set("org_name", value: scalar(state.orgName))
        branding.set("logo_path", value: scalar(state.logoPath))
        branding.set("accent_color", value: scalar(state.accentColor))
        branding.set("accent_dark", value: scalar(state.accentDark))
        root.set("branding", value: .mapping(branding))

        document.root = .mapping(root)
    }

    private static func customEAValue(_ ea: ConfigCustomEA) -> YAMLCodec.YAMLValue {
        var entries: [YAMLCodec.YAMLEntry] = [
            .init(key: "name", value: scalar(ea.name)),
            .init(key: "column", value: scalar(ea.column)),
            .init(key: "type", value: scalar(ea.type)),
        ]
        switch ea.type {
        case "boolean":
            entries.append(.init(key: "true_value", value: scalar(ea.trueValue)))
        case "percentage":
            entries.append(.init(key: "warning_threshold", value: intScalar(ea.warningThreshold)))
            entries.append(.init(key: "critical_threshold", value: intScalar(ea.criticalThreshold)))
        case "version":
            entries.append(.init(
                key: "current_versions",
                value: .sequence(ea.currentVersions.map { scalar($0) })
            ))
        case "date":
            entries.append(.init(key: "warning_days", value: intScalar(ea.warningDays)))
        default:
            break
        }
        return .mapping(.init(entries: entries))
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

    private static func intScalar(_ value: String) -> YAMLCodec.YAMLValue {
        if let int = Int(value.trimmingCharacters(in: .whitespaces)) {
            return .scalar(.int(int))
        }
        return .scalar(.string(value))
    }
}
