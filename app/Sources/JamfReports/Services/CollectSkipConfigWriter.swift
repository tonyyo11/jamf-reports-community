import Foundation

/// The Data Sources switches' write of `jamf_cli.collect_skip` and `jamf_cli.collect_opt_in`:
/// one source on or off, through `ConfigService.saveBlock`, outside `managedTopLevelKeys` like
/// `ChartsConfigWriter`.
enum CollectSkipConfigWriter {
    /// The two lists a switch can write.
    enum ListKey: String, CaseIterable {
        case collectSkip = "collect_skip"
        case collectOptIn = "collect_opt_in"
    }

    enum WriteError: Error, LocalizedError, Equatable {
        case invalidProfile(String)
        case coreSource(String)
        case unknownSource(String)
        /// An opt-in source has no collect_skip switch: it is off until turned on.
        case optInSource(String)
        /// Another Mac changed the list and this Mac has not confirmed it: a write now would
        /// confirm the peer's edit with this one.
        case changedOnAnotherMac

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): ProfileName.invalidMessage(profile)
            case .coreSource:
                L("This source cannot be turned off: the daily summary and most screens are built from it.")
            case .unknownSource(let kind): L("\(kind) is not a source this app collects.")
            case .optInSource(let kind):
                L("\(kind) is collected only when you turn it on in Data Sources.")
            case .changedOnAnotherMac: L("Changed on another Mac; confirm in Config Doctor")
            }
        }
    }

    /// Sets `key` to `list` in the `jamf_cli` block of `root`, removing the key when empty.
    static func apply(_ key: ListKey, list: [String], to root: inout YAMLCodec.YAMLMapping) {
        var block = root.value(for: "jamf_cli")?.mapping ?? .init(entries: [])
        if list.isEmpty {
            block.entries.removeAll { $0.key == key.rawValue }
        } else {
            block.set(key.rawValue, value: .sequence(list.map { .scalar(.string($0)) }))
        }
        root.set("jamf_cli", value: .mapping(block))
    }

    /// Turns `kind` on (removes it from the list) or off (adds it). On a pinned workspace the
    /// list the file holds at write time must still be the pinned one, else nothing is written
    /// (a peer's edit is never confirmed by this one); other entries stay as typed, the list is
    /// written sorted and removed when it empties. Dependents follow `patch-status` at read time.
    /// `beforeWrite` (tests) runs between the pin check and the write.
    @discardableResult
    static func setCollecting(
        _ kind: String, _ on: Bool, profile: String, appSupport: URL = AppSupport.directory(),
        beforeWrite: () -> Void = {}
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        let name = ReportEngine.normalizedKind(kind)
        guard ReportEngine.allSourceKinds.contains(name) else {
            throw WriteError.unknownSource(kind)
        }
        if ReportEngine.serverHealthOptInKinds.contains(name) { throw WriteError.optInSource(name) }
        let config = loadConfig(profile)
        let protectOnly = EnvironmentProfiles.resolve(config: config, workspace: profile)
            .isConfirmedProtectOnly(workspace: profile)
        let fleet = FleetState.load(dataDir: try? WorkspacePaths.dataDir(for: profile))
        guard ReportEngine.optionalKinds(protectOnly: protectOnly, fleet: fleet).contains(name)
        else {
            throw WriteError.coreSource(name)
        }
        let read = SharedConfigPin.collectSkipList(
            configured: config?.jamfCli?.collectSkip, profile: profile, appSupport: appSupport)
        if read.drifted { throw WriteError.changedOnAnotherMac }
        beforeWrite()
        let (result, written) = try write(
            .collectSkip, name: name, add: !on, pinnedText: read.pinnedText, profile: profile)
        if let written {
            SharedConfigPin.confirmWritten(
                written, key: .collectSkip, profile: profile, appSupport: appSupport)
        }
        return result
    }

    /// Turns the opt-in source `kind` on (adds it to `collect_opt_in`) or off (removes it). An
    /// addition is confirmed on this Mac as it is written; a removal needs no confirmation, since
    /// the pin drops what the file no longer lists. While another Mac's addition waits for a
    /// Confirm, a removal is still written and an addition is refused: it would confirm the
    /// peer's entry too.
    @discardableResult
    static func setOptedIn(
        _ on: Bool, kind: String, profile: String, appSupport: URL = AppSupport.directory(),
        beforeWrite: () -> Void = {}
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        let name = ReportEngine.normalizedKind(kind)
        guard ReportEngine.serverHealthOptInKinds.contains(name) else {
            throw WriteError.unknownSource(kind)
        }
        let read = SharedConfigPin.collectOptInList(
            configured: loadConfig(profile)?.jamfCli?.collectOptIn, profile: profile,
            appSupport: appSupport)
        if read.drifted, on { throw WriteError.changedOnAnotherMac }
        beforeWrite()
        let (result, written) = try write(
            .collectOptIn, name: name, add: on,
            pinnedText: read.drifted ? nil : read.pinnedText, profile: profile)
        if on, let written {
            SharedConfigPin.confirmWritten(
                written, key: .collectOptIn, profile: profile, appSupport: appSupport)
        }
        return result
    }

    private static func loadConfig(_ profile: String) -> ReportConfig? {
        ProfileService.workspaceURL(for: profile).flatMap {
            try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
        }
    }

    /// Adds or removes `name` in the file's list. A non-nil `pinnedText` must still equal the
    /// file's list, else a peer wrote in between and nothing is written. Returns the pinned
    /// form of the list it wrote, nil when nothing changed.
    private static func write(
        _ key: ListKey, name: String, add: Bool, pinnedText: String?, profile: String
    ) throws -> ((stamp: ConfigFileStamp, report: ConfigSaveReport), String?) {
        var peerChanged = false
        var written: String?
        let result = try ConfigService.saveBlock(key: "jamf_cli", profile: profile) { root in
            let block = root.value(for: "jamf_cli")?.mapping ?? .init(entries: [])
            let typed = block.value(for: key.rawValue)?.sequence?.compactMap(\.stringValue) ?? []
            // Equal to the pin after normalizing, so building on it builds on the pinned list.
            if let pinnedText, SharedConfigPin.collectSkipText(typed) != pinnedText {
                peerChanged = true
                return
            }
            var list = typed.filter { ReportEngine.normalizedKind($0) != name }
            if add { list.append(name) }
            list.sort()
            guard list != typed.sorted() else { return }
            written = SharedConfigPin.collectSkipText(list)
            apply(key, list: list, to: &root)
        }
        if peerChanged { throw WriteError.changedOnAnotherMac }
        return (result, written)
    }
}
