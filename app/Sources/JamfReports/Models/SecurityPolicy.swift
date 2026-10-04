import Foundation

/// The four security controls a workspace's `security_policy` governs.
enum SecurityControl: String, CaseIterable, Sendable {
    case fileVault = "filevault", sip, firewall, gatekeeper

    var displayName: String {
        switch self {
        case .fileVault: "FileVault"
        case .sip: "System Integrity Protection"
        case .firewall: "Firewall"
        case .gatekeeper: "Gatekeeper"
        }
    }
}

/// What a failing control means: a gap (`fail`), amber but not a gap (`warning`),
/// or not evaluated at all (`ignore`).
enum SecurityControlLevel: String, CaseIterable, Sendable {
    case fail, warning, ignore

    var displayName: String {
        switch self {
        case .fail: "Fail"
        case .warning: "Warning"
        case .ignore: "Not counted"
        }
    }

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
/// has, there is no hardware-encrypted FileVault rule and the score uses the default weights.
struct SecurityControlPolicy: Sendable, Equatable, Decodable {
    var fileVault: SecurityControlLevel
    var sip: SecurityControlLevel
    var firewall: SecurityControlLevel
    var gatekeeper: SecurityControlLevel
    /// Level for FileVault off on a Mac whose internal volume is hardware-encrypted;
    /// nil uses `fileVault`.
    var fileVaultOffHardwareEncrypted: SecurityControlLevel?
    /// The Security Score's weights; nil uses `SecurityScoreWeights.defaultWeights`.
    var scoreWeights: SecurityScoreWeights?
    /// The name of the `security_agents` entry the score counts as the EDR agent
    /// (`security_policy.edr_agent`), trimmed. Nil, and a name that matches no agent, count the
    /// first named agent (`SecurityScoreInputs.edrAgent(in:)`); the other agents are shown and
    /// tracked but do not change the score.
    var edrAgent: String?
    /// The values an organization's own export uses for on and off, per control
    /// (`security_policy.on_values` / `off_values`), normalised by `normalizedValue` and never
    /// empty. A control with no entry reads by the built-in vocabulary alone.
    private(set) var onValues: [SecurityControl: Set<String>]
    private(set) var offValues: [SecurityControl: Set<String>]

    static let `default` = SecurityControlPolicy()

    /// `onValues` and `offValues` take the values as typed; they are stored normalised.
    init(
        fileVault: SecurityControlLevel = .fail,
        sip: SecurityControlLevel = .fail,
        firewall: SecurityControlLevel = .fail,
        gatekeeper: SecurityControlLevel = .fail,
        fileVaultOffHardwareEncrypted: SecurityControlLevel? = nil,
        scoreWeights: SecurityScoreWeights? = nil,
        edrAgent: String? = nil,
        onValues: [SecurityControl: [String]] = [:],
        offValues: [SecurityControl: [String]] = [:]
    ) {
        self.fileVault = fileVault
        self.sip = sip
        self.firewall = firewall
        self.gatekeeper = gatekeeper
        self.fileVaultOffHardwareEncrypted = fileVaultOffHardwareEncrypted
        self.scoreWeights = scoreWeights
        let agent = edrAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.edrAgent = agent?.isEmpty == false ? agent : nil
        self.onValues = Self.vocabulary(onValues)
        self.offValues = Self.vocabulary(offValues)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case controls
        case fileVaultOffHardwareEncrypted = "filevault_off_hardware_encrypted"
        case scoreWeights = "score_weights"
        case edrAgent = "edr_agent"
        case onValues = "on_values"
        case offValues = "off_values"
    }

    enum ControlKeys: String, CodingKey, CaseIterable {
        case filevault, sip, firewall, gatekeeper
    }

    /// A key under `score_weights`, named at run time from `SecurityScoreWeights.configSlots`.
    private struct WeightKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// The words under one `on_values` / `off_values` key: a string, or a list of them. A
    /// boolean reads as its text, because a quoted "True" arrives as one. An item of any other
    /// type is left out here; `SecurityPolicyConfigLoader.issues` reports it.
    private struct VocabularyWords: Decodable {
        let words: [String]

        init(from decoder: Decoder) throws {
            if let single = Self.word(in: decoder) {
                words = [single]
                return
            }
            guard var items = try? decoder.unkeyedContainer() else {
                words = []
                return
            }
            var found: [String] = []
            // `decode` always moves past the item, so this ends; a throwing one would not.
            while !items.isAtEnd {
                if let item = try? items.decode(Item.self), let word = item.word {
                    found.append(word)
                }
            }
            words = found
        }

        private struct Item: Decodable {
            let word: String?

            init(from decoder: Decoder) throws {
                word = VocabularyWords.word(in: decoder)
            }
        }

        private static func word(in decoder: Decoder) -> String? {
            guard let single = try? decoder.singleValueContainer() else { return nil }
            if let text = try? single.decode(String.self) { return text }
            return (try? single.decode(Bool.self)).map { $0 ? "true" : "false" }
        }
    }

    /// Never throws (the `AlertRule` pattern): a thrown error would fail the whole
    /// config.yaml decode, so a wrong shape or value falls back to the default part.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        let hardware = Self.decodedLevel(c, .fileVaultOffHardwareEncrypted)
        let weights = Self.decodedWeights(c)
        let agent = try? c.decodeIfPresent(String.self, forKey: .edrAgent)
        let on = Self.decodedVocabulary(c, .onValues)
        let off = Self.decodedVocabulary(c, .offValues)
        guard let controls = try? c.nestedContainer(keyedBy: ControlKeys.self, forKey: .controls)
        else {
            self.init(
                fileVaultOffHardwareEncrypted: hardware, scoreWeights: weights,
                edrAgent: agent, onValues: on, offValues: off)
            return
        }
        self.init(
            fileVault: Self.decodedLevel(controls, .filevault) ?? .fail,
            sip: Self.decodedLevel(controls, .sip) ?? .fail,
            firewall: Self.decodedLevel(controls, .firewall) ?? .fail,
            gatekeeper: Self.decodedLevel(controls, .gatekeeper) ?? .fail,
            fileVaultOffHardwareEncrypted: hardware,
            scoreWeights: weights,
            edrAgent: agent,
            onValues: on, offValues: off
        )
    }

    /// The values typed under each control of `on_values` or `off_values`; empty for a block
    /// that is absent or not a mapping, and for a control whose value is of the wrong shape.
    private static func decodedVocabulary(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> [SecurityControl: [String]] {
        guard let block = try? container.nestedContainer(keyedBy: ControlKeys.self, forKey: key)
        else { return [:] }
        var typed: [SecurityControl: [String]] = [:]
        for control in SecurityControl.allCases {
            if let controlKey = ControlKeys(rawValue: control.rawValue),
               let words = try? block.decodeIfPresent(VocabularyWords.self, forKey: controlKey) {
                typed[control] = words.words
            }
        }
        return typed
    }

    /// Normalised and without empty values, so an empty string can never match a blank cell.
    private static func vocabulary(
        _ typed: [SecurityControl: [String]]
    ) -> [SecurityControl: Set<String>] {
        typed.compactMapValues { words in
            let kept = Set(words.map { normalizedValue($0) }.filter { !$0.isEmpty })
            return kept.isEmpty ? nil : kept
        }
    }

    /// Nil for a block that is absent or not a mapping; otherwise every key the app reads,
    /// each at its typed weight or, when missing or unreadable, its default.
    private static func decodedWeights(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) -> SecurityScoreWeights? {
        guard let block = try? container.nestedContainer(
            keyedBy: WeightKey.self, forKey: .scoreWeights)
        else { return nil }
        return SecurityScoreWeights { slot in
            guard let key = WeightKey(stringValue: slot) else { return nil }
            // A fractional YAML scalar arrives as a string, an integer as a number
            // (`AlertRule.tolerantDouble`).
            if let number = try? block.decodeIfPresent(Double.self, forKey: key) {
                return scoreWeight(number)
            }
            return (try? block.decodeIfPresent(String.self, forKey: key))
                .flatMap { scoreWeight(typed: $0) }
        }
    }

    /// A typed weight is a number from 0 to 100; anything else is not read.
    static func scoreWeight(_ value: Double) -> Double? {
        (0...100).contains(value) ? value : nil
    }

    static func scoreWeight(typed raw: String) -> Double? {
        Double(raw.trimmingCharacters(in: .whitespaces)).flatMap { scoreWeight($0) }
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

    func setting(_ level: SecurityControlLevel, for control: SecurityControl) -> Self {
        var policy = self
        switch control {
        case .fileVault: policy.fileVault = level
        case .sip: policy.sip = level
        case .firewall: policy.firewall = level
        case .gatekeeper: policy.gatekeeper = level
        }
        return policy
    }

    /// A typed hardware level is applied as typed, stricter than FileVault's or not. It changes
    /// nothing when it equals FileVault's level, or when FileVault is not evaluated at all.
    var usesHardwareRule: Bool {
        guard fileVault != .ignore, let hardware = fileVaultOffHardwareEncrypted else {
            return false
        }
        return hardware != fileVault
    }

    /// Every control at fail and no hardware rule in use: the security rows are graded as with
    /// no policy. The score weights grade no control.
    var gradesLikeTheDefault: Bool {
        SecurityControl.allCases.allSatisfy { level(for: $0) == .fail } && !usesHardwareRule
    }

    func hardwareRuleApplies(fileVaultReading: Bool?, hardwareEncrypted: Bool?) -> Bool {
        usesHardwareRule && fileVaultReading == false && hardwareEncrypted == true
    }

    /// The rule applies and puts this Mac below FileVault's own level (a warning, or not
    /// counted). At `fail` the Mac is a plain FileVault failure, so nothing names it apart.
    func hardwareRuleLowers(fileVaultReading: Bool?, hardwareEncrypted: Bool?) -> Bool {
        fileVaultOffHardwareEncrypted != .fail
            && hardwareRuleApplies(
                fileVaultReading: fileVaultReading, hardwareEncrypted: hardwareEncrypted)
    }

    static let hardwareEncryptedFileVaultOffLabel = "FileVault off (hardware-encrypted)"
    /// For a pill or cell that already sits under a "FileVault" label.
    static let hardwareEncryptedFileVaultOffShortLabel = "Off (hardware-encrypted)"

    /// A FileVault value as the Devices screen shows it: a label above when the hardware
    /// rule lowers this Mac, so its amber or grey tone is explained; else the value itself.
    func fileVaultLabel(_ value: String, hardwareEncrypted: Bool?, short: Bool = false) -> String {
        let lowers = hardwareRuleLowers(
            fileVaultReading: reading(value, for: .fileVault), hardwareEncrypted: hardwareEncrypted)
        guard lowers else { return value }
        return short ? Self.hardwareEncryptedFileVaultOffShortLabel
            : Self.hardwareEncryptedFileVaultOffLabel
    }

    // MARK: - Reading a value

    /// Jamf did not collect the value, the Mac cannot report it, or the value does not
    /// say whether the boot volume is encrypted ("Some Partitions Encrypted").
    private static let unknownMarkers = [
        "not collected", "not available", "not supported", "unknown", "pending",
        "some partitions",
    ]
    /// Checked before the true forms, because most negatives contain their positive
    /// word: "UNENCRYPTED", "NOT_ENCRYPTED", "Not Enabled", "inactive", "Disconnected",
    /// "Unconnected". A paused encryption stays paused until someone resumes it, so unlike
    /// ENCRYPTING it is off.
    private static let falseMarkers = [
        "not ", "no partitions", "disabled", "unencrypted", "inactive", "decrypt", "missing",
        "encrypting paused", "disconnected", "unconnected",
    ]
    private static let falseValues: Set<String> = ["false", "no", "0", "off", "none"]
    /// Gatekeeper reports its setting ("APP_STORE_AND_IDENTIFIED_DEVELOPERS"), not a yes or no,
    /// and the firewall its strictest mode ("Block all incoming connections"). A CSV column an
    /// organization maps itself may use an agent's "Running" or "Connected".
    private static let trueMarkers = [
        "enabled", "encrypted", "escrowed", "installed", "active", "app store",
        "identified developers", "running", "connected", "block all incoming",
    ]
    private static let trueValues: Set<String> = ["true", "yes", "1", "on"]

    /// How a value is compared with a configured on or off value, and with the built-in
    /// vocabulary: trimmed, lowercase, `-` and `_` read as spaces.
    static func normalizedValue(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    /// Whether a security value reads as on (true), off (false) or unmeasured (nil), by the
    /// built-in vocabulary alone: for a value that is not one of the four controls, such as the
    /// bootstrap token. A control's own value reads through `reading(_:for:)`.
    /// FileVault mid-transition (ENCRYPTING, OPTIMIZING) or unable to report
    /// (INELIGIBLE, RESTART_NEEDED) reads nil. `-` and `_` read as spaces.
    static func reading(_ raw: String?) -> Bool? {
        builtInReading(normalizedValue(raw))
    }

    /// A control's value as on, off or unmeasured. The workspace's own `off_values` come first,
    /// then its `on_values` (so a value in both reads off), then the built-in vocabulary. A
    /// configured value matches the whole value, never part of it.
    func reading(_ raw: String?, for control: SecurityControl) -> Bool? {
        let text = Self.normalizedValue(raw)
        if offValues[control]?.contains(text) == true { return false }
        if onValues[control]?.contains(text) == true { return true }
        return Self.builtInReading(text)
    }

    private static func builtInReading(_ text: String) -> Bool? {
        if text.isEmpty || unknownMarkers.contains(where: { text.contains($0) }) { return nil }
        if let partitions = partitionReading(text) { return partitions }
        if falseValues.contains(text) || falseMarkers.contains(where: { text.contains($0) })
            || negatesATrueWord(text) {
            return false
        }
        if trueValues.contains(text) || trueMarkers.contains(where: { text.contains($0) }) {
            return true
        }
        return nil
    }

    /// A true word with `not` or `un` joined on: "NotConnected", "Uninstalled", "Unescrowed".
    private static func negatesATrueWord(_ text: String) -> Bool {
        trueMarkers.contains { text.hasPrefix("not" + $0) || text.contains("un" + $0) }
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
        verdict(
            for: control, reading: reading(value, for: control),
            hardwareEncrypted: hardwareEncrypted)
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

    /// The score's weights with FileVault, SIP or Firewall at zero when set to `ignore`, so
    /// the calculator leaves that control out without listing it as missing data.
    func effectiveScoreWeights(_ base: SecurityScoreWeights) -> SecurityScoreWeights {
        var weights = base
        if fileVault == .ignore { weights.fileVault = 0 }
        if sip == .ignore { weights.sip = 0 }
        if firewall == .ignore { weights.firewall = 0 }
        return weights
    }

    /// What every score uses: the workspace's weights, or the defaults, less the controls
    /// that are not counted.
    var resolvedScoreWeights: SecurityScoreWeights {
        effectiveScoreWeights(scoreWeights ?? .defaultWeights)
    }
}

extension SecurityScoreWeights {
    /// The keys under `security_policy.score_weights`, in the order the Scoring tab lists them.
    nonisolated(unsafe) static let configSlots:
        [(key: String, path: WritableKeyPath<SecurityScoreWeights, Double>)] = [
            ("filevault", \.fileVault), ("sip", \.sip), ("firewall", \.firewall),
            ("edr_agent", \.edrAgent), ("mscp", \.mscp), ("xprotect", \.xprotect),
            ("cve", \.cve), ("secure_boot", \.secureBoot),
        ]

    /// The defaults, with each slot the lookup has a weight for replaced.
    init(reading weight: (String) -> Double?) {
        self = .defaultWeights
        for slot in Self.configSlots {
            if let value = weight(slot.key) { self[keyPath: slot.path] = value }
        }
    }

    /// The weight under a `score_weights` key; nil for a key the app does not read.
    func weight(forConfigKey key: String) -> Double? {
        Self.configSlots.first { $0.key == key }.map { self[keyPath: $0.path] }
    }

    /// Whole numbers from 0 to 100, as the block stores them; a weight that is not a
    /// number reads as its default.
    func rounded() -> SecurityScoreWeights {
        var copy = self
        for slot in Self.configSlots {
            let value = self[keyPath: slot.path].rounded()
            copy[keyPath: slot.path] = value.isNaN
                ? Self.defaultWeights[keyPath: slot.path] : min(max(value, 0), 100)
        }
        return copy
    }
}

extension ReportConfig {
    var resolvedSecurityPolicy: SecurityControlPolicy { securityPolicy ?? .default }
}
