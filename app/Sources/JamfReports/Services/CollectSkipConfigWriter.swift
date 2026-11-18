import Foundation

/// The Data Sources switches' write of `jamf_cli.collect_skip`: one source on or off, through
/// `ConfigService.saveBlock`, outside `managedTopLevelKeys` like `ChartsConfigWriter`.
enum CollectSkipConfigWriter {
    enum WriteError: Error, LocalizedError, Equatable {
        case invalidProfile(String)
        case coreSource(String)
        case unknownSource(String)
        /// Another Mac changed the list and this Mac has not confirmed it: a write now would
        /// confirm the peer's edit with this one.
        case changedOnAnotherMac

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): ProfileName.invalidMessage(profile)
            case .coreSource:
                L("This source cannot be turned off: the daily summary and most screens are built from it.")
            case .unknownSource(let kind): L("\(kind) is not a source this app collects.")
            case .changedOnAnotherMac: L("Changed on another Mac; confirm in Config Doctor")
            }
        }
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
        let config = ProfileService.workspaceURL(for: profile).flatMap {
            try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
        }
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
        var peerChanged = false
        var written: String?
        let result = try ConfigService.saveBlock(key: "jamf_cli", profile: profile) { root in
            var block = root.value(for: "jamf_cli")?.mapping ?? .init(entries: [])
            let typed = block.value(for: "collect_skip")?.sequence?.compactMap(\.stringValue) ?? []
            // Equal to the pin after normalizing, so building on it builds on the pinned list.
            if let pinned = read.pinnedText, SharedConfigPin.collectSkipText(typed) != pinned {
                peerChanged = true
                return
            }
            var list = typed.filter { ReportEngine.normalizedKind($0) != name }
            if !on { list.append(name) }
            list.sort()
            guard list != typed.sorted() else { return }
            written = SharedConfigPin.collectSkipText(list)
            if list.isEmpty {
                block.entries.removeAll { $0.key == "collect_skip" }
            } else {
                block.set("collect_skip", value: .sequence(list.map { .scalar(.string($0)) }))
            }
            root.set("jamf_cli", value: .mapping(block))
        }
        if peerChanged { throw WriteError.changedOnAnotherMac }
        if let written {
            SharedConfigPin.confirmWritten(
                written, key: .collectSkip, profile: profile, appSupport: appSupport)
        }
        return result
    }
}
