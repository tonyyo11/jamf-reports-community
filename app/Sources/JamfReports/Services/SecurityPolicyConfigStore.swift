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
