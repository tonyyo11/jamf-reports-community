import Foundation

// MARK: - ProfileProductType

/// The product type a jamf-cli profile serves, derived from config.yaml.
///
/// Routing rules:
/// - `school_cli.enabled == true` and `school_cli.profile` blank or the workspace's own
///   profile → `.jamfSchool` (school collect only, never pro).
/// - Otherwise → `.jamfPro`. That includes a `school_cli.profile` naming some other jamf-cli
///   profile: a School login recorded in a Jamf Pro workspace (written by builds before 2.10)
///   is not used there.
/// - Either way, `protect?.enabled == true` means Protect augments the run (2.11: Jamf Protect
///   works with Jamf School too, Experimental).
///
/// Protect is an ADD-ON to a Jamf Pro or Jamf School workspace, not a standalone product type;
/// it runs with its own `protect.profile` login.
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
    ///   - profile: The workspace's own profile, which `school_cli.profile` must equal
    ///     (exactly, as jamf-cli names are case-sensitive) or leave blank for School.
    static func detect(from config: ReportConfig?, profile: String) -> DetectedProduct {
        guard let config else {
            return DetectedProduct(type: .jamfPro, runsProtect: false)
        }
        if config.schoolCli?.isPrimary(forWorkspace: profile) == true {
            return DetectedProduct(
                type: .jamfSchool, runsProtect: config.protect?.isEnabled == true)
        }
        return DetectedProduct(type: .jamfPro, runsProtect: config.protect?.isEnabled == true)
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
/// A Jamf School collect is followed by Protect under the same rules (it has no stand-down
/// or once-a-day guard, so it always counts as `.collected`).
///
/// Protect runs only when the Pro collect returned `.collected`. A Pro collect that
/// stood down for a peer on a shared workspace, or found today's full collect already
/// done, fetched nothing — and Protect has no claim or cadence of its own, so running
/// it anyway would collect beside the peer that holds the claim, or fetch Protect
/// again on a day the Pro collect itself skipped.
///
/// School collect does not emit a `summary.json` trend snapshot today. That is a
/// noted gap, not a regression: School profiles had no collect at all before this
/// router was introduced.
enum CollectRouter {

    /// Type of the pro-collect closure, matching `ReportEngine.collect`'s signature.
    /// The returned disposition decides whether Protect follows (see above).
    typealias ProCollect = @Sendable (
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
        _ profile: String,
        _ workspacePaths: WorkspacePaths.Type,
        _ tiers: Set<CollectionTier>,
        _ skipExpensive: Bool,
        _ force: Bool,
        _ now: Date,
        _ onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> ReportEngine.CollectDisposition

    /// Type of the school-collect closure, matching `ReportEngine.schoolCollect`'s signature.
    typealias SchoolCollect = @Sendable (
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
    ) async throws -> Void

    /// Route a collect run for `profile` to the correct engine function(s).
    ///
    /// - Parameters:
    ///   - profile: Validated profile slug (caller has already verified `ProfileService.isValid`).
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
    ///   - resolved: The profile's resolved auth method and product (`ProfileAuthMethod.resolve`).
    ///     Nil means "could not ask" and runs the collect.
    ///   - onLine: Progress log callback.
    ///
    /// A collect started outside a recording run keeps its attention items in the app record.
    static func run(
        profile: String,
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
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved? = {
            ProfileAuthMethod.resolve(profile: $0)
        },
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws {
        try await AttentionLog.recording(profile: profile) {
            try await routed(
                profile: profile, tiers: tiers, skipExpensive: skipExpensive, force: force,
                config: config, workspacePaths: workspacePaths,
                proCollect: proCollect ?? defaultProCollect(now: now, engine: proEngine),
                schoolCollect: schoolCollect, protectCollect: protectCollect,
                resolved: resolved, onLine: onLine)
        }
    }

    private static func routed(
        profile: String,
        tiers: Set<CollectionTier>,
        skipExpensive: Bool,
        force: Bool,
        config: ReportConfig?,
        workspacePaths: WorkspacePaths.Type,
        proCollect: ProCollect,
        schoolCollect: SchoolCollect,
        protectCollect: ProtectCollect,
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved?,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws {
        // First, before anything touches the workspace: jamf-cli never checks a profile against
        // the command's product, so a Protect, Security Cloud or organization-level profile
        // would send Jamf Pro commands. A Jamf School workspace is routed to School collect
        // below and is not a Pro run.
        let detected = ProfileProductType.detect(from: config, profile: profile)
        if detected.type == .jamfPro, let refusal = await CLIBridge.refusesProCommand(
            profile: profile, operation: "Collect", onLine: onLine, resolved: resolved
        ) {
            throw CLIBridgeError.wrongProduct(refusal)
        }
        // Every collect path passes through here; the GUI's also checks when it
        // binds the workspace, but the CLI and schedules load config directly.
        if let owner = config?.jamfCli?.resolvedProfile,
           ProfileService.isCaseVariant(owner, of: profile) {
            let conflict = CLIBridgeError.profileCaseConflict(profile: profile, owner: owner)
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] \(conflict.localizedDescription)"))
            throw conflict
        }
        // Shared workspace: say which pinned config.yaml keys changed on this Mac before any
        // collect reads them, for Jamf Pro, Protect and Jamf School alike.
        SharedConfigPin.checkpoint(profile: profile, onLine: onLine)
        func followWithProtect(_ disposition: ReportEngine.CollectDisposition) async {
            await collectProtect(
                detected: detected, config: config, profile: profile, disposition: disposition,
                workspacePaths: workspacePaths, protectCollect: protectCollect,
                resolved: resolved, onLine: onLine)
        }
        switch detected.type {
        case .jamfSchool:
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] routing \(profile) → Jamf School collect"))
            do {
                try await schoolCollect(profile, workspacePaths, tiers, force, onLine)
            } catch let verdict as ReportEngineError where verdict.isCollectVerdict {
                await followWithProtect(.collected)
                throw verdict
            }
            await followWithProtect(.collected)

        case .jamfPro:
            let disposition: ReportEngine.CollectDisposition
            do {
                disposition = try await proCollect(
                    profile, workspacePaths, tiers, skipExpensive, force, onLine
                )
            } catch let verdict as ReportEngineError where verdict.isCollectVerdict {
                // The Pro run reached Jamf and failed (dead credentials, a dead run): Protect has
                // its own login and may still answer. The Pro error stays the run's result.
                // The School case below follows the same rule.
                await followWithProtect(.collected)
                throw verdict
            }
            await followWithProtect(disposition)
        }
    }

    /// The Protect half of a Jamf Pro or Jamf School run. Never throws: a Protect failure is a
    /// `[partial]` line and the Pro or School run's result stands.
    private static func collectProtect(
        detected: DetectedProduct,
        config: ReportConfig?,
        profile: String,
        disposition: ReportEngine.CollectDisposition,
        workspacePaths: WorkspacePaths.Type,
        protectCollect: ProtectCollect,
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved?,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async {
        guard detected.runsProtect else { return }
        guard SharedConfigPin.protectAllowed(profile: profile) else {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[skip] protect: protect.profile changed in the shared "
                            + "config.yaml and is not confirmed on this Mac — "
                            + "Protect not collected"))
            return
        }
        guard disposition == .collected else {
            let reason = disposition == .stoodDown
                ? "the Jamf Pro collect stood down for another Mac"
                : "Jamf Pro already collected today"
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[skip] protect: \(reason) — Protect not collected"))
            return
        }
        // Protect augments Pro: a failure does not fail the run, but reads as Partial.
        // A blank name is not a connection (`ConnectedProducts`); a login of another product
        // would send Protect commands to the wrong API.
        let protectProfile = config?.protect?.resolvedProfile ?? ""
        let notCollected: String? = if protectProfile.isEmpty {
            "protect.profile is blank"
        } else {
            await ProfileAuthMethod.protectRefusal(profile: protectProfile, resolved: resolved)
        }
        if let notCollected {
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] Jamf Protect not collected: \(notCollected)"))
            return
        }
        guard let dataDir = try? workspacePaths.dataDir(for: profile) else {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] protect: could not resolve dataDir for \(profile) — skipping"))
            return
        }
        onLine(.init(timestamp: Date(), level: .info,
                     text: "[info] running protect collect for \(profile)"))
        do {
            try await protectCollect(protectProfile, dataDir, onLine)
        } catch {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "\(ReportEngine.protectCollectFailedMarker)\(error.localizedDescription)"))
        }
    }

    /// Why a Jamf Pro run on `profile` must not start, or nil. For entry points that name a
    /// profile themselves (a schedule, the CLI) and must refuse before they create anything in
    /// its workspace. A Jamf School workspace (`school_cli`) is not a Pro run; `run` applies the
    /// same rule. Can spawn `jamf-cli config list`.
    static func proRunRefusal(profile: String, operation: String, config: ReportConfig?) -> String? {
        guard ProfileProductType.detect(from: config, profile: profile).type == .jamfPro
        else { return nil }
        return ProfileAuthMethod.refusal(profile: profile, operation: operation)
    }

    /// Why `pro backup` has nothing to do for a Jamf School workspace; the scheduled skip, the
    /// CLI `backup` and `schedules add --mode backup` all say this.
    static func schoolBackupReason(profile: String) -> String {
        "`pro backup` is a Jamf Pro command and '\(profile)' is configured for Jamf School "
            + "(school_cli.enabled in config.yaml)"
    }

    /// Why a backup of `profile` must not run, or nil: a Jamf School workspace (decided from
    /// config.yaml, so it holds without a readable jamf-cli) or any `proRunRefusal`.
    static func backupRefusal(profile: String, config: ReportConfig?) -> String? {
        if ProfileProductType.detect(from: config, profile: profile).type == .jamfSchool {
            return schoolBackupReason(profile: profile)
        }
        return proRunRefusal(profile: profile, operation: "Backup", config: config)
    }

    /// `proRunRefusal` for a schedule, the rule `scheduledRunSingleBody` applies: a per-profile
    /// schedule that sends commands. A multi schedule and `jamf-cli-only` are never refused here.
    static func scheduleRunRefusal(_ schedule: Schedule) -> String? {
        guard !schedule.isMulti, schedule.mode != .jamfCLIOnly else { return nil }
        return proRunRefusal(
            profile: schedule.profile, operation: "Scheduled \(schedule.mode.rawValue) run",
            config: collectRoutingConfig(profile: schedule.profile))
    }

    // MARK: - Default closures (production)

    /// Default production closure wrapping `ReportEngine.collect`.
    static func defaultProCollect(now: Date, engine: @escaping ProEngine) -> ProCollect {
        { profile, workspacePaths, tiers, skipExpensive, force, onLine in
            try await engine(profile, workspacePaths, tiers, skipExpensive, force, now, onLine)
        }
    }

    static let realProEngine: ProEngine = {
        profile, workspacePaths, tiers, skipExpensive, force, now, onLine in
        try await ReportEngine.collect(
            profile: profile,
            workspacePaths: workspacePaths,
            tiers: tiers,
            skipExpensive: skipExpensive,
            force: force,
            now: now,
            onLine: onLine
        )
    }

    /// Default production closure wrapping `ReportEngine.schoolCollect`.
    static let defaultSchoolCollect: SchoolCollect = { profile, workspacePaths, tiers, force, onLine in
        try await ReportEngine.schoolCollect(
            profile: profile,
            workspacePaths: workspacePaths,
            tiers: tiers,
            force: force,
            onLine: onLine
        )
    }

    /// Default production closure wrapping `ReportEngine.protectCollect`.
    static let defaultProtectCollect: ProtectCollect = { profile, dataDir, onLine in
        try await ReportEngine.protectCollect(
            profile: profile,
            dataDir: dataDir,
            onLine: onLine
        )
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
