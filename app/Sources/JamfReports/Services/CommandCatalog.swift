import Foundation

/// jamf-cli's own list of its commands (`jamf-cli commands -o json`): one row per command path
/// with its long flags, the Jamf Pro privileges it needs, its API and whether it is destructive
/// or in preview.
///
/// Read leniently: every field is optional, an unknown key is ignored, and a row that does not
/// decode is dropped instead of failing the list. Nothing here reads a workspace file. Tests
/// read the fixture `Fixtures/jamf-cli/commands-<version>.json`; at runtime the catalog is
/// optional (`installed()`), so a missing jamf-cli leaves the compiled-in fallbacks in use.
///
/// The catalog's `flags` hold each command's own long flags only, not jamf-cli's global flags
/// (`--output`, `--no-input`, ...). The `scopes` column is read (`scopes(for:)`) but
/// `ReportEngine.environmentLevelKinds` still lists its kinds by hand; it moves to `scopes`
/// with the environment-scope work in 2.12 (task 2.3).
struct CommandCatalog: Sendable {

    struct Entry: Sendable, Equatable {
        let path: [String]
        let aliases: [String]
        let flags: [String]
        let privileges: [String]
        let scopes: [String]
        let product: String?
        let api: String?
        let destructive: Bool
        let preview: Bool
    }

    enum CatalogError: Error, Equatable {
        case notAnArray
    }

    private let byPath: [String: Entry]

    init(data: Data) throws {
        guard let rows = try? JSONDecoder().decode([Lossy].self, from: data) else {
            throw CatalogError.notAnArray
        }
        var entries: [String: Entry] = [:]
        for case let row? in rows.map(\.row) {
            guard let command = row.command, !command.isEmpty else { continue }
            let path = command.split(separator: " ").map(String.init)
            entries[command] = Entry(
                path: path,
                aliases: row.aliases ?? [],
                flags: row.flags ?? [],
                privileges: row.privileges ?? [],
                scopes: row.scopes ?? [],
                product: row.product,
                api: row.api,
                destructive: row.destructive ?? false,
                preview: row.preview ?? false)
        }
        byPath = entries
    }

    var count: Int { byPath.count }

    /// The row for `path`: its own name, else the one row whose segments match it when aliases
    /// stand in for names (jamf-cli lists `pro computers list` under `pro computer-inventory
    /// list`). Two rows matching through aliases is no answer.
    func entry(for path: [String]) -> Entry? {
        if let exact = byPath[path.joined(separator: " ")] { return exact }
        let viaAlias = byPath.values.filter { entry in
            entry.path.count == path.count
                && zip(path, entry.path).allSatisfy { $0 == $1 || entry.aliases.contains($0) }
        }
        return viaAlias.count == 1 ? viaAlias[0] : nil
    }

    func exists(path: [String]) -> Bool { entry(for: path) != nil }

    /// True when `path` is the row's own name, not an alias of it.
    func isCanonical(path: [String]) -> Bool { byPath[path.joined(separator: " ")] != nil }

    /// The command's own long flags (global flags excluded); empty for an unknown path.
    func flags(for path: [String]) -> [String] { entry(for: path)?.flags ?? [] }

    func privileges(for path: [String]) -> [String] { entry(for: path)?.privileges ?? [] }

    func scopes(for path: [String]) -> [String] { entry(for: path)?.scopes ?? [] }

    func product(for path: [String]) -> String? { entry(for: path)?.product }

    /// `pro` and `pro-classic` for Jamf Pro commands, `platform-gateway` for the Platform API.
    func api(for path: [String]) -> String? { entry(for: path)?.api }

    func isDestructive(path: [String]) -> Bool { entry(for: path)?.destructive ?? false }

    func isPreview(path: [String]) -> Bool { entry(for: path)?.preview ?? false }

    // MARK: - Reading an argv

    /// The command path and long flags in a jamf-cli argv. A leading `-p <profile>` and flags
    /// before the path are skipped; the path ends at the first flag; the last `positionals`
    /// words of it are arguments (an ID, a title), not path. Flags are the `--name` words (the
    /// part before `=`); a bare `--` ends them, so a profile name after it is never a flag.
    static func invocation(
        of argv: [String], positionals: Int = 0
    ) -> (path: [String], flags: [String]) {
        var words: [String] = []
        var flags: [String] = []
        var index = 0
        var inPath = true
        while index < argv.count {
            let token = argv[index]
            index += 1
            if token == "--" { break }
            if token == "-p" || token == "--profile" {
                index += 1
            } else if token.hasPrefix("--") {
                flags.append(String(token.split(separator: "=", maxSplits: 1)[0]))
                if !words.isEmpty { inPath = false }
            } else if token.hasPrefix("-") {
                if !words.isEmpty { inPath = false }
            } else if inPath {
                words.append(token)
            }
        }
        return (Array(words.dropLast(min(positionals, words.count))), flags)
    }

    /// The Jamf Pro API role privileges the commands in `argvs` list, sorted. Report and Classic
    /// rows list none in the catalog, so this is the part of the need jamf-cli names, not all of
    /// it. Gateway permissions (`compliance-benchmarks:read`) belong to a Jamf Account
    /// integration and are left out.
    func proPrivileges(forArguments argvs: [(argv: [String], positionals: Int)]) -> [String] {
        var names: Set<String> = []
        for (argv, positionals) in argvs {
            guard let entry = entry(for: Self.invocation(of: argv, positionals: positionals).path),
                  entry.api == "pro" || entry.api == "pro-classic" else { continue }
            names.formUnion(entry.privileges)
        }
        return names.sorted()
    }

    /// `proPrivileges` over what a full collect runs: the command matrix, the benchmark listing,
    /// the per-device scan's two calls and the patch-definition walk.
    func collectPrivileges() -> [String] {
        let matrix = ReportEngine.collectCommandMatrix(profile: "p", staleDays: 30)
            .map { (argv: $0.args, positionals: 0) }
        return proPrivileges(forArguments: matrix + [
            (ReportEngine.benchmarkListArguments(profile: "p"), 0),
            (ReportEngine.historyArguments(profile: "p", id: "1"), 1),
            (ReportEngine.statusItemsArguments(profile: "p", managementId: "1"), 1),
            (ReportEngine.patchDefinitionArguments(profile: "p", titleId: "1"), 1),
        ])
    }

    // MARK: - Installed jamf-cli

    /// The Jamf Pro privileges for the setup text when no catalog can be read: the collect
    /// matrix's union over the 1.31.1 catalog (`CommandCatalogTests` keeps it equal to the
    /// fixture's), so the text is never blank.
    static let bundledCollectPrivileges = [
        "Read Advanced Mobile Device Searches", "Read Buildings", "Read Categories",
        "Read Computer Extension Attributes", "Read Computers", "Read Departments",
        "Read Device Enrollment Program Instances", "Read Mobile Devices", "Read Packages",
        "Read Patch Management Software Titles", "Read Scripts", "Read Self Service",
        "Read Sites", "Read Smart Computer Groups",
    ]

    nonisolated(unsafe) private static var cached: CommandCatalog?
    private static let cacheLock = NSLock()

    /// The installed jamf-cli's catalog, read once per process; nil when jamf-cli is absent,
    /// fails its signature check, does not answer within `JamfCLIProbe.defaultTimeout` or prints
    /// something else. A failed read is not cached, so a later jamf-cli install is found.
    /// Blocks the calling thread until the child ends: call it off the main actor. Never
    /// launches anything in a test process (`ExecutableLocator`).
    static func installed(
        locate: () -> URL? = { ExecutableLocator.locate("jamf-cli") }
    ) -> CommandCatalog? {
        cacheLock.lock()
        let hit = cached
        cacheLock.unlock()
        if let hit { return hit }
        guard let binary = locate(),
              CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) == nil,
              let output = JamfCLIProbe.run(
                executable: binary, arguments: ["commands", "-o", "json"]),
              output.exitCode == 0,
              let catalog = try? CommandCatalog(data: output.stdout) else { return nil }
        cacheLock.lock()
        cached = catalog
        cacheLock.unlock()
        return catalog
    }

    // MARK: - Decoding

    /// One row that fails to decode is dropped, not the whole list.
    private struct Lossy: Decodable {
        let row: Row?
        init(from decoder: Decoder) throws { row = try? Row(from: decoder) }
    }

    /// jamf-cli writes `aliases` and `flags` as comma-separated text.
    private struct Row: Decodable {
        let command: String?
        let aliases: [String]?
        let flags: [String]?
        let privileges: [String]?
        let scopes: [String]?
        let product: String?
        let api: String?
        let destructive: Bool?
        let preview: Bool?

        enum CodingKeys: String, CodingKey {
            case command, aliases, flags, privileges, scopes, product, api, destructive, preview
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try? c.decodeIfPresent(String.self, forKey: .command)
            aliases = Self.words(c, .aliases)
            flags = Self.words(c, .flags)
            privileges = try? c.decodeIfPresent([String].self, forKey: .privileges)
            scopes = try? c.decodeIfPresent([String].self, forKey: .scopes)
            product = try? c.decodeIfPresent(String.self, forKey: .product)
            api = try? c.decodeIfPresent(String.self, forKey: .api)
            destructive = try? c.decodeIfPresent(Bool.self, forKey: .destructive)
            preview = try? c.decodeIfPresent(Bool.self, forKey: .preview)
        }

        private static func words(
            _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> [String]? {
            if let text = try? c.decodeIfPresent(String.self, forKey: key) {
                return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            return try? c.decodeIfPresent([String].self, forKey: key)
        }
    }
}
