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
    private static let controlsPath = "security_policy.controls"
    private static let hardwarePath = "security_policy.filevault_off_hardware_encrypted"
    private static let weightsPath = "security_policy.score_weights"

    /// Key paths of the blocks that hold other settings: an issue at one of them is about
    /// the block's shape, and any other issue with a `used` is about a typed level.
    static let blockKeyPaths: Set<String> = [blockPath, controlsPath, weightsPath]

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
                shapeIssues(weightsPath, node, used: "the default weights")
            default:
                unknownKeyIssues("\(blockPath).\(displayText(key))")
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
            let path = "\(controlsPath).\(displayText(key))"
            guard let control = SecurityControl(rawValue: key) else {
                return unknownKeyIssues(path)
            }
            return levelIssues(path, node, used: applied.level(for: control).rawValue)
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
            keyPath: path, value: displayText(typedText(node)), used: used)]
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
            [SecurityPolicyIssue(keyPath: path, value: displayText(typedText(node)), used: used)]
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
        let hidden = CharacterSet.controlCharacters.union(.newlines)
        let kept = String(String.UnicodeScalarView(
            raw.unicodeScalars.filter { !hidden.contains($0) }))
        return kept.count > 40 ? String(kept.prefix(39)) + "…" : kept
    }
}

/// Scoped write-back for the Config → Scoring Security Policy card. Like
/// `ChartsConfigWriter` it reads the existing mapping and sets individual keys, outside
/// `ConfigService`'s managed keys, so `score_weights`, a key the app does not read and every
/// other top-level block survive a save.
///
/// A key whose typed value already reads as the saved level is left as typed: a synonym
/// (`warn`) or a typo the app already treats as `fail` is not rewritten by a save of another
/// control, and its issue stays reported until its own row changes.
enum SecurityPolicyConfigWriter {
    enum WriteError: Error, LocalizedError {
        case invalidProfile(String)
        case invalidDocumentRoot

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            case .invalidDocumentRoot:
                "config.yaml's YAML root is not a mapping — cannot save the security policy."
            }
        }
    }

    private static let hardwareKey = "filevault_off_hardware_encrypted"

    static func save(_ policy: SecurityControlPolicy, profile: String) throws {
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
        guard case .mapping(var root) = document.root else {
            throw WriteError.invalidDocumentRoot
        }

        let existing = root.value(for: "security_policy")?.mapping ?? .init(entries: [])
        var block = existing
        apply(policy, to: &block)
        // Nothing to write: leave the file, and any comments in the block, as it is.
        guard block != existing else { return }
        root.set("security_policy", value: .mapping(block))
        document.root = .mapping(root)

        let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: ["security_policy"])
        let tempURL = workspace.appendingPathComponent(".config.yaml.\(UUID().uuidString).tmp")
        try encoded.write(to: tempURL, atomically: true, encoding: .utf8)
        if !manager.fileExists(atPath: configURL.path) {
            manager.createFile(atPath: configURL.path, contents: Data())
        }
        _ = try manager.replaceItemAt(configURL, withItemAt: tempURL)
    }

    private static func apply(
        _ policy: SecurityControlPolicy, to block: inout YAMLCodec.YAMLMapping
    ) {
        let existing = block.value(for: "controls")?.mapping ?? .init(entries: [])
        var controls = existing
        for control in SecurityControl.allCases {
            let level = policy.level(for: control)
            // The decoder reads an absent or unreadable level as fail.
            if (typedLevel(lastValue(of: control.rawValue, in: controls)) ?? .fail) != level {
                assign(.scalar(.string(level.rawValue)), to: control.rawValue, in: &controls)
            }
        }
        // `controls` stays as the file had it (even a non-mapping) when nothing was written.
        if controls != existing { block.set("controls", value: .mapping(controls)) }

        let hardware = policy.fileVaultOffHardwareEncrypted
        guard typedLevel(lastValue(of: hardwareKey, in: block)) != hardware else { return }
        if let hardware {
            assign(.scalar(.string(hardware.rawValue)), to: hardwareKey, in: &block)
        } else {
            block.entries.removeAll { $0.key == hardwareKey }
        }
    }

    /// What the decoder sees for a repeated key: the last entry.
    private static func lastValue(
        of key: String, in mapping: YAMLCodec.YAMLMapping
    ) -> YAMLCodec.YAMLValue? {
        mapping.entries.last { $0.key == key }?.value
    }

    private static func typedLevel(_ node: YAMLCodec.YAMLValue?) -> SecurityControlLevel? {
        guard case .scalar(.string(let text)) = node else { return nil }
        return SecurityControlLevel.parse(text)
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
