import Foundation

/// The four security controls a workspace's `security_policy` governs.
enum SecurityControl: String, CaseIterable, Sendable {
    case fileVault = "filevault", sip, firewall, gatekeeper
}

/// What a failing control means: a gap (`fail`), amber but not a gap (`warning`),
/// or not evaluated at all (`ignore`).
enum SecurityControlLevel: String, CaseIterable, Sendable {
    case fail, warning, ignore

    /// The one place a typed level is read: trimmed, case-insensitive, `_` and `-` read as
    /// spaces. Nil for anything that is not one of these spellings.
    static func parse(_ raw: String) -> SecurityControlLevel? {
        let text = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch text {
        case "fail", "failure", "gap": return .fail
        case "warning", "warn": return .warning
        case "ignore", "ignored", "not counted", "skip": return .ignore
        default: return nil
        }
    }
}

enum SecurityVerdict: Sendable, Equatable {
    case pass, fail, warning, ignored, unknown
}

/// Something in a hand-edited `security_policy:` block the app did not use as written.
/// `value` is what was typed (empty for an empty value, and for a key the app does not
/// read); `used` is what the app applied instead: a level, `the FileVault level`, or the
/// default for a block of the wrong shape. An empty `used` means the key is not read.
struct SecurityPolicyIssue: Sendable, Equatable {
    let keyPath: String
    let value: String
    let used: String
}

/// The workspace's `security_policy:` block. Absent, every control fails as it always
/// has and there is no hardware-encrypted FileVault rule.
struct SecurityControlPolicy: Sendable, Equatable, Decodable {
    var fileVault: SecurityControlLevel
    var sip: SecurityControlLevel
    var firewall: SecurityControlLevel
    var gatekeeper: SecurityControlLevel
    /// Level for FileVault off on a Mac whose internal volume is hardware-encrypted;
    /// nil uses `fileVault`.
    var fileVaultOffHardwareEncrypted: SecurityControlLevel?

    static let `default` = SecurityControlPolicy()

    init(
        fileVault: SecurityControlLevel = .fail,
        sip: SecurityControlLevel = .fail,
        firewall: SecurityControlLevel = .fail,
        gatekeeper: SecurityControlLevel = .fail,
        fileVaultOffHardwareEncrypted: SecurityControlLevel? = nil
    ) {
        self.fileVault = fileVault
        self.sip = sip
        self.firewall = firewall
        self.gatekeeper = gatekeeper
        self.fileVaultOffHardwareEncrypted = fileVaultOffHardwareEncrypted
    }

    private enum CodingKeys: String, CodingKey {
        case controls
        case fileVaultOffHardwareEncrypted = "filevault_off_hardware_encrypted"
    }

    private enum ControlKeys: String, CodingKey {
        case filevault, sip, firewall, gatekeeper
    }

    /// Never throws (the `AlertRule` pattern): a thrown error would fail the whole
    /// config.yaml decode, so a wrong shape or value falls back to the default part.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        let hardware = Self.decodedLevel(c, .fileVaultOffHardwareEncrypted)
        guard let controls = try? c.nestedContainer(keyedBy: ControlKeys.self, forKey: .controls)
        else {
            self.init(fileVaultOffHardwareEncrypted: hardware)
            return
        }
        self.init(
            fileVault: Self.decodedLevel(controls, .filevault) ?? .fail,
            sip: Self.decodedLevel(controls, .sip) ?? .fail,
            firewall: Self.decodedLevel(controls, .firewall) ?? .fail,
            gatekeeper: Self.decodedLevel(controls, .gatekeeper) ?? .fail,
            fileVaultOffHardwareEncrypted: hardware
        )
    }

    private static func decodedLevel<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>, _ key: Key
    ) -> SecurityControlLevel? {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return SecurityControlLevel.parse(raw)
    }

    func level(for control: SecurityControl) -> SecurityControlLevel {
        switch control {
        case .fileVault: fileVault
        case .sip: sip
        case .firewall: firewall
        case .gatekeeper: gatekeeper
        }
    }

    var usesHardwareRule: Bool {
        guard fileVault != .ignore else { return false }
        return fileVaultOffHardwareEncrypted == .warning || fileVaultOffHardwareEncrypted == .ignore
    }

    func hardwareRuleApplies(fileVaultReading: Bool?, hardwareEncrypted: Bool?) -> Bool {
        usesHardwareRule && fileVaultReading == false && hardwareEncrypted == true
    }

    // MARK: - Reading a value

    /// Jamf did not collect the value, the Mac cannot report it, or the value does not
    /// say whether the boot volume is encrypted ("Some Partitions Encrypted").
    private static let unknownMarkers = [
        "not collected", "not available", "not supported", "unknown", "pending",
        "some partitions",
    ]
    /// Checked before the true forms, because most negatives contain their positive
    /// word: "UNENCRYPTED", "NOT_ENCRYPTED", "Not Enabled", "inactive". A paused
    /// encryption stays paused until someone resumes it, so unlike ENCRYPTING it is off.
    private static let falseMarkers = [
        "not ", "no partitions", "disabled", "unencrypted", "inactive", "decrypt", "missing",
        "encrypting paused",
    ]
    private static let falseValues: Set<String> = ["false", "no", "0", "off", "none"]
    /// Gatekeeper reports its setting ("APP_STORE_AND_IDENTIFIED_DEVELOPERS"), not a yes or no.
    private static let trueMarkers = [
        "enabled", "encrypted", "escrowed", "installed", "active", "app store",
        "identified developers",
    ]
    private static let trueValues: Set<String> = ["true", "yes", "1", "on"]

    /// Whether a security value reads as on (true), off (false) or unmeasured (nil).
    /// FileVault mid-transition (ENCRYPTING, OPTIMIZING) or unable to report
    /// (INELIGIBLE, RESTART_NEEDED) reads nil.
    static func reading(_ raw: String?) -> Bool? {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
        if text.isEmpty || unknownMarkers.contains(where: { text.contains($0) }) { return nil }
        if let partitions = partitionReading(text) { return partitions }
        if falseValues.contains(text) || falseMarkers.contains(where: { text.contains($0) }) {
            return false
        }
        if trueValues.contains(text) || trueMarkers.contains(where: { text.contains($0) }) {
            return true
        }
        return nil
    }

    /// Jamf's CSV FileVault column is "encrypted/total partitions": on only when every
    /// partition is encrypted. Nil when the text is not of that form.
    private static func partitionReading(_ text: String) -> Bool? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        guard let encrypted = Int(parts[0]), let total = Int(parts[1]) else { return false }
        return encrypted == total && total > 0
    }

    // MARK: - Verdicts

    func verdict(
        for control: SecurityControl, reading: Bool?, hardwareEncrypted: Bool?
    ) -> SecurityVerdict {
        let controlLevel = level(for: control)
        guard controlLevel != .ignore else { return .ignored }
        guard let reading else { return .unknown }
        if reading { return .pass }
        if control == .fileVault,
           hardwareRuleApplies(fileVaultReading: reading, hardwareEncrypted: hardwareEncrypted),
           let hardwareLevel = fileVaultOffHardwareEncrypted {
            return Self.offVerdict(at: hardwareLevel)
        }
        return Self.offVerdict(at: controlLevel)
    }

    func verdict(
        for control: SecurityControl, value: String?, hardwareEncrypted: Bool?
    ) -> SecurityVerdict {
        verdict(for: control, reading: Self.reading(value), hardwareEncrypted: hardwareEncrypted)
    }

    private static func offVerdict(at level: SecurityControlLevel) -> SecurityVerdict {
        switch level {
        case .fail: .fail
        case .warning: .warning
        case .ignore: .ignored
        }
    }

    /// Controls at `fail` that read off. Nil when no evaluated control was measured,
    /// so a Mac the report knows nothing about is No Data rather than compliant.
    func gapCount(
        fileVault: Bool?, sip: Bool?, firewall: Bool?, gatekeeper: Bool?, hardwareEncrypted: Bool?
    ) -> Int? {
        let readings: [(SecurityControl, Bool?)] = [
            (.fileVault, fileVault), (.sip, sip), (.firewall, firewall), (.gatekeeper, gatekeeper),
        ]
        let evaluated = readings.filter { level(for: $0.0) != .ignore }
        guard evaluated.contains(where: { $0.1 != nil }) else { return nil }
        return evaluated.filter {
            verdict(for: $0.0, reading: $0.1, hardwareEncrypted: hardwareEncrypted) == .fail
        }.count
    }
}

extension ReportConfig {
    var resolvedSecurityPolicy: SecurityControlPolicy { securityPolicy ?? .default }
}
