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
    private static let weightsPath = "security_policy.score_weights"

    /// Key paths of the blocks that hold other settings: an issue at one of them is about
    /// the block's shape. Any other issue with a `used` is about a typed level, or when
    /// `isWeightPath` holds, a typed weight.
    static let blockKeyPaths: Set<String> = [blockPath, controlsPath, weightsPath]

    static func isWeightPath(_ keyPath: String) -> Bool {
        keyPath.hasPrefix(weightsPath + ".")
    }

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
            case "score_weights":
                weightsIssues(node, applied: applied)
            default:
                unknownKeyIssues("\(blockPath).\(ConfigSchema.displayText(key))")
            }
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

    private static func weightsIssues(
        _ node: YAMLCodec.YAMLValue, applied: SecurityControlPolicy
    ) -> [SecurityPolicyIssue] {
        guard case .mapping(let weights) = node else {
            return shapeIssues(weightsPath, node, used: "the default weights")
        }
        let used = applied.scoreWeights ?? .defaultWeights
        return settings(weights).flatMap { key, node -> [SecurityPolicyIssue] in
            let path = "\(weightsPath).\(displayText(key))"
            guard let weight = used.weight(forConfigKey: key) else {
                return unknownKeyIssues(path)
            }
            if case .scalar = node,
               SecurityControlPolicy.scoreWeight(typed: typedText(node)) != nil { return [] }
            return [SecurityPolicyIssue(
                keyPath: path, value: displayText(typedText(node)),
                used: String(format: "%g", weight))]
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
        /// Nil removes the block, so the default weights apply.
        case scoreWeights(SecurityScoreWeights?)
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
    private static let weightsKey = "score_weights"

    static func save(_ setting: Setting, profile: String) throws {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            throw WriteError.invalidProfile(profile)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let configURL = workspace.appendingPathComponent("config.yaml")

        var document: YAMLCodec.YAMLDocument
        if manager.fileExists(atPath: configURL.path) {
            document = try YAMLCodec.decode(String(contentsOf: configURL, encoding: .utf8))
        } else {
            document = YAMLCodec.emptyDocument()
        }
        // `decode` and `emptyDocument` yield a mapping, so this is not a reachable failure.
        guard case .mapping(var root) = document.root else {
            throw YAMLCodec.CodecError.invalidTopLevel
        }

        let existing = lastValue(of: blockKey, in: root)?.mapping ?? .init(entries: [])
        var block = existing
        apply(setting, to: &block)
        // Nothing to write: leave the file, and any comments in the block, as it is.
        guard block != existing else { return }
        assign(.mapping(block), to: blockKey, in: &root)
        document.root = .mapping(root)

        let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: [blockKey])
        let tempURL = workspace.appendingPathComponent(".config.yaml.\(UUID().uuidString).tmp")
        try encoded.write(to: tempURL, atomically: true, encoding: .utf8)
        if !manager.fileExists(atPath: configURL.path) {
            manager.createFile(atPath: configURL.path, contents: Data())
        }
        _ = try manager.replaceItemAt(configURL, withItemAt: tempURL)
    }

    private static func apply(_ setting: Setting, to block: inout YAMLCodec.YAMLMapping) {
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
        case .scoreWeights(let weights):
            applyWeights(weights, to: &block)
        }
    }

    /// Writes the whole set when the file has no weights block, else only the weights the
    /// file does not already yield. Keys the app does not read stay.
    private static func applyWeights(
        _ weights: SecurityScoreWeights?, to block: inout YAMLCodec.YAMLMapping
    ) {
        guard let weights else {
            block.entries.removeAll { $0.key == weightsKey }
            return
        }
        let whole = weights.rounded()
        let existing = lastValue(of: weightsKey, in: block)?.mapping
        var mapping = existing ?? .init(entries: [])
        for slot in SecurityScoreWeights.configSlots {
            // The decoder reads an absent or unreadable weight as its default.
            let typed = typedWeight(lastValue(of: slot.key, in: mapping))
                ?? SecurityScoreWeights.defaultWeights[keyPath: slot.path]
            if existing == nil || typed != weights[keyPath: slot.path] {
                assign(.scalar(.int(Int(whole[keyPath: slot.path]))), to: slot.key, in: &mapping)
            }
        }
        if mapping != existing { assign(.mapping(mapping), to: weightsKey, in: &block) }
    }

    private static func typedWeight(_ node: YAMLCodec.YAMLValue?) -> Double? {
        guard let node, case .scalar = node else { return nil }
        return SecurityControlPolicy.scoreWeight(typed: node.stringValue ?? "")
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
