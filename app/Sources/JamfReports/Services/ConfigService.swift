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
    var securityAgents: [ConfigSecurityAgent]
    var customEAs: [ConfigCustomEA]
    var staleDeviceDays: String
    var checkinOverdueDays: String
    var warningDiskPercent: String
    var criticalDiskPercent: String
    var certWarningDays: String
    var profileErrorWarning: String
    /// `thresholds.stale_basis`, as the app reads it: never empty.
    var staleBasis: [StaleBasis] = StaleBasis.default
    /// `thresholds.contact_gap_days`, as typed; the default when the file has none.
    var contactGapDays = String(ContactGap.defaultDays)
    var complianceEnabled: Bool
    var baselineLabel: String
    var failuresCountColumn: String
    var failuresListColumn: String
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

    /// The stale rule the screen's thresholds describe.
    var staleRule: StaleRule {
        StaleRule(days: Int(staleDeviceDays.trimmingCharacters(in: .whitespaces)) ?? 30,
                  basis: staleBasis)
    }

    /// The contact gap the screen shows: whole days from 1 to 365, else the default.
    var contactGapDaysValue: Int {
        Int(contactGapDays.trimmingCharacters(in: .whitespaces))
            .flatMap { ContactGap.dayRange.contains($0) ? $0 : nil } ?? ContactGap.defaultDays
    }

    static let defaultState = ConfigState(
        securityAgents: [],
        customEAs: [],
        staleDeviceDays: "30",
        checkinOverdueDays: "7",
        warningDiskPercent: "80",
        criticalDiskPercent: "90",
        certWarningDays: "90",
        profileErrorWarning: "10",
        complianceEnabled: false,
        // Blank, not a benchmark name: before config.yaml loads (and for a workspace that never
        // set one) the Overview shows its generic "Compliance Benchmark" title, not a name the
        // workspace did not choose.
        baselineLabel: "",
        failuresCountColumn: "",
        failuresListColumn: "",
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
        accentColor: "#2D5EA2"
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
    /// Key paths of settings the app no longer reads (`ConfigSchema.retiredKeys`) that the
    /// save removed from a block it rewrote.
    var removedRetiredKeys: [String] = []
    /// The copy of the file as it was, made before a save that dropped any of it.
    var backupName: String?

    /// One sentence for each thing the save left as typed or did not keep.
    var notes: [String] {
        var lines = keptBlocks.map { key in
            "\(key) in config.yaml is not a list, so it was left as typed and nothing was "
                + "written to it. Write each entry as a \"- name:\" list item so the app can "
                + "read and edit it."
        }
        if !removedRetiredKeys.isEmpty {
            let named = removedRetiredKeys.map { key in
                ConfigSchema.retiredKeys[key].map { "\(key) (since \($0))" } ?? key
            }
            lines.append("Settings the app no longer reads were removed from config.yaml: "
                + named.joined(separator: ", ") + "."
                + (backupName.map { " A copy of the file as it was is at \($0)." } ?? ""))
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

    /// The notes as the one status line a scoped-write card shows; nil when there are none.
    var statusLine: String? { notes.isEmpty ? nil : notes.joined(separator: " ") }

    /// The status line kept with the profile whose config.yaml the save wrote; nil when there
    /// is nothing to say.
    func note(for profile: String) -> ProfileSaveNote? {
        statusLine.map { ProfileSaveNote(profile: profile, line: $0) }
    }
}

/// A save's status line and the profile it was saved under, so a card that outlives a profile
/// switch shows it only while that profile is the live one.
struct ProfileSaveNote: Equatable, Sendable {
    let profile: String
    let line: String

    func line(for live: String) -> String? { live == profile ? line : nil }
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
        guard let digest, let text = try? ConfigLoader.readText(at: url) else {
            return false
        }
        return Self.digest(text) == digest
    }

    /// Whether `other` stamps the same file as this one: the same date and size, or, when a
    /// sync provider restamped a file it did not change, the same text.
    func isSameFile(as other: ConfigFileStamp) -> Bool {
        if modified == other.modified && size == other.size { return true }
        guard let digest, let otherDigest = other.digest else { return false }
        return digest == otherDigest
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
        /// A number field holding text the engine cannot read as a whole number.
        case notAWholeNumber(key: String, value: String)
        /// An old product key written under a `profiles:` block, which `EnvironmentProfiles`
        /// would not read; the slot to edit instead.
        case profilesBlock(slot: String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): ProfileName.invalidMessage(profile)
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
            case .notAWholeNumber(let key, let value):
                "\(key) must be a whole number, and \"\(ConfigSchema.displayText(value))\" is "
                    + "not one, so nothing was saved. Enter a number, or clear the field to "
                    + "use the default."
            case .profilesBlock(let slot):
                "config.yaml has a profiles block, so nothing was written here; edit "
                    + "profiles.\(slot) in config.yaml instead."
            }
        }
    }

    private static let managedTopLevelKeys: Set<String> = [
        "security_agents", "custom_eas", "thresholds", "compliance", "platform", "output",
        "jamf_cli", "branding",
    ]

    /// Retired keys that are a whole top-level block (`columns`, `school_columns`): a Config save
    /// removes them, after copying the file.
    private static var retiredTopLevelKeys: Set<String> {
        Set(ConfigSchema.retiredKeys.keys.filter { !$0.contains(".") })
    }

    static func load(profile: String, workspaceRoot: URL? = nil) throws -> LoadedConfig {
        let url = try configURL(for: profile, workspaceRoot: workspaceRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.missingConfig(url)
        }

        // Date and size are taken before the read, so a change made during it shows as one.
        var stamp = ConfigFileStamp.of(url)
        let text = try ConfigLoader.readText(at: url)
        stamp.digest = ConfigFileStamp.digest(text)
        let document = try YAMLCodec.decode(text)
        if !document.repairedKeys.isEmpty {
            AppLogger.collect.warning(
                "ConfigService: repaired malformed sequence(s) under \(document.repairedKeys.sorted().joined(separator: ", "), privacy: .private) in config.yaml — saving from the Config screen heals the file"
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
            document = try YAMLCodec.decode(ConfigLoader.readText(at: url))
            try rejectCredentialKeys(in: document.root)
        } else if let existingDocument {
            document = existingDocument
        } else {
            document = YAMLCodec.emptyDocument()
        }

        try rejectCredentialKeys(in: document.root)
        if let bad = notAWholeNumber(in: state, file: document.root) { throw bad }
        var report = ConfigSaveReport(keptBlocks: nonListBlocks(in: document.root))
        let keys = managedTopLevelKeys.subtracting(report.keptBlocks)
        apply(state: state, to: &document)
        if case .mapping(var root) = document.root {
            report.removedRetiredKeys = dropRetiredKeys(
                from: &root, inBlocks: keys.union(retiredTopLevelKeys))
            document.root = .mapping(root)
        }
        try backUpDropped(from: document, rewriting: keys, at: url, into: &report)
        let encoded = try YAMLCodec.encode(
            document, replacingTopLevelKeys: keys,
            removingTopLevelKeys: Set(report.removedRetiredKeys).intersection(retiredTopLevelKeys))
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
    /// `profilesSlot` names the `profiles:` slot that replaces the block's old product keys:
    /// under a `profiles:` mapping the write would change nothing the app reads, so it throws
    /// `profilesBlock` instead, or writes nothing when that slot already names `slotValue`.
    static func saveBlock(
        key: String, profile: String, workspaceRoot: URL? = nil, profilesSlot: String? = nil,
        slotValue: String? = nil,
        apply: (inout YAMLCodec.YAMLMapping) -> Void
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        let url = try configURL(for: profile, workspaceRoot: workspaceRoot)
        try rejectSymlinkDestination(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var stamp = ConfigFileStamp.of(url)
        var document = YAMLCodec.emptyDocument()
        if FileManager.default.fileExists(atPath: url.path) {
            let text = try ConfigLoader.readText(at: url)
            stamp.digest = ConfigFileStamp.digest(text)
            document = try YAMLCodec.decode(text)
            try rejectCredentialKeys(in: document.root)
        }
        guard case .mapping(var root) = document.root else { throw ConfigError.invalidTopLevel }
        if let profilesSlot, let slots = root.value(for: "profiles")?.mapping {
            let named = slots.value(for: profilesSlot)?.stringValue?
                .trimmingCharacters(in: .whitespaces)
            guard let slotValue, named == slotValue.trimmingCharacters(in: .whitespaces) else {
                throw ConfigError.profilesBlock(slot: profilesSlot)
            }
            return (stamp, ConfigSaveReport())
        }
        let before = root.value(for: key)
        if let before, before.mapping == nil, before != .scalar(.null) {
            throw ConfigError.notASettingsBlock(key)
        }
        apply(&root)
        let removed = dropRetiredKeys(from: &root, inBlocks: [key])
        let empty = YAMLCodec.YAMLMapping(entries: [])
        guard (root.value(for: key)?.mapping ?? empty) != (before?.mapping ?? empty) else {
            return (stamp, ConfigSaveReport())
        }
        document.root = .mapping(root)
        var report = ConfigSaveReport(removedRetiredKeys: removed)
        try backUpDropped(from: document, rewriting: [key], at: url, into: &report)
        let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: [key])
        return (try replace(url, with: encoded), report)
    }

    /// Sets `jamf_cli.profile` on `root` and keeps every other key in the block: the binding's
    /// write and the seeded config of a new workspace.
    static func setJamfCLIProfile(_ profile: String, in root: inout YAMLCodec.YAMLMapping) {
        var jamfCLI = root.value(for: "jamf_cli")?.mapping ?? YAMLCodec.YAMLMapping(entries: [])
        jamfCLI.set("profile", value: .scalar(.string(profile)))
        root.set("jamf_cli", value: .mapping(jamfCLI))
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
        if report.droppedComments || report.droppedUnreadLines
            || !report.removedRetiredKeys.isEmpty {
            report.backupName = try backUp(url)?.lastPathComponent
        }
    }

    /// Removes, from the blocks in `blocks`, every retired key (`ConfigSchema.retiredKeys`) they
    /// hold, each copy of a repeated key, and returns the key paths removed in sorted order. Only
    /// a block a writer rewrites is passed in; a retired key anywhere else stays as typed.
    static func dropRetiredKeys(
        from root: inout YAMLCodec.YAMLMapping, inBlocks blocks: Set<String>
    ) -> [String] {
        var removed: [String] = []
        for path in ConfigSchema.retiredKeys.keys.sorted() {
            let parts = path.components(separatedBy: ".")
            guard let first = parts.first, let last = parts.last, blocks.contains(first) else {
                continue
            }
            // A one-segment path is a whole top-level block (`columns`), not a key inside itself.
            let held = parts.count == 1
                ? root.entries.contains { $0.key == first }
                : dropKey(last, at: Array(parts.dropFirst().dropLast()), under: first, in: &root)
            guard held else { continue }
            if parts.count == 1 { root.entries.removeAll { $0.key == first } }
            removed.append(path)
        }
        if !removed.isEmpty {
            let named = removed.joined(separator: ", ")
            AppLogger.collect.notice(
                "ConfigService: removed retired keys \(named, privacy: .private)")
        }
        return removed
    }

    /// Removes `key` from the mapping reached from `root[top]` through `middle`. True when a
    /// key was there.
    private static func dropKey(
        _ key: String, at middle: [String], under top: String, in root: inout YAMLCodec.YAMLMapping
    ) -> Bool {
        func drop(_ mapping: inout YAMLCodec.YAMLMapping, _ rest: ArraySlice<String>) -> Bool {
            guard let next = rest.first else {
                let held = mapping.entries.contains { $0.key == key }
                mapping.entries.removeAll { $0.key == key }
                return held
            }
            guard var child = mapping.value(for: next)?.mapping else { return false }
            let found = drop(&child, rest.dropFirst())
            if found { mapping.set(next, value: .mapping(child)) }
            return found
        }
        return drop(&root, ([top] + middle)[...])
    }

    /// The save that removes a retired key from `block`: "Config save" for the blocks the Config
    /// screen writes, "Customize Apply" for `charts`, nil for a block no app writer rewrites.
    static func retiredKeyRemover(inBlock block: String) -> String? {
        if managedTopLevelKeys.contains(block) || retiredTopLevelKeys.contains(block) {
            return "Config save"
        }
        switch block {
        case "charts": return "Customize Apply"
        case "security_policy": return "Scoring save"
        default: return nil
        }
    }

    /// Replaces the file at `url` with `encoded` through a staged file beside it (keeping the
    /// mode of the file it replaces), and returns the stamp of what was written.
    private static func replace(_ url: URL, with encoded: String) throws -> ConfigFileStamp {
        try AtomicInstall.write(Data(encoded.utf8), to: url)
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
    /// replaces or rewrites it, with `notify.url` taken out (`scrubbedForBackup`): a webhook URL
    /// is a credential, and the copies pile up beside a file that may be a synced team folder.
    /// A copy that already holds the same text is returned instead; a name taken by other text
    /// moves to the next free second. Keeps the returned copy and the newest four others. Nil
    /// when there is no file.
    static func backUp(_ url: URL, now: Date = Date()) throws -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".bak-"
        let text = scrubbedForBackup(try ConfigLoader.readData(at: url))
        let copies = try backupNames(in: directory, prefix: prefix)
        var backup: URL
        if let same = copies.sorted().last(where: {
            (try? ConfigLoader.readData(at: directory.appendingPathComponent($0))) == text
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
            try text.write(to: backup, options: .atomic)
            if let mode = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: backup.path)
            }
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

    /// `data` with the webhook URL taken out: the `url` line of the top-level `notify` block
    /// reads `url: ""` followed by a comment that names the host only, and any other place the
    /// same URL text appears (a comment, a second key) becomes `<removed>`. Everything else is
    /// byte for byte as it was; a file with no URL, or that is not UTF-8, comes back unchanged.
    /// A restored copy therefore has no usable webhook until the URL is entered again.
    static func scrubbedForBackup(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        // Any other webhook URL the file carries (an old one in a comment, a second block).
        var swept = removingWebhookURLs(text)
        // The webhook and the timestamp authority: either URL can carry a token.
        if let root = try? ConfigLoader.rawMapping(fromYAML: text) {
            for (section, key) in [("notify", "url"), ("output", "timestamp_authority")] {
                guard let url = (ConfigLoader.rawValue(at: [section, key], in: root) as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { continue }
                swept = removingURL(url, at: section, key, from: swept)
            }
        }
        return swept == text ? data : Data(swept.utf8)
    }

    /// Every incoming-webhook URL `LogRedactor` recognises, replaced with `<removed>`.
    private static func removingWebhookURLs(_ text: String) -> String {
        LogRedactor.webhookURLPatterns.reduce(text) { current, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            else { return current }
            let range = NSRange(current.startIndex..., in: current)
            return regex.stringByReplacingMatches(
                in: current, range: range, withTemplate: "<removed>")
        }
    }

    /// `<section>.<key>`'s line written as `<key>: ""` with a comment naming only the host, and
    /// any other copy of that text replaced with `<removed>`.
    private static func removingURL(
        _ url: String, at section: String, _ key: String, from text: String
    ) -> String {
        let host = URL(string: url)?.host.map { "https://\($0)/…" } ?? "its host"
        var inSection = false
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let first = line.first
            if first != nil, first != " ", first != "\t", first != "#", first != "\r" {
                inSection = line.hasPrefix(section + ":")
            }
            let body = line.drop { $0 == " " || $0 == "\t" }
            guard inSection, body.count < line.count, body.hasPrefix(key),
                  body.dropFirst(key.count).drop(while: { $0 == " " }).first == ":" else {
                lines.append(line.replacingOccurrences(of: url, with: "<removed>"))
                continue
            }
            let indent = String(line.prefix(line.count - body.count))
            let ending = line.hasSuffix("\r") ? "\r" : ""
            lines.append("\(indent)\(key): \"\"\(ending)")
            lines.append(
                "\(indent)# \(section).\(key) removed from this copy (was \(host))\(ending)")
        }
        return lines.joined(separator: "\n")
    }

    /// What `scrubbedForBackup` took out of the copy at `backup`, worded for a note: the webhook
    /// URL and the timestamp authority address. Empty when neither was there.
    static func backupOmissions(_ backup: URL) -> [String] {
        let text = (try? ConfigLoader.readText(at: backup)) ?? ""
        return [("notify.url", "webhook URL"), ("output.timestamp_authority",
                                                "timestamp authority address")]
            .filter { text.contains("# \($0.0) removed from this copy") }.map(\.1)
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
        guard let id = WorkspaceID(profile) else {
            throw ConfigError.invalidProfile(profile)
        }

        let root = (workspaceRoot ?? ProfileService.workspacesRoot())
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let workspace = WorkspacePaths.workspaceURL(for: id, under: root).standardizedFileURL
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
            state.profileErrorWarning = string(thresholds, "profile_error_warning", fallback: state.profileErrorWarning)
            state.staleBasis = staleBasisSetting(thresholds).resolved
            state.contactGapDays = string(
                thresholds, "contact_gap_days", fallback: state.contactGapDays)
        }

        if let compliance = root.value(for: "compliance")?.mapping {
            state.complianceEnabled = compliance.value(for: "enabled")?.boolValue ?? state.complianceEnabled
            state.baselineLabel = string(compliance, "baseline_label", fallback: state.baselineLabel)
            state.failuresCountColumn = string(compliance, "failures_count_column")
            state.failuresListColumn = string(compliance, "failures_list_column")
        }

        if let platform = root.value(for: "platform")?.mapping {
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
        }

        return state
    }

    static func apply(state: ConfigState, to document: inout YAMLCodec.YAMLDocument) {
        var root = document.root.mapping ?? .init(entries: [])

        root.set("security_agents", value: .sequence(state.securityAgents.map { agent in
            var entry = agent.source.mapping
            entry.set("name", value: scalar(agent.name))
            entry.set("column", value: scalar(agent.column))
            entry.set("connected_value", value: scalar(agent.connectedValue))
            return .mapping(entry)
        }))

        root.set("custom_eas", value: .sequence(state.customEAs.map(customEAValue)))

        var thresholds = root.value(for: "thresholds")?.mapping ?? .init(entries: [])
        setWholeNumbers(state, in: "thresholds", to: &thresholds)
        applyStaleBasis(state.staleBasis, to: &thresholds)
        applyContactGapDays(state, to: &thresholds)
        root.set("thresholds", value: .mapping(thresholds))

        var compliance = root.value(for: "compliance")?.mapping ?? .init(entries: [])
        compliance.set("enabled", value: .scalar(.bool(state.complianceEnabled)))
        if state.baselineLabel.trimmingCharacters(in: .whitespaces).isEmpty {
            compliance.entries.removeAll { $0.key == "baseline_label" }
        } else {
            compliance.set("baseline_label", value: scalar(state.baselineLabel))
        }
        compliance.set("failures_count_column", value: scalar(state.failuresCountColumn))
        compliance.set("failures_list_column", value: scalar(state.failuresListColumn))
        root.set("compliance", value: .mapping(compliance))

        var platform = root.value(for: "platform")?.mapping ?? .init(entries: [])
        platform.set("compliance_benchmarks", value: .sequence(state.complianceBenchmarks.map { scalar($0) }))
        root.set("platform", value: .mapping(platform))

        var output = root.value(for: "output")?.mapping ?? .init(entries: [])
        let defaults = ConfigState.defaultState
        setFolder("output_dir", state.outputDir, default: defaults.outputDir, in: &output)
        setFolder("archive_dir", state.archiveDir, default: defaults.archiveDir, in: &output)
        output.set("timestamp_outputs", value: .scalar(.bool(state.timestampOutputs)))
        output.set("archive_enabled", value: .scalar(.bool(state.archiveEnabled)))
        setWholeNumbers(state, in: "output", to: &output)
        root.set("output", value: .mapping(output))

        var jamfCLI = root.value(for: "jamf_cli")?.mapping ?? .init(entries: [])
        jamfCLI.set("use_cached_data", value: .scalar(.bool(state.jamfCLIUseCachedData)))
        jamfCLI.set("require_manifest", value: .scalar(.bool(state.jamfCLIRequireManifest)))
        root.set("jamf_cli", value: .mapping(jamfCLI))

        var branding = root.value(for: "branding")?.mapping ?? .init(entries: [])
        branding.set("org_name", value: scalar(state.orgName))
        branding.set("logo_path", value: scalar(state.logoPath))
        branding.set("accent_color", value: scalar(state.accentColor))
        root.set("branding", value: .mapping(branding))

        document.root = .mapping(root)
    }

    /// Writes a pinned folder key only when the file already sets it or the value is not the
    /// default: a key the file never had would read as a changed folder in `SharedConfigPin`.
    private static func setFolder(
        _ key: String, _ value: String, default fallback: String,
        in output: inout YAMLCodec.YAMLMapping
    ) {
        let isDefault = value.trimmingCharacters(in: .whitespaces)
            == fallback.trimmingCharacters(in: .whitespaces)
        guard output.value(for: key) != nil || !isDefault else { return }
        output.set(key, value: scalar(value))
    }

    /// What `thresholds.stale_basis` holds: a date, a list of dates, or nothing the app reads.
    private static func staleBasisSetting(
        _ thresholds: YAMLCodec.YAMLMapping
    ) -> StaleBasisSetting {
        guard let value = thresholds.value(for: "stale_basis") else {
            return StaleBasisSetting(words: [])
        }
        if let items = value.sequence {
            return StaleBasisSetting(words: items.map { $0.stringValue ?? "" })
        }
        return value.stringValue.map { StaleBasisSetting(words: [$0]) }
            ?? StaleBasisSetting(words: [], wrongShape: true)
    }

    /// Writes `stale_basis` only when the choice differs from what the file already says, so
    /// a single word, an unknown word or a comment-free hand edit is left as typed, and the
    /// default is the absent key.
    private static func applyStaleBasis(
        _ basis: [StaleBasis], to thresholds: inout YAMLCodec.YAMLMapping
    ) {
        let chosen = StaleRule(days: 0, basis: basis).basis
        guard chosen != staleBasisSetting(thresholds).resolved else { return }
        if chosen == StaleBasis.default {
            thresholds.entries.removeAll { $0.key == "stale_basis" }
        } else {
            thresholds.set("stale_basis", value: .sequence(chosen.map { scalar($0.rawValue) }))
        }
    }

    /// Same rule as `applyStaleBasis`: an unchanged gap is left as typed.
    private static func applyContactGapDays(
        _ state: ConfigState, to thresholds: inout YAMLCodec.YAMLMapping
    ) {
        let typed = thresholds.value(for: "contact_gap_days")?.stringValue
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let current = typed.flatMap { ContactGap.dayRange.contains($0) ? $0 : nil }
            ?? ContactGap.defaultDays
        let chosen = state.contactGapDaysValue
        guard chosen != current else { return }
        if chosen == ContactGap.defaultDays {
            thresholds.entries.removeAll { $0.key == "contact_gap_days" }
        } else {
            thresholds.set("contact_gap_days", value: .scalar(.int(chosen)))
        }
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
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines)).map { .scalar(.int($0)) }
    }

    /// The number fields the Config screen writes, which the engine reads as `Int?`: any other
    /// text there fails the decode of the whole config.yaml, on every Mac that shares it.
    static func wholeNumberFields(_ state: ConfigState) -> [(key: [String], value: String)] {
        [
            (["thresholds", "stale_device_days"], state.staleDeviceDays),
            (["thresholds", "checkin_overdue_days"], state.checkinOverdueDays),
            (["thresholds", "warning_disk_percent"], state.warningDiskPercent),
            (["thresholds", "critical_disk_percent"], state.criticalDiskPercent),
            (["thresholds", "cert_warning_days"], state.certWarningDays),
            (["thresholds", "profile_error_warning"], state.profileErrorWarning),
            (["output", "keep_latest_runs"], state.keepLatestRuns),
        ]
    }

    /// The first number field the user typed that is neither blank nor a whole number. Text
    /// the file already holds there is not refused: it stays as typed, the engine uses the
    /// default for it and Config Doctor names it, so it cannot block saving another setting.
    static func notAWholeNumber(
        in state: ConfigState, file root: YAMLCodec.YAMLValue? = nil
    ) -> ConfigError? {
        for (key, value) in wholeNumberFields(state) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  optionalInt(value) == nil,
                  value != fileText(key, in: root) else { continue }
            return .notAWholeNumber(key: key.joined(separator: "."), value: value)
        }
        return nil
    }

    private static func fileText(_ key: [String], in root: YAMLCodec.YAMLValue?) -> String? {
        root?.mapping?.value(for: key[0])?.mapping?.value(for: key[1])?.stringValue
    }

    /// Writes `block`'s number fields: a whole number as a number, a blank field by removing
    /// the key (the engine's default applies), and any other text, which `save` has let through
    /// only when the file already held it, left as the file has it.
    private static func setWholeNumbers(
        _ state: ConfigState, in block: String, to mapping: inout YAMLCodec.YAMLMapping
    ) {
        for (key, value) in wholeNumberFields(state) where key[0] == block {
            if let number = optionalInt(value) {
                mapping.set(key[1], value: number)
            } else if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mapping.entries.removeAll { $0.key == key[1] }
            }
        }
    }
}
