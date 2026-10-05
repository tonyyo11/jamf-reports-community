import Foundation

/// Best-effort read of a profile's `security_policy:` block. Never throws: a missing
/// workspace or file degrades to `.default`, today's behaviour. Mirrors `ChartsConfigLoader`,
/// except that an undecodable config.yaml is logged: falling back changes the gap counts.
enum SecurityPolicyConfigLoader {
    static func load(profile: String) -> SecurityControlPolicy {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return .default }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        do {
            return try ConfigLoader.load(from: url).resolvedSecurityPolicy
        } catch {
            let file = url.lastPathComponent
            let reason = error.localizedDescription
            AppLogger.report.warning("""
                Security policy: could not decode \(file, privacy: .public), using the default \
                policy: \(reason, privacy: .private)
                """)
            return .default
        }
    }

    // MARK: - What the block says that `load` did not use as written

    private static let blockPath = "security_policy"
    static let controlsPath = "security_policy.controls"
    static let hardwarePath = "security_policy.filevault_off_hardware_encrypted"
    static let factorsPath = "security_policy.score_factors"
    static let edrAgentPath = "security_policy.edr_agent"
    static let onValuesPath = "security_policy.on_values"
    static let offValuesPath = "security_policy.off_values"

    /// Key paths of the blocks that hold other settings: an issue at one of them is about
    /// the block's shape. Any other issue with a `used` is about a typed level, or when
    /// `isFactorPath` holds, a `score_factors` entry, or when `isVocabularyPath` holds, a
    /// typed value.
    static let blockKeyPaths: Set<String> = [
        blockPath, controlsPath, onValuesPath, offValuesPath,
    ]

    /// `score_factors` itself, or one of its entries (`score_factors[2]`, from 0 as
    /// `ConfigSchema` numbers list items).
    static func isFactorPath(_ keyPath: String) -> Bool {
        keyPath == factorsPath || keyPath.hasPrefix(factorsPath + "[")
    }

    /// A key under `on_values` or `off_values`: one issue per value that is not used.
    static func isVocabularyPath(_ keyPath: String) -> Bool {
        keyPath.hasPrefix(onValuesPath + ".") || keyPath.hasPrefix(offValuesPath + ".")
    }

    /// `used` of a vocabulary value the decoder left out.
    static let vocabularySkipped = "skipped"
    /// `used` of an `on_values` value that `off_values` also lists for the control.
    static let vocabularyReadAsOff = "off"

    /// Reads the file `load(profile:)` reads and reports, without throwing, each value or key
    /// it did not use as written. An accepted synonym is not an issue. `used` is taken from
    /// the policy the decoder produced, so the two cannot disagree.
    static func issues(profile: String) -> [SecurityPolicyIssue] {
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let text = try? String(
                  contentsOf: workspace.appendingPathComponent("config.yaml"), encoding: .utf8),
              let root = (try? YAMLCodec.decode(text))?.root.mapping,
              let block = settings(root).first(where: { $0.key == blockPath })?.node
        else { return [] }
        let applied = (try? ConfigLoader.loadFromString(text))?.resolvedSecurityPolicy
            ?? .default
        return blockIssues(block, applied: applied)
    }

    private static func blockIssues(
        _ block: YAMLCodec.YAMLValue, applied: SecurityControlPolicy
    ) -> [SecurityPolicyIssue] {
        guard case .mapping(let mapping) = block else {
            return shapeIssues(blockPath, block, used: "the default policy")
        }
        let hardwareUsed = applied.fileVaultOffHardwareEncrypted?.rawValue ?? "the FileVault level"
        return settings(mapping).flatMap { key, node -> [SecurityPolicyIssue] in
            switch key {
            case "controls":
                controlsIssues(node, applied: applied)
            case "filevault_off_hardware_encrypted":
                levelIssues(hardwarePath, node, used: hardwareUsed)
            case "score_factors":
                factorsIssues(node)
            case "edr_agent":
                edrAgentIssues(node)
            case "on_values":
                vocabularyIssues(
                    onValuesPath, node, kept: applied.onValues, overriddenBy: applied.offValues)
            case "off_values":
                vocabularyIssues(offValuesPath, node, kept: applied.offValues, overriddenBy: [:])
            default:
                unknownKeyIssues("\(blockPath).\(ConfigSchema.displayText(key))")
            }
        }
    }

    /// A name is text; anything else is read as no choice, so the first agent counts. A name
    /// that matches no agent needs the agent list, so `ConfigDoctorService` reports it.
    private static func edrAgentIssues(_ node: YAMLCodec.YAMLValue) -> [SecurityPolicyIssue] {
        switch node {
        case .scalar(.null): return []
        case .scalar(.string): return []
        default:
            return [SecurityPolicyIssue(
                keyPath: edrAgentPath, value: ConfigSchema.displayText(typedText(node)),
                used: "the first agent")]
        }
    }

    private static func controlsIssues(
        _ node: YAMLCodec.YAMLValue, applied: SecurityControlPolicy
    ) -> [SecurityPolicyIssue] {
        guard case .mapping(let controls) = node else {
            return shapeIssues(controlsPath, node, used: "fail for every control")
        }
        return settings(controls).flatMap { key, node -> [SecurityPolicyIssue] in
            let path = "\(controlsPath).\(ConfigSchema.displayText(key))"
            guard let control = SecurityControl(rawValue: key) else {
                return unknownKeyIssues(path)
            }
            return levelIssues(path, node, used: applied.level(for: control).rawValue)
        }
    }

    /// `score_factors` is a list; each entry the decoder skipped, or read other than as typed,
    /// is one issue at `score_factors[N]` (from 0) with what happened in `used`.
    private static func factorsIssues(_ node: YAMLCodec.YAMLValue) -> [SecurityPolicyIssue] {
        guard case .sequence(let items) = node else {
            if case .scalar(.null) = node { return [] }
            return [SecurityPolicyIssue(
                keyPath: factorsPath, value: ConfigSchema.displayText(typedText(node)),
                used: "the default factors, since this is not a list")]
        }
        var seen: [String: Int] = [:]
        var issues: [SecurityPolicyIssue] = []
        for (index, item) in items.enumerated() {
            let path = "\(factorsPath)[\(index)]"
            let (found, key) = factorIssues(path, item)
            issues += found
            if let key {
                if let earlier = seen[key] {
                    issues.append(SecurityPolicyIssue(
                        keyPath: "\(factorsPath)[\(earlier)]", value: displayText(key),
                        used: "replaced by score_factors[\(index)], which lists it again"))
                }
                seen[key] = index
            }
        }
        return issues
    }

    /// The issues of one entry, and the key the decoder kept it under (nil when skipped).
    private static func factorIssues(
        _ path: String, _ item: YAMLCodec.YAMLValue
    ) -> (issues: [SecurityPolicyIssue], key: String?) {
        guard case .mapping(let entry) = item else {
            return ([SecurityPolicyIssue(
                keyPath: path, value: ConfigSchema.displayText(typedText(item)),
                used: "skipped: an entry needs factor and weight")], nil)
        }
        let fields = Dictionary(settings(entry).map { ($0.key, $0.node) }) { _, last in last }
        var issues = settings(entry).compactMap { key, _ -> SecurityPolicyIssue? in
            SecurityControlPolicy.FactorKeys(rawValue: key) == nil
                ? unknownKeyIssues("\(path).\(ConfigSchema.displayText(key))").first : nil
        }
        let typedKind = fields["factor"].map(typedText) ?? ""
        guard let kind = SecurityControlPolicy.factorKind(typed: typedKind) else {
            let known = SecurityScoreFactor.Kind.allCases.map(\.rawValue).joined(separator: ", ")
            issues.append(SecurityPolicyIssue(
                keyPath: path, value: displayText(typedKind),
                used: "skipped: factor is one of \(known)"))
            return (issues, nil)
        }
        guard let weightNode = fields["weight"], case .scalar = weightNode,
              SecurityControlPolicy.scoreWeight(typed: typedText(weightNode)) != nil else {
            issues.append(SecurityPolicyIssue(
                keyPath: path, value: displayText(fields["weight"].map(typedText) ?? ""),
                used: "skipped: weight is a number from 0 to 100"))
            return (issues, nil)
        }
        let name = kind == .agent ? fields["agent"] : kind == .mscp ? fields["baseline"] : nil
        let target = name.flatMap { $0.stringValue }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .agent, target?.isEmpty != false {
            issues.append(SecurityPolicyIssue(
                keyPath: path, value: displayText(typedKind),
                used: "skipped: an agent entry needs the agent's name under agent"))
            return (issues, nil)
        }
        issues += graceIssues(path, kind: kind, fields["grace_days"])
        let key = SecurityScoreFactor(kind, weight: 1, target: target).key
        return (issues, key)
    }

    private static func graceIssues(
        _ path: String, kind: SecurityScoreFactor.Kind, _ node: YAMLCodec.YAMLValue?
    ) -> [SecurityPolicyIssue] {
        guard let node else { return [] }
        guard let days = kind.defaultGraceDays else {
            return [SecurityPolicyIssue(
                keyPath: "\(path).grace_days", value: displayText(typedText(node)),
                used: "not read: \(kind.rawValue) has no grace period")]
        }
        let typed = Int(typedText(node).trimmingCharacters(in: .whitespaces))
        if case .scalar = node, let typed, SecurityControlPolicy.graceDays(typed) != nil {
            return []
        }
        return [SecurityPolicyIssue(
            keyPath: "\(path).grace_days", value: displayText(typedText(node)),
            used: "\(days) days, since grace_days is a whole number from 0 to 365")]
    }

    /// A value the decoder did not keep (not text, or empty) is an issue at its control's key
    /// path, and so is an `on_values` value that `overriddenBy` (the `off_values` the decoder
    /// kept) lists too. `kept` is what the decoder produced, so the two cannot disagree.
    private static func vocabularyIssues(
        _ path: String, _ node: YAMLCodec.YAMLValue,
        kept: [SecurityControl: Set<String>], overriddenBy: [SecurityControl: Set<String>]
    ) -> [SecurityPolicyIssue] {
        guard case .mapping(let controls) = node else {
            return shapeIssues(path, node, used: "the built-in values only")
        }
        return settings(controls).flatMap { key, node -> [SecurityPolicyIssue] in
            let keyPath = "\(path).\(ConfigSchema.displayText(key))"
            guard let control = SecurityControl(rawValue: key) else {
                return unknownKeyIssues(keyPath)
            }
            // One value is one word, a list holds one per item; a key with no value is one
            // empty word.
            let (keptHere, overriddenHere) = (kept[control] ?? [], overriddenBy[control] ?? [])
            return (node.sequence ?? [node]).compactMap {
                vocabularyIssue(keyPath, $0, kept: keptHere, overriddenBy: overriddenHere)
            }
        }
    }

    private static func vocabularyIssue(
        _ keyPath: String, _ word: YAMLCodec.YAMLValue, kept: Set<String>,
        overriddenBy: Set<String>
    ) -> SecurityPolicyIssue? {
        let shown = ConfigSchema.displayText(typedText(word))
        let normalized = SecurityControlPolicy.normalizedValue(vocabularyText(word))
        guard kept.contains(normalized) else {
            return SecurityPolicyIssue(keyPath: keyPath, value: shown, used: vocabularySkipped)
        }
        return overriddenBy.contains(normalized)
            ? SecurityPolicyIssue(keyPath: keyPath, value: shown, used: vocabularyReadAsOff)
            : nil
    }

    /// A number is not text: the decoder reads a word as a string or a boolean.
    private static func vocabularyText(_ word: YAMLCodec.YAMLValue) -> String? {
        guard case .scalar(let scalar) = word else { return nil }
        switch scalar {
        case .string, .bool: return word.stringValue
        case .int, .null: return nil
        }
    }

    /// Nothing is echoed for a key the app does not read, so `value` and `used` are empty.
    private static func unknownKeyIssues(_ path: String) -> [SecurityPolicyIssue] {
        [SecurityPolicyIssue(keyPath: path, value: "", used: "")]
    }

    private static func levelIssues(
        _ path: String, _ node: YAMLCodec.YAMLValue, used: String
    ) -> [SecurityPolicyIssue] {
        if case .scalar = node, SecurityControlLevel.parse(typedText(node)) != nil { return [] }
        return [SecurityPolicyIssue(
            keyPath: path, value: ConfigSchema.displayText(typedText(node)), used: used)]
    }

    /// A block holds settings, so anything but a mapping is the wrong shape. An empty value
    /// (null) is simply an empty block.
    private static func shapeIssues(
        _ path: String, _ node: YAMLCodec.YAMLValue, used: String
    ) -> [SecurityPolicyIssue] {
        switch node {
        case .mapping, .scalar(.null):
            []
        default:
            [SecurityPolicyIssue(
                keyPath: path, value: ConfigSchema.displayText(typedText(node)), used: used)]
        }
    }

    /// Each key once, in file order, with the value the decoder sees: the last of a repeated
    /// key, because the JSON dictionary it decodes from keeps the last.
    private static func settings(
        _ mapping: YAMLCodec.YAMLMapping
    ) -> [(key: String, node: YAMLCodec.YAMLValue)] {
        var order: [String] = []
        var last: [String: YAMLCodec.YAMLValue] = [:]
        for entry in mapping.entries {
            if last.updateValue(entry.value, forKey: entry.key) == nil { order.append(entry.key) }
        }
        return order.compactMap { key in last[key].map { (key, $0) } }
    }

    private static func typedText(_ node: YAMLCodec.YAMLValue) -> String {
        switch node {
        case .scalar: node.stringValue ?? ""
        case .sequence(let items): "[" + items.map(typedText).joined(separator: ", ") + "]"
        case .mapping: "{…}"
        }
    }

    /// Text taken from the file, safe to show: control and format characters (a pasted escape
    /// sequence, a right-to-left override) and line breaks removed, capped at 40 characters.
    static func displayText(_ raw: String) -> String {
        let kept = stripped(raw)
        return kept.count > 40 ? String(kept.prefix(39)) + "…" : kept
    }

    /// `displayText` without the cap, for a key path that is already built from capped parts.
    static func stripped(_ raw: String) -> String {
        let hidden = CharacterSet.controlCharacters.union(.newlines)
        return String(String.UnicodeScalarView(
            raw.unicodeScalars.filter { !hidden.contains($0) }))
    }
}

/// Scoped write-back for the Config → Scoring cards. Like `ChartsConfigWriter` it reads the
/// existing mapping and sets individual keys, outside `ConfigService`'s managed keys, so a
/// key the app does not read and every other top-level block survive a save.
///
/// A save writes only the setting it names, from what the file holds now, never from the
/// caller's copy of the policy: a copy that is stale, or that fell back to the default
/// because something else in config.yaml did not decode, cannot overwrite a value an operator
/// typed for another key. `score_weights` writes only the weights the file does not already
/// yield.
enum SecurityPolicyConfigWriter {
    /// One part of the `security_policy` block.
    enum Setting {
        case level(SecurityControlLevel, for: SecurityControl)
        /// Nil removes the key, so FileVault's own level applies.
        case hardwareLevel(SecurityControlLevel?)
        /// The whole list, as the Scoring tab edits it; nil removes the key, so the default
        /// factors apply.
        case scoreFactors([SecurityScoreFactor]?)
        /// The agent counted as EDR; nil removes the key, so the first agent counts.
        case edrAgent(String?)
    }

    enum WriteError: Error, LocalizedError {
        case invalidProfile(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            }
        }
    }

    private static let blockKey = "security_policy"
    private static let controlsKey = "controls"
    private static let hardwareKey = "filevault_off_hardware_encrypted"
    private static let factorsKey = "score_factors"
    private static let edrAgentKey = "edr_agent"

    @discardableResult
    static func save(
        _ setting: Setting, profile: String
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        return try ConfigService.saveBlock(key: blockKey, profile: profile) { root in
            var block = lastValue(of: blockKey, in: root)?.mapping ?? .init(entries: [])
            apply(setting, to: &block)
            assign(.mapping(block), to: blockKey, in: &root)
        }
    }

    /// Sets `setting` on the `security_policy` block. Internal so `ConfigEditedKeys` can read
    /// the keys the Scoring tab writes off it.
    static func apply(_ setting: Setting, to block: inout YAMLCodec.YAMLMapping) {
        switch setting {
        case .level(let level, let control):
            var controls = lastValue(of: controlsKey, in: block)?.mapping ?? .init(entries: [])
            assign(.scalar(.string(level.rawValue)), to: control.rawValue, in: &controls)
            assign(.mapping(controls), to: controlsKey, in: &block)
        case .hardwareLevel(let level):
            if let level {
                assign(.scalar(.string(level.rawValue)), to: hardwareKey, in: &block)
            } else {
                block.entries.removeAll { $0.key == hardwareKey }
            }
        case .scoreFactors(let factors):
            guard let factors else {
                block.entries.removeAll { $0.key == factorsKey }
                return
            }
            let existing = lastValue(of: factorsKey, in: block)?.sequence ?? []
            assign(.sequence(factors.map { entry($0, keeping: existing) }),
                   to: factorsKey, in: &block)
        case .edrAgent(let name):
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                assign(.scalar(.string(name)), to: edrAgentKey, in: &block)
            } else {
                block.entries.removeAll { $0.key == edrAgentKey }
            }
        }
    }

    /// One `score_factors` entry: `factor` and `weight`, then the name or grace period the kind
    /// takes. The file's last entry for the same factor keeps its other keys and their order, so
    /// a key typed by hand survives a save. A whole weight is written as a number, a fractional
    /// one as text, which the decoder reads back.
    static func entry(
        _ factor: SecurityScoreFactor, keeping existing: [YAMLCodec.YAMLValue] = []
    ) -> YAMLCodec.YAMLValue {
        var entry = existing.compactMap(\.mapping).last { typedKey($0) == factor.key }
            ?? .init(entries: [])
        let weight = min(max(factor.weight, 0), 100)
        assign(.scalar(.string(factor.kind.rawValue)), to: "factor", in: &entry)
        assign(weight == weight.rounded()
               ? .scalar(.int(Int(weight))) : .scalar(.string(String(format: "%g", weight))),
               to: "weight", in: &entry)
        let targetKey = factor.kind == .agent ? "agent" : "baseline"
        if let target = factor.target {
            assign(.scalar(.string(target)), to: targetKey, in: &entry)
        } else if factor.kind.takesTarget {
            entry.entries.removeAll { $0.key == targetKey }
        }
        if let days = factor.graceDays {
            assign(.scalar(.int(days)), to: "grace_days", in: &entry)
        } else {
            entry.entries.removeAll { $0.key == "grace_days" }
        }
        return .mapping(entry)
    }

    /// The factor a typed entry decodes as, or nil when it names none.
    private static func typedKey(_ entry: YAMLCodec.YAMLMapping) -> String? {
        guard let kind = entry.value(for: "factor")?.stringValue
            .flatMap(SecurityControlPolicy.factorKind(typed:)) else { return nil }
        let name = kind == .agent ? entry.value(for: "agent")
            : kind == .mscp ? entry.value(for: "baseline") : nil
        return SecurityScoreFactor(kind, weight: 1, target: name?.stringValue).key
    }

    /// What the decoder sees for a repeated key: the last entry.
    private static func lastValue(
        of key: String, in mapping: YAMLCodec.YAMLMapping
    ) -> YAMLCodec.YAMLValue? {
        mapping.entries.last { $0.key == key }?.value
    }

    /// Sets the key where it first appears and drops any repeat, so the entry the decoder
    /// reads is the one set.
    private static func assign(
        _ value: YAMLCodec.YAMLValue, to key: String, in mapping: inout YAMLCodec.YAMLMapping
    ) {
        let position = mapping.entries.firstIndex { $0.key == key } ?? mapping.entries.count
        mapping.entries.removeAll { $0.key == key }
        mapping.entries.insert(.init(key: key, value: value), at: position)
    }
}
