import Foundation

/// What config.yaml holds that the Config screen's editors do not show, for the read-only
/// "From config.yaml" tab. Nothing here writes the file. A value under a key that looks like
/// a secret is reduced to `(set)` or `(empty)` when a row is built, so it is never carried.
struct ConfigFileSections: Equatable, Sendable {
    static let nothingToShow = "Everything in config.yaml is editable on the other tabs."
    /// Rows listed per section; the rest are counted.
    static let settingCap = 200
    static let noteCap = 50

    /// A key the app reads that no screen edits. `value` is display text.
    struct Setting: Equatable, Sendable {
        let keyPath: String
        let value: String
    }

    /// The settings under one top-level key, in file order.
    struct Block: Equatable, Sendable {
        let name: String
        let settings: [Setting]
    }

    /// Keys the app reads that no screen edits, by top-level key in file order.
    var fileOnly: [Block] = []
    /// Keys the app does not read, with the known key each is nearest to.
    var unknown: [UnknownKey] = []
    /// `Line N: …` for each line the reader did not take as written.
    var skipped: [String] = []
    var omittedSettings = 0
    var omittedUnknown = 0
    var omittedSkipped = 0

    var isEmpty: Bool { fileOnly.isEmpty && unknown.isEmpty && skipped.isEmpty }

    /// Throws when the text is not a YAML mapping. `edited` is the set of key paths a screen
    /// writes; a test passes its own to look at a key the app's editors do write.
    static func build(
        fromYAML text: String, edited: Set<[String]> = ConfigEditedKeys.paths
    ) throws -> ConfigFileSections {
        let document = try YAMLCodec.decode(text)
        guard let root = document.root.mapping else { throw YAMLCodec.CodecError.invalidTopLevel }
        let blocks = fileOnlyBlocks(in: root, edited: edited)
        let shownBlocks = capped(blocks)
        let unknown = ConfigSchema.unknownKeys(in: try ConfigLoader.rawMapping(fromYAML: text))
        let notes = document.parseNotes.map(\.display)
        return ConfigFileSections(
            fileOnly: shownBlocks.blocks, unknown: Array(unknown.prefix(noteCap)),
            skipped: Array(notes.prefix(noteCap)), omittedSettings: shownBlocks.omitted,
            omittedUnknown: max(0, unknown.count - noteCap),
            omittedSkipped: max(0, notes.count - noteCap))
    }

    // MARK: - The keys the app reads that no screen edits

    private static func fileOnlyBlocks(
        in root: YAMLCodec.YAMLMapping, edited: Set<[String]>
    ) -> [Block] {
        guard let known = ConfigSchema.knownKeys(at: []) else { return [] }
        var seen = Set<String>()
        var blocks: [Block] = []
        for entry in root.entries {
            guard known.contains(entry.key), seen.insert(entry.key).inserted,
                  let value = root.value(for: entry.key) else { continue }
            var settings: [Setting] = []
            visit(value, path: [entry.key], shown: entry.key, edited: edited, into: &settings)
            if !settings.isEmpty { blocks.append(Block(name: entry.key, settings: settings)) }
        }
        return blocks
    }

    /// `path` is the key's place in the schema (no list indices); `shown` is what is listed.
    /// A value of the wrong shape (a scalar where the app reads a block, a block where it
    /// reads a scalar) is not listed: the app does not read it as that key. A file with one
    /// usually fails to decode, and the file-problem card then names the key path.
    private static func visit(
        _ value: YAMLCodec.YAMLValue, path: [String], shown: String, edited: Set<[String]>,
        into settings: inout [Setting]
    ) {
        let readsBlock = ConfigSchema.knownKeys(at: path) != nil
        switch value {
        case .mapping(let mapping) where readsBlock:
            collect(mapping, at: path, shown: shown, edited: edited, into: &settings)
        case .sequence(let items) where readsBlock:
            for (index, item) in items.enumerated() {
                guard let mapping = item.mapping else { continue }
                collect(mapping, at: path, shown: "\(shown)[\(index)]", edited: edited,
                        into: &settings)
            }
        case .scalar, .sequence:
            guard !readsBlock, !edited.contains(path) else { return }
            settings.append(Setting(keyPath: shown, value: displayValue(value, keyPath: shown)))
        case .mapping:
            return
        }
    }

    /// The keys of `mapping` that the app reads, each once, the last value set for it.
    private static func collect(
        _ mapping: YAMLCodec.YAMLMapping, at path: [String], shown: String,
        edited: Set<[String]>, into settings: inout [Setting]
    ) {
        guard let known = ConfigSchema.knownKeys(at: path) else { return }
        var seen = Set<String>()
        for entry in mapping.entries {
            guard known.contains(entry.key), seen.insert(entry.key).inserted,
                  let value = mapping.value(for: entry.key) else { continue }
            visit(value, path: path + [entry.key], shown: "\(shown).\(entry.key)",
                  edited: edited, into: &settings)
        }
    }

    private static func capped(_ blocks: [Block]) -> (blocks: [Block], omitted: Int) {
        var room = settingCap
        var shown: [Block] = []
        var omitted = 0
        for block in blocks {
            let kept = block.settings.prefix(room)
            omitted += block.settings.count - kept.count
            room -= kept.count
            if !kept.isEmpty { shown.append(Block(name: block.name, settings: Array(kept))) }
        }
        return (shown, omitted)
    }

    // MARK: - Values

    private static let secretWords = ["url", "token", "secret", "password", "key", "webhook"]

    /// The value as listed. A key whose path names a secret shows only whether it is set.
    static func displayValue(_ value: YAMLCodec.YAMLValue, keyPath: String) -> String {
        let text = typedText(value)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return "(empty)" }
        let path = keyPath.lowercased()
        guard !secretWords.contains(where: { path.contains($0) }) else { return "(set)" }
        return ConfigSchema.displayText(text)
    }

    private static func typedText(_ value: YAMLCodec.YAMLValue) -> String {
        switch value {
        case .scalar(.string(let text)): text
        case .scalar(.int(let number)): String(number)
        case .scalar(.bool(let flag)): String(flag)
        case .scalar(.null), .mapping: ""
        case .sequence(let items):
            items.map(typedText).filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }
}

/// What the "From config.yaml" tab has to show for a profile's config.yaml.
enum ConfigFileReading: Equatable, Sendable {
    case sections(ConfigFileSections)
    /// A sentence saying why there is nothing to list.
    case unavailable(String)

    /// Whether there is a config.yaml to reveal in Finder, readable or not. Never in demo mode.
    static func canReveal(at url: URL?, demoMode: Bool = false) -> Bool {
        guard !demoMode, let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Demo mode reads no file and shows the demo workspace's nothing-to-show state.
    static func read(at url: URL?, demoMode: Bool = false) -> ConfigFileReading {
        guard !demoMode else { return .sections(ConfigFileSections()) }
        guard let url else { return .unavailable("The workspace folder was not found.") }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable(
                "config.yaml does not exist yet. Saving from another tab creates it.")
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return .unavailable("config.yaml could not be read: \(error.localizedDescription)")
        }
        do {
            return .sections(try ConfigFileSections.build(fromYAML: text))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
