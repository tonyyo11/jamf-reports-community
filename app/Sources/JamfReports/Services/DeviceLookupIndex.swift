import Foundation

/// Read-only index over the cached `computers-list` and `mobile-devices-list`
/// snapshots, used by Device Lookup to resolve a free-text term (id, serial,
/// or name) to a concrete `(kind, id)` pair before invoking the per-device
/// jamf-cli call.
///
/// Lives as a focused service rather than as part of `DeviceInventoryService`
/// because that service is keyed to the Devices screen's data model
/// (`DeviceInventoryRecord` with risk scoring, patch state, etc.) and only
/// indexes computers. This index is deliberately lightweight: it carries just
/// enough fields to display a candidate chip and pick the right CLI call.
///
/// `@Observable` — without it, `DeviceLookupView`'s `@State private var index`
/// only re-renders when the *reference* is reassigned, not when `load(profile:)`
/// mutates this class's stored properties in place. The unobserved mutation was
/// invisible: `resolve(_:)` still saw the freshly loaded `candidates`, so lookups
/// worked, but any view text reading `index.candidates.count` (the cached-count
/// caption) stayed frozen at its first-paint value forever.
@MainActor
@Observable
final class DeviceLookupIndex {

    enum Kind: String, Sendable, Equatable, Hashable {
        case computer
        case mobile

        var displayLabel: String {
            switch self {
            case .computer: "Mac"
            case .mobile:   "Mobile"
            }
        }
    }

    struct Candidate: Sendable, Identifiable, Hashable {
        let kind: Kind
        let id: String
        let name: String
        let serial: String?
        let osVersion: String?

        var identifier: String { "\(kind.rawValue)-\(id)" }
        var id_: String { identifier } // satisfy Identifiable
    }

    private(set) var candidates: [Candidate] = []
    private(set) var loadedAt: Date?
    private(set) var sourceFiles: [String] = []
    private(set) var lastError: String?

    /// The profile `candidates` belong to, or are being read for.
    private(set) var heldProfile: String?

    /// Bumped by each `load`, so a read that a later load replaced does not paint.
    private var loadGeneration = 0

    /// Reload from `profile`'s cached list snapshots. The snapshots decode off the main actor.
    /// Another profile's candidates are cleared first, so a search while the read is in flight
    /// finds nothing rather than a device of the profile left behind. A load a later call, a
    /// cancelled task or `wanted` (false once the caller has moved on) replaced paints nothing.
    func load(profile: String, wanted: @MainActor () -> Bool = { true }) async {
        loadGeneration += 1
        let generation = loadGeneration
        if heldProfile != profile {
            heldProfile = profile
            candidates = []
            sourceFiles = []
            loadedAt = nil
            lastError = "Loading the cached inventory for `\(profile)`…"
        }
        guard let loaded = await ScreenLoad.paint(
            stillCurrent: { generation == loadGeneration && wanted() },
            read: { Self.read(profile: profile) }
        ) else { return }
        candidates = loaded.candidates
        sourceFiles = loaded.sourceFiles
        loadedAt = loaded.loadedAt
        lastError = loaded.lastError
    }

    /// Resolve a free-text term against the loaded index.
    ///
    /// Priority:
    /// 1. Exact `id` match (typical when user pastes a Jamf ID)
    /// 2. Exact case-insensitive serial match
    /// 3. Substring case-insensitive name match
    ///
    /// Results are ordered by priority. When `kind` is non-nil, candidates of
    /// other kinds are filtered out — used by the override chip in the UI.
    func resolve(_ rawTerm: String, kind: Kind? = nil) -> [Candidate] {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let lower = term.lowercased()
        let scope = kind.map { k in candidates.filter { $0.kind == k } } ?? candidates

        var ordered: [Candidate] = []
        var seen: Set<String> = []
        let push: (Candidate) -> Void = { cand in
            guard !seen.contains(cand.identifier) else { return }
            seen.insert(cand.identifier)
            ordered.append(cand)
        }

        for cand in scope where cand.id == term { push(cand) }
        for cand in scope where (cand.serial ?? "").lowercased() == lower { push(cand) }
        for cand in scope where cand.name.lowercased().contains(lower) { push(cand) }
        return ordered
    }

    // MARK: - Reading

    struct Loaded: Sendable {
        var candidates: [Candidate] = []
        var sourceFiles: [String] = []
        var loadedAt: Date?
        var lastError: String?
    }

    nonisolated static func read(profile: String) -> Loaded {
        guard ProfileService.isValid(profile),
              let workspace = ProfileService.workspaceURL(for: profile) else {
            return Loaded(lastError: "Workspace not found for profile `\(profile)`.")
        }
        let dataDir = (try? WorkspacePaths.dataDir(for: profile))
            ?? workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        // The data folder, so a snapshot read refuses a kind folder that is a link.
        let reader = Reader(dataRoot: dataDir)
        var loaded = Loaded()
        var newestDate: Date?

        if let url = reader.newestJSON(
            in: dataDir, named: ["computers-list", "computers_list", "computers"]) {
            loaded.candidates += reader.parseComputers(url)
            loaded.sourceFiles.append(url.lastPathComponent)
            newestDate = reader.maxDate(newestDate, reader.fileDate(url))
        }

        if let url = reader.newestJSON(
            in: dataDir, named: ["mobile-devices-list", "mobile_devices_list"]) {
            loaded.candidates += reader.parseMobile(url)
            loaded.sourceFiles.append(url.lastPathComponent)
            newestDate = reader.maxDate(newestDate, reader.fileDate(url))
        }

        loaded.loadedAt = newestDate
        if loaded.candidates.isEmpty {
            loaded.lastError = "No cached inventory found. Run a collect to populate the index."
        }
        return loaded
    }

    private struct Reader {
        let dataRoot: URL?
        /// Find the newest `.json` file under any `<dataDir>/<name>/` subdirectory,
        /// or `<dataDir>/<name>_*.json` flat files, for the supplied list of
        /// candidate names. Returns nil if no candidate exists.
        func newestJSON(in dataDir: URL, named names: [String]) -> URL? {
            let fm = FileManager.default
            var candidates: [URL] = []
            for name in names {
                let subdir = dataDir.appendingPathComponent(name, isDirectory: true)
                if let entries = FileManager.snapshotFolderEntries(in: subdir, options: []) {
                    candidates.append(contentsOf: entries.filter {
                        $0.pathExtension.lowercased() == "json"
                        && !$0.lastPathComponent.contains(".partial")
                        && $0.lastPathComponent.lowercased() != SnapshotManifest.fileName
                    })
                }
                if let flatEntries = try? fm.contentsOfDirectory(
                    at: dataDir, includingPropertiesForKeys: [.contentModificationDateKey], options: []
                ) {
                    candidates.append(contentsOf: flatEntries.filter { url in
                        let n = url.lastPathComponent
                        return url.pathExtension.lowercased() == "json"
                            && (n == "\(name).json" || n.hasPrefix("\(name)_"))
                            && !n.contains(".partial")
                    })
                }
            }
            return FileManager.newestSnapshot(among: candidates)
        }

        func parseComputers(_ url: URL) -> [Candidate] {
            guard let array = decodeArray(url) else { return [] }
            return array.compactMap { dict -> Candidate? in
                guard let rawID = stringValue(dict, "id"), !rawID.isEmpty else { return nil }
                let general = dict["general"] as? [String: Any] ?? [:]
                let hardware = dict["hardware"] as? [String: Any] ?? [:]
                let operatingSystem = dict["operatingSystem"] as? [String: Any] ?? [:]
                let name = stringValue(general, "name")
                    ?? stringValue(dict, "name")
                    ?? rawID
                let serial = stringValue(hardware, "serialNumber")
                    ?? stringValue(dict, "serialNumber")
                let osVersion = stringValue(operatingSystem, "version")
                    ?? stringValue(dict, "osVersion")
                return Candidate(kind: .computer, id: rawID, name: name, serial: serial, osVersion: osVersion)
            }
        }

        func parseMobile(_ url: URL) -> [Candidate] {
            guard let array = decodeArray(url) else { return [] }
            return array.compactMap { dict -> Candidate? in
                // Mobile records use `mobileDeviceId` at the root and `general.displayName`
                // for the human label; serial lives at `hardware.serialNumber`.
                guard let rawID = stringValue(dict, "mobileDeviceId")
                                ?? stringValue(dict, "id"),
                      !rawID.isEmpty else { return nil }
                let general = dict["general"] as? [String: Any] ?? [:]
                let hardware = dict["hardware"] as? [String: Any] ?? [:]
                // jamf-cli `mobile-devices-list` with default `--all=true` uses
                // `selectTableColumns` which flattens `general.displayName` → top-level
                // `name`. Check `dict["name"]` first so the common case resolves without
                // descending into a `general` block that is absent in that output shape.
                let name = stringValue(dict, "name")
                    ?? stringValue(general, "displayName")
                    ?? stringValue(general, "name")
                    ?? stringValue(dict, "displayName")
                    ?? rawID
                let serial = stringValue(hardware, "serialNumber")
                    ?? stringValue(dict, "serialNumber")
                let osVersion = stringValue(general, "osVersion")
                    ?? stringValue(dict, "osVersion")
                return Candidate(kind: .mobile, id: rawID, name: name, serial: serial, osVersion: osVersion)
            }
        }

        private func decodeArray(_ url: URL) -> [[String: Any]]? {
            guard let data = BoundedFile.readLogged(url, inside: dataRoot),
                  let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
            if let array = raw as? [[String: Any]] { return array }
            if let envelope = raw as? [String: Any],
               let results = envelope["results"] as? [[String: Any]] { return results }
            return nil
        }

        private func stringValue(_ dict: [String: Any], _ key: String) -> String? {
            switch dict[key] {
            case let s as String:
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case let i as Int: return String(i)
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }

        func fileDate(_ url: URL) -> Date? {
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        func maxDate(_ a: Date?, _ b: Date?) -> Date? {
            switch (a, b) {
            case (nil, let d), (let d, nil): return d
            case (let l?, let r?): return l > r ? l : r
            default: return nil
            }
        }
    }
}
