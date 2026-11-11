import Foundation

// MARK: - ProfileProductType

/// The product type a jamf-cli profile serves, from `EnvironmentProfiles`: Jamf School when
/// School is the environment's MDM (`profiles.jamf_school`, or `school_cli.enabled` with a blank
/// `school_cli.profile` or the workspace's own), otherwise Jamf Pro. A School login recorded in a
/// Jamf Pro workspace by builds before 2.10 is not used there. Either way Protect augments the run
/// when the environment has it (2.11: Jamf Protect works with Jamf School too, Experimental),
/// with its own login.
enum ProfileProductType: Equatable, Sendable {
    case jamfPro
    case jamfSchool
}

// MARK: - DetectedProduct

/// Result of `ProfileProductType.detect(from:profile:)`.
struct DetectedProduct: Sendable {
    let type: ProfileProductType
    /// True when the workspace also has `protect.enabled == true`.
    let runsProtect: Bool
}

extension ProfileProductType {

    /// Detect the product type from a decoded `ReportConfig`.
    ///
    /// - Parameters:
    ///   - config: The loaded config for the profile. When nil (load failure),
    ///     defaults to `.jamfPro` with `runsProtect: false` — same behaviour as before
    ///     the router existed, and loud: callers log the nil case before calling this.
    ///   - profile: The workspace's own profile (`EnvironmentProfiles.resolve`).
    static func detect(from config: ReportConfig?, profile: String) -> DetectedProduct {
        let environment = EnvironmentProfiles.resolve(config: config, workspace: profile)
        return DetectedProduct(
            type: environment.isSchool ? .jamfSchool : .jamfPro,
            runsProtect: environment.runsProtect)
    }
}

// MARK: - CollectRouter

/// Dispatches a collect run to the right engine function(s) based on profile product type.
///
/// The three collect params default to the real `ReportEngine` statics so production
/// call sites pass nothing. Tests inject spies that record which closures were called.
///
/// Protect failure semantics: if `protectCollect` throws, the error is logged as a warning
/// and the function returns normally — the Pro run already succeeded and is the primary
/// deliverable. Do not rethrow.
///
/// A Jamf School collect is followed by Protect under the same rules: the gate stands it down
/// or ends it for the day like a Jamf Pro one, and a stop skips the follow.
///
/// Protect runs only when the Pro collect returned `.collected`. A Pro collect that
/// stood down for a peer on a shared workspace, or found today's full collect already
/// done, fetched nothing — and Protect has no claim or cadence of its own, so running
/// it anyway would collect beside the peer that holds the claim, or fetch Protect
/// again on a day the Pro collect itself skipped.
///
/// A School collect writes its own daily summary (`ReportEngine.writeSchoolSummary`), and a
/// Protect-only environment writes one from its landed kinds.
enum CollectRouter {

    /// Type of the pro-collect closure, matching `ReportEngine.collect`'s signature: the
    /// workspace whose folders the run writes, and the Jamf Pro profile its commands run as.
    /// The returned disposition decides whether Protect follows (see above).
    typealias ProCollect = @Sendable (
        _ workspace: WorkspaceID,
        _ profile: String,
        _ workspacePaths: WorkspacePaths.Type,
        _ tiers: Set<CollectionTier>,
        _ skipExpensive: Bool,
        _ force: Bool,
        _ onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> ReportEngine.CollectDisposition

    /// `ReportEngine.collect` as the default Pro closure calls it: the `ProCollect` arguments plus
    /// the run's start (`now`). Tests replace it to see the day the router hands the engine.
    typealias ProEngine = @Sendable (
        _ workspace: WorkspaceID,
        _ profile: String,
        _ workspacePaths: WorkspacePaths.Type,
        _ tiers: Set<CollectionTier>,
        _ skipExpensive: Bool,
        _ force: Bool,
        _ now: Date,
        _ onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> ReportEngine.CollectDisposition

    /// Type of the school-collect closure, matching `ReportEngine.schoolCollect`'s signature:
    /// the workspace and the Jamf School login.
    typealias SchoolCollect = @Sendable (
        _ workspace: WorkspaceID,
        _ profile: String,
        _ workspacePaths: WorkspacePaths.Type,
        _ tiers: Set<CollectionTier>,
        _ force: Bool,
        _ onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> Void

    /// Type of the protect-collect closure, matching `ReportEngine.protectCollect`'s signature.
    typealias ProtectCollect = @Sendable (
        _ profile: String,
        _ dataDir: URL,
        _ onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> [String]

    /// Type of the Security Cloud collect closure, matching `ReportEngine.securityCollect`.
    typealias SecurityCollect = @Sendable (
        _ profile: String,
        _ dataDir: URL,
        _ collectSkip: Set<String>,
        _ onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> [String]

    /// Type of the gate closure, matching `ReportEngine.environmentGate`'s shape.
    typealias Gate = @Sendable (
        _ workspace: WorkspaceID,
        _ workspacePaths: WorkspacePaths.Type,
        _ tiers: Set<CollectionTier>,
        _ force: Bool,
        _ now: Date,
        _ onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> ReportEngine.EnvironmentGate

    static let realGate: Gate = { workspace, paths, tiers, force, now, onLine in
        ReportEngine.environmentGate(
            workspace: workspace, workspacePaths: paths, tiers: tiers, force: force, now: now,
            onLine: onLine)
    }

    /// Route a collect run for `workspace` to the correct engine function(s). Each product's
    /// `-p` comes from `EnvironmentProfiles`, resolved once here before the pin checkpoint; the
    /// product check probes the same Jamf Pro slot the collect launches with.
    ///
    /// - Parameters:
    ///   - workspace: The workspace whose folders the run reads and writes.
    ///   - tiers: Collection tiers (School collects with the refresh or inventory tier).
    ///   - skipExpensive: Skip expensive per-device Pro commands (ignored for School).
    ///   - force: Bypass the once-per-day guard (Pro) and the cadence (Pro and School).
    ///   - config: Loaded config for the profile; pass nil when load failed. A nil config
    ///     degrades to Jamf Pro (same behaviour as before this router existed).
    ///   - workspacePaths: Path resolver (injectable for tests).
    ///   - now: The run's start, which dates the Jamf Pro collect's summary. A default is read at
    ///     entry, before the product probe below, so the probe's time never moves the day.
    ///   - proCollect: Closure wrapping `ReportEngine.collect`; nil is the real one.
    ///   - schoolCollect: Closure wrapping `ReportEngine.schoolCollect`. Defaults to the real static.
    ///   - protectCollect: Closure wrapping `ReportEngine.protectCollect`. Defaults to the real static.
    ///   - resolved: The Jamf Pro slot's resolved auth method and product
    ///     (`ProfileAuthMethod.resolve`).
    ///     Nil means "could not ask" and runs the collect.
    ///   - gate: The once-per-day guard and shared-workspace claim, asked once before any product
    ///     runs; a stop skips Jamf Pro or Jamf School and passes its disposition to Protect.
    ///   - onLine: Progress log callback.
    ///
    /// A collect started outside a recording run keeps its attention items in the app record.
    static func run(
        workspace: WorkspaceID,
        tiers: Set<CollectionTier> = Set(CollectionTier.allCases),
        skipExpensive: Bool = false,
        force: Bool = false,
        config: ReportConfig?,
        workspacePaths: WorkspacePaths.Type = WorkspacePaths.self,
        now: Date = Date(),
        proCollect: ProCollect? = nil,
        proEngine: @escaping ProEngine = realProEngine,
        schoolCollect: SchoolCollect = defaultSchoolCollect,
        protectCollect: ProtectCollect = defaultProtectCollect,
        securityCollect: SecurityCollect = defaultSecurityCollect,
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved? = {
            ProfileAuthMethod.resolve(profile: $0)
        },
        gate: @escaping Gate = realGate,
        locateJamfCLI: @escaping @Sendable () -> URL? = { ExecutableLocator.locate("jamf-cli") },
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws {
        try await AttentionLog.recording(profile: workspace.name) {
            try await routed(
                workspace: workspace, tiers: tiers, skipExpensive: skipExpensive, force: force,
                config: config, workspacePaths: workspacePaths,
                proCollect: proCollect ?? defaultProCollect(now: now, engine: proEngine),
                schoolCollect: schoolCollect, protectCollect: protectCollect,
                securityCollect: securityCollect,
                resolved: resolved, gate: gate, locateJamfCLI: locateJamfCLI, now: now,
                onLine: onLine)
        }
    }

    private static func routed(
        workspace: WorkspaceID,
        tiers: Set<CollectionTier>,
        skipExpensive: Bool,
        force: Bool,
        config: ReportConfig?,
        workspacePaths: WorkspacePaths.Type,
        proCollect: ProCollect,
        schoolCollect: SchoolCollect,
        protectCollect: ProtectCollect,
        securityCollect: SecurityCollect,
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved?,
        gate: Gate,
        locateJamfCLI: @escaping @Sendable () -> URL?,
        now: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws {
        // First, before anything touches the workspace: jamf-cli never checks a profile against
        // the command's product, so a Protect, Security Cloud or organization-level profile
        // would send Jamf Pro commands. A Jamf School workspace is routed to School collect
        // below and is not a Pro run.
        let profile = workspace.name
        let environment = EnvironmentProfiles.resolve(config: config, workspace: profile)
        let detected = ProfileProductType.detect(from: config, profile: profile)
        if detected.type == .jamfPro, !environment.isProtectOnly,
           let refusal = await CLIBridge.refusesProCommand(
            profile: profile, operation: "Collect", onLine: onLine, environment: environment,
            resolved: resolved
        ) {
            throw CLIBridgeError.wrongProduct(refusal)
        }
        // Every collect path passes through here; the GUI's also checks when it
        // binds the workspace, but the CLI and schedules load config directly. The owner is the
        // existing folder's own spelling, never what config.yaml says.
        if let owner = ProfileService.caseVariantWorkspace(of: profile) {
            let conflict = CLIBridgeError.profileCaseConflict(profile: profile, owner: owner)
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] \(conflict.localizedDescription)"))
            throw conflict
        }
        if let refusal = environment.refusal(workspace: profile) {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] \(refusal)"))
            throw CLIBridgeError.wrongProduct(refusal)
        }
        // An old-shape file derives the MDM from the workspace, and a block without one is
        // refused above.
        guard environment.mdm != nil || environment.isProtectOnly else {
            throw CLIBridgeError.wrongProduct(
                "'\(ConfigSchema.displayText(profile))' names no Jamf Pro or Jamf School profile")
        }
        // Before the claim, retention and the run's first write: a peer's planted or edited
        // Protect-only block gets nothing from this Mac until it is confirmed.
        if environment.isProtectOnly, !SharedConfigPin.protectAllowed(
            profile: profile, name: environment.protect ?? "") {
            let reason = protectNotConfirmedReason(environment)
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] \(reason)"))
            throw ReportEngineError.protectNotConfirmed(reason)
        }
        // Shared workspace: say which pinned config.yaml keys changed on this Mac before any
        // collect reads them, for Jamf Pro, Protect and Jamf School alike.
        SharedConfigPin.checkpoint(profile: profile, onLine: onLine)
        let landed = LandedSources()
        // Protect, then Jamf Security Cloud: both are add-ons to the MDM and follow it under the
        // same rule (a Protect-only environment never reaches this, so it collects no Security
        // Cloud). What each lands is recorded for the daily summary's `products` and figures.
        func followWithAddOns(_ disposition: ReportEngine.CollectDisposition) async {
            landed.record(.protect, await collectProtect(
                environment: environment, profile: profile, disposition: disposition,
                workspacePaths: workspacePaths, protectCollect: protectCollect,
                resolved: resolved, onLine: onLine))
            landed.record(.securityCloud, await collectSecurityCloud(
                environment: environment, profile: profile, disposition: disposition,
                collectSkip: ReportEngine.collectSkipKinds(config?.jamfCli?.collectSkip),
                workspacePaths: workspacePaths, securityCollect: securityCollect,
                resolved: resolved, onLine: onLine))
        }
        // Before any product: a stop covers Jamf Pro, Jamf School and Protect alike.
        switch gate(workspace, workspacePaths, tiers, force, now, onLine) {
        case .stop(let disposition):
            // The gate logged why; a Protect-only environment has nothing else to follow.
            if !environment.isProtectOnly { await followWithAddOns(disposition) }
            return
        case .proceed(let holdsClaim, let coordinating):
            defer { if holdsClaim { SharedWorkspace.release(profile: profile) } }
            // Snapshot retention (v2.2.0): config-driven, OFF by default, once per calendar day
            // by its own marker. Here, past the gate, so every product's run sweeps once;
            // best-effort, never fails the collect.
            SnapshotRetentionService.sweepIfDue(profile: profile, onLine: onLine)
            func finalize() {
                finalizeEnvironment(
                    environment: environment, workspace: workspace, workspacePaths: workspacePaths,
                    landed: landed.all, day: now, announcesWrite: !landed.mdmSummaryUnwritten,
                    maxCacheAgeHours: config?.jamfCli?.resolvedMaxCacheAgeHours ?? 168,
                    onLine: onLine)
            }
            let watched: @Sendable (CLIBridge.LogLine) -> Void = { line in
                if line.text.hasPrefix(ReportEngine.summaryNotWrittenMarker) {
                    landed.mdmSummaryUnwritten = true
                }
                onLine(line)
            }
            if environment.isProtectOnly {
                landed.record(.protect, try await collectProtectOnly(
                    environment: environment, workspace: workspace, workspacePaths: workspacePaths,
                    protectCollect: protectCollect, resolved: resolved,
                    locateJamfCLI: locateJamfCLI, onLine: onLine))
                finalize()
                if coordinating { SharedWorkspace.recordActivity(profile: profile) }
                return
            }
            guard let mdm = environment.mdm else {
                throw CLIBridgeError.wrongProduct(
                    "'\(ConfigSchema.displayText(profile))' names no Jamf Pro or Jamf School "
                        + "profile")
            }
            do {
                try await ReportEngine.$routedEnvironment.withValue(environment) {
                    try await ReportEngine.$landedSources.withValue(landed) {
                        try await runProducts(
                            detected: detected, workspace: workspace, mdm: mdm, tiers: tiers,
                            skipExpensive: skipExpensive, force: force,
                            workspacePaths: workspacePaths, proCollect: proCollect,
                            schoolCollect: schoolCollect, followWithAddOns: followWithAddOns,
                            onLine: watched)
                    }
                }
            } catch let verdict as ReportEngineError where verdict.isCollectVerdict {
                // Protect may have landed after the MDM failed; the verdict stays the result.
                finalize()
                throw verdict
            }
            finalize()
            // Stamp this machine's activity so other Macs sharing the folder see the collect
            // without parsing summaries. One file per host, so runs never write the same path.
            if coordinating { SharedWorkspace.recordActivity(profile: profile) }
        }
    }

    private static func runProducts(
        detected: DetectedProduct,
        workspace: WorkspaceID,
        mdm: String,
        tiers: Set<CollectionTier>,
        skipExpensive: Bool,
        force: Bool,
        workspacePaths: WorkspacePaths.Type,
        proCollect: ProCollect,
        schoolCollect: SchoolCollect,
        followWithAddOns: (ReportEngine.CollectDisposition) async -> Void,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws {
        let profile = workspace.name
        switch detected.type {
        case .jamfSchool:
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] routing \(profile) → Jamf School collect"))
            do {
                try await schoolCollect(workspace, mdm, workspacePaths, tiers, force, onLine)
            } catch let verdict as ReportEngineError where verdict.isCollectVerdict {
                await followWithAddOns(.collected)
                throw verdict
            }
            await followWithAddOns(.collected)

        case .jamfPro:
            let disposition: ReportEngine.CollectDisposition
            do {
                disposition = try await proCollect(
                    workspace, mdm, workspacePaths, tiers, skipExpensive, force, onLine
                )
            } catch let verdict as ReportEngineError where verdict.isCollectVerdict {
                // The Pro run reached Jamf and failed (dead credentials, a dead run): Protect has
                // its own login and may still answer. The Pro error stays the run's result.
                // The School case below follows the same rule.
                await followWithAddOns(.collected)
                throw verdict
            }
            await followWithAddOns(disposition)
        }
    }

    /// A Protect-only environment: Protect is the whole run, so a refusal, a throw or no landed
    /// source fails it (unlike the follow after an MDM), and a landed one writes today's summary.
    private static func collectProtectOnly(
        environment: EnvironmentProfiles,
        workspace: WorkspaceID,
        workspacePaths: WorkspacePaths.Type,
        protectCollect: ProtectCollect,
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved?,
        locateJamfCLI: @Sendable () -> URL?,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> [String] {
        let profile = workspace.name
        let protectProfile = environment.protect ?? ""
        guard SharedConfigPin.protectAllowed(profile: profile, name: protectProfile) else {
            let reason = protectNotConfirmedReason(environment)
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] \(reason)"))
            throw ReportEngineError.protectNotConfirmed(reason)
        }
        if let refusal = await ProfileAuthMethod.protectRefusal(
            profile: protectProfile, resolved: resolved) {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] \(refusal)"))
            throw CLIBridgeError.wrongProduct(refusal)
        }
        // The floor and a login jamf-cli does not list, as a Jamf Pro collect checks them. No
        // binary is left to the Protect collect to report.
        if let bin = locateJamfCLI() {
            _ = try await ReportEngine.collectPreflight(
                profile: protectProfile, binary: bin, onLine: onLine)
        }
        let dataDir = try workspacePaths.dataDir(for: profile)
        onLine(.init(timestamp: Date(), level: .info, text: "[info] routing \(profile) → "
            + "Jamf Protect collect (no Jamf Pro or Jamf School in this environment)"))
        let kinds = try await protectCollect(protectProfile, dataDir, onLine)
        guard !kinds.isEmpty else {
            throw ReportEngineError.collectDead(
                profile: profile, failedCount: ReportEngine.protectCommandMatrix(profile: "").count)
        }
        return kinds
    }

    /// One finalize per run past the gate; see `ReportEngine.finalizeEnvironmentSummary`.
    private static func finalizeEnvironment(
        environment: EnvironmentProfiles,
        workspace: WorkspaceID,
        workspacePaths: WorkspacePaths.Type,
        landed: [EnvironmentProducts.Product: Set<String>],
        day: Date,
        announcesWrite: Bool = true,
        maxCacheAgeHours: Int,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) {
        guard let dataDir = try? workspacePaths.dataDir(for: workspace.name),
              let summariesDir = try? workspacePaths.summariesDir(for: workspace.name) else {
            onLine(.init(timestamp: Date(), level: .warn, text:
                "\(ReportEngine.summaryNotWrittenMarker) the summaries directory is unavailable"))
            return
        }
        ReportEngine.finalizeEnvironmentSummary(
            summariesDir: summariesDir, dataDir: dataDir, environment: environment,
            workspace: workspace, landed: landed, day: day, announcesWrite: announcesWrite,
            maxCacheAgeHours: maxCacheAgeHours, onLine: onLine)
    }

    /// The Protect half of a Jamf Pro or Jamf School run. Never throws: a Protect failure is a
    /// `[partial]` line and the Pro or School run's result stands.
    private static func collectProtect(
        environment: EnvironmentProfiles,
        profile: String,
        disposition: ReportEngine.CollectDisposition,
        workspacePaths: WorkspacePaths.Type,
        protectCollect: ProtectCollect,
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved?,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> [String] {
        guard environment.runsProtect else { return [] }
        guard SharedConfigPin.protectAllowed(
            profile: profile, name: environment.protect ?? "") else {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[skip] protect: \(environment.protectKey) changed in the shared "
                            + "config.yaml and is not confirmed on this Mac — Protect not collected"))
            return []
        }
        guard disposition == .collected else {
            let product = environment.isSchool ? "Jamf School" : "Jamf Pro"
            let reason = disposition == .stoodDown
                ? "the \(product) collect stood down for another Mac"
                : "\(product) already collected today"
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[skip] protect: \(reason) — Protect not collected"))
            return []
        }
        // Protect augments Pro: a failure does not fail the run, but reads as Partial.
        // A blank name is not a connection; a login of another product would send Protect
        // commands to the wrong API.
        let protectProfile = environment.protect ?? ""
        let notCollected: String? = if protectProfile.isEmpty {
            "protect.profile is blank"
        } else {
            await ProfileAuthMethod.protectRefusal(profile: protectProfile, resolved: resolved)
        }
        if let notCollected {
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] Jamf Protect not collected: \(notCollected)"))
            return []
        }
        guard let dataDir = try? workspacePaths.dataDir(for: profile) else {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] protect: could not resolve dataDir for \(profile) — skipping"))
            return []
        }
        onLine(.init(timestamp: Date(), level: .info,
                     text: "[info] running protect collect for \(profile)"))
        do {
            return try await protectCollect(protectProfile, dataDir, onLine)
        } catch {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "\(ReportEngine.protectCollectFailedMarker)\(error.localizedDescription)"))
            return []
        }
    }

    /// The Jamf Security Cloud half of a Jamf Pro or Jamf School run, under Protect's rules:
    /// only after a `.collected` result, never throws (a failure is a `[partial]` line), and a
    /// login of a known other product gets one `[warn]` and nothing recorded.
    private static func collectSecurityCloud(
        environment: EnvironmentProfiles,
        profile: String,
        disposition: ReportEngine.CollectDisposition,
        collectSkip: Set<String>,
        workspacePaths: WorkspacePaths.Type,
        securityCollect: SecurityCollect,
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved?,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> [String] {
        guard let login = environment.securityCloud else { return [] }
        guard SharedConfigPin.securityCloudAllowed(profile: profile, name: login) else {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[skip] Jamf Security Cloud not collected: profiles.security_cloud "
                            + "changed in the shared config.yaml and is not confirmed on this Mac"))
            return []
        }
        guard disposition == .collected else {
            let product = environment.isSchool ? "Jamf School" : "Jamf Pro"
            let reason = disposition == .stoodDown
                ? "the \(product) collect stood down for another Mac"
                : "\(product) already collected today"
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[skip] security-risk: \(reason) — "
                            + "Jamf Security Cloud not collected"))
            return []
        }
        if let refusal = await ProfileAuthMethod.securityCloudRefusal(
            profile: login, resolved: resolved) {
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] Jamf Security Cloud not collected: \(refusal)"))
            return []
        }
        guard let dataDir = try? workspacePaths.dataDir(for: profile) else {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] security-risk: could not resolve dataDir for \(profile) "
                    + "— skipping"))
            return []
        }
        do {
            return try await securityCollect(login, dataDir, collectSkip, onLine)
        } catch {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "\(ReportEngine.securityCollectFailedMarker)\(error.localizedDescription)"))
            return []
        }
    }

    /// Why a collect run on `profile` must not start, or nil. For entry points that name a
    /// profile themselves (a schedule, the CLI) and must refuse before they create anything in
    /// its workspace. A `profiles:` block that cannot run (`EnvironmentProfiles.refusal`) refuses
    /// any product; a Jamf School workspace is otherwise not a Pro run; a Protect-only
    /// environment is refused for an unconfirmed `profiles.protect` or a login of another
    /// product, the two refusals `collectProtectOnly` would throw after the run record opened.
    /// `run` applies the same rules. Can spawn `jamf-cli config list`.
    static func runRefusal(
        profile: String, operation: String, config: ReportConfig?,
        appSupport: URL = AppSupport.directory(),
        resolved: @Sendable (String) -> ProfileAuthMethod.Resolved? = { ProfileAuthMethod.resolve(profile: $0) }
    ) -> String? {
        // First: a merged-away or connected login has no folder, and nothing may create one.
        if let refusal = ProfileService.connectedProfileRefusal(of: profile) { return refusal }
        let environment = EnvironmentProfiles.resolve(config: config, workspace: profile)
        if let refusal = environment.refusal(workspace: profile) { return refusal }
        if environment.isProtectOnly {
            let name = environment.protect ?? ""
            guard SharedConfigPin.protectAllowed(profile: profile, name: name, appSupport: appSupport)
            else { return protectNotConfirmedReason(environment) }
            return resolved(name)?.protectRefusal(profile: name)
        }
        guard !environment.isSchool, let jamfPro = environment.jamfPro else { return nil }
        return ProfileAuthMethod.refusal(profile: jamfPro, operation: operation)
    }

    static func protectNotConfirmedReason(_ environment: EnvironmentProfiles) -> String {
        "\(environment.protectKey) was changed in the shared config.yaml and is awaiting "
            + "confirmation on this Mac (Config Doctor)"
    }

    /// Why `pro backup` has nothing to do for a Jamf School workspace; the scheduled skip, the
    /// CLI `backup` and `schedules add --mode backup` all say this.
    static func schoolBackupReason(profile: String) -> String {
        L("`pro backup` is a Jamf Pro command and '\(profile)' is configured for Jamf School (school_cli.enabled in config.yaml)")
    }

    /// Why a backup of `profile` must not run, or nil: a Jamf School workspace (decided from
    /// config.yaml, so it holds without a readable jamf-cli) or any `runRefusal`.
    static func backupRefusal(profile: String, config: ReportConfig?) -> String? {
        let environment = EnvironmentProfiles.resolve(config: config, workspace: profile)
        // The School sentence is backup's own, so it comes before `proCommandRefusal`'s.
        if let refusal = environment.refusal(workspace: profile) { return refusal }
        if environment.isSchool { return schoolBackupReason(profile: profile) }
        if let refusal = environment.proCommandRefusal(workspace: profile, operation: "Backup") {
            return refusal
        }
        return runRefusal(profile: profile, operation: "Backup", config: config)
    }

    /// The refusals `scheduledRunSingleBody` applies to a per-profile schedule: a case variant
    /// whose folder is another spelling's, in every mode, then `runRefusal` for a schedule
    /// that sends commands. A multi schedule is never refused here.
    static func scheduleRunRefusal(_ schedule: Schedule) -> String? {
        guard !schedule.isMulti else { return nil }
        if let refusal = ProfileService.caseVariantRefusal(of: schedule.profile)
            ?? ProfileService.connectedProfileRefusal(of: schedule.profile) { return refusal }
        guard schedule.mode != .jamfCLIOnly else { return nil }
        return runRefusal(
            profile: schedule.profile, operation: "Scheduled \(schedule.mode.rawValue) run",
            config: collectRoutingConfig(profile: schedule.profile))
    }

    // MARK: - Default closures (production)

    /// Default production closure wrapping `ReportEngine.collect`.
    static func defaultProCollect(now: Date, engine: @escaping ProEngine) -> ProCollect {
        { workspace, profile, workspacePaths, tiers, skipExpensive, force, onLine in
            try await engine(
                workspace, profile, workspacePaths, tiers, skipExpensive, force, now, onLine)
        }
    }

    static let realProEngine: ProEngine = {
        workspace, profile, workspacePaths, tiers, skipExpensive, force, now, onLine in
        try await Localization.english {
try await ReportEngine.collect(
            workspace: workspace,
            profile: profile,
            workspacePaths: workspacePaths,
            tiers: tiers,
            skipExpensive: skipExpensive,
            force: force,
            now: now,
            onLine: onLine
        )
}
    }

    /// Default production closure wrapping `ReportEngine.schoolCollect`.
    static let defaultSchoolCollect: SchoolCollect = {
        workspace, profile, workspacePaths, tiers, force, onLine in
        try await Localization.english {
try await ReportEngine.schoolCollect(
            workspace: workspace,
            profile: profile,
            workspacePaths: workspacePaths,
            tiers: tiers,
            force: force,
            onLine: onLine
        )
}
    }

    /// Default production closure wrapping `ReportEngine.securityCollect`.
    static let defaultSecurityCollect: SecurityCollect = { profile, dataDir, skip, onLine in
        try await Localization.english {
            try await ReportEngine.securityCollect(
                profile: profile, dataDir: dataDir, collectSkip: skip, onLine: onLine)
        }
    }

    /// Default production closure wrapping `ReportEngine.protectCollect`.
    static let defaultProtectCollect: ProtectCollect = { profile, dataDir, onLine in
        try await Localization.english {
return try await ReportEngine.protectCollect(
            profile: profile,
            dataDir: dataDir,
            onLine: onLine
        )
}
    }
}

extension ReportEngineError {
    /// A collect that ran and failed as a whole (credentials dead, every call failed), as
    /// opposed to a refusal before it started.
    var isCollectVerdict: Bool {
        switch self {
        case .authExpired, .collectDead: true
        default: false
        }
    }
}
