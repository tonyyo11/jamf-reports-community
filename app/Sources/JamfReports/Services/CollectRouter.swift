import Foundation

// MARK: - ProfileProductType

/// The product type a jamf-cli profile serves, derived from config.yaml.
///
/// Routing rules:
/// - `school_cli.enabled == true` → `.jamfSchool` (school collect only, never pro).
/// - Otherwise → `.jamfPro`, and `protect?.enabled == true` means Protect augments the Pro run.
///
/// Protect is an ADD-ON to a Jamf Pro profile, not a standalone product type.
/// A School profile cannot also run Protect (school setup uses API-key auth, not OAuth2).
enum ProfileProductType: Equatable, Sendable {
    case jamfPro
    case jamfSchool
}

// MARK: - DetectedProduct

/// Result of `ProfileProductType.detect(from:)`.
struct DetectedProduct: Sendable {
    let type: ProfileProductType
    /// True when a Jamf Pro profile also has `protect.enabled == true`.
    /// Always false for School profiles.
    let runsProtect: Bool
}

extension ProfileProductType {

    /// Detect the product type from a decoded `ReportConfig`.
    ///
    /// - Parameter config: The loaded config for the profile. When nil (load failure),
    ///   defaults to `.jamfPro` with `runsProtect: false` — same behaviour as before
    ///   the router existed, and loud: callers log the nil case before calling this.
    static func detect(from config: ReportConfig?) -> DetectedProduct {
        guard let config else {
            return DetectedProduct(type: .jamfPro, runsProtect: false)
        }
        if config.schoolCli?.isEnabled == true {
            return DetectedProduct(type: .jamfSchool, runsProtect: false)
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
/// School collect does not emit a `summary.json` trend snapshot today. That is a
/// noted gap, not a regression: School profiles had no collect at all before this
/// router was introduced.
enum CollectRouter {

    /// Type of the pro-collect closure, matching `ReportEngine.collect`'s signature.
    typealias ProCollect = @Sendable (
        _ profile: String,
        _ workspacePaths: WorkspacePaths.Type,
        _ tiers: Set<CollectionTier>,
        _ skipExpensive: Bool,
        _ force: Bool,
        _ onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> Void

    /// Type of the school-collect closure, matching `ReportEngine.schoolCollect`'s signature.
    typealias SchoolCollect = @Sendable (
        _ profile: String,
        _ workspacePaths: WorkspacePaths.Type,
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
    ///   - tiers: Collection tiers for the Pro path (ignored for School).
    ///   - skipExpensive: Skip expensive per-device Pro commands (ignored for School).
    ///   - force: Bypass the once-per-day guard on the Pro path (ignored for School).
    ///   - config: Loaded config for the profile; pass nil when load failed. A nil config
    ///     degrades to Jamf Pro (same behaviour as before this router existed).
    ///   - workspacePaths: Path resolver (injectable for tests).
    ///   - proCollect: Closure wrapping `ReportEngine.collect`. Defaults to the real static.
    ///   - schoolCollect: Closure wrapping `ReportEngine.schoolCollect`. Defaults to the real static.
    ///   - protectCollect: Closure wrapping `ReportEngine.protectCollect`. Defaults to the real static.
    ///   - onLine: Progress log callback.
    static func run(
        profile: String,
        tiers: Set<CollectionTier> = Set(CollectionTier.allCases),
        skipExpensive: Bool = false,
        force: Bool = false,
        config: ReportConfig?,
        workspacePaths: WorkspacePaths.Type = WorkspacePaths.self,
        proCollect: ProCollect = defaultProCollect,
        schoolCollect: SchoolCollect = defaultSchoolCollect,
        protectCollect: ProtectCollect = defaultProtectCollect,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws {
        let detected = ProfileProductType.detect(from: config)
        switch detected.type {
        case .jamfSchool:
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] routing \(profile) → Jamf School collect"))
            try await schoolCollect(profile, workspacePaths, onLine)

        case .jamfPro:
            try await proCollect(profile, workspacePaths, tiers, skipExpensive, force, onLine)
            guard detected.runsProtect else { return }
            // Protect augments Pro; failure is non-fatal — Pro run already succeeded.
            let protectProfile = config?.protect?.resolvedProfile ?? profile
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
                    text: "[warn] protect collect failed (non-fatal): \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Default closures (production)

    /// Default production closure wrapping `ReportEngine.collect`.
    static let defaultProCollect: ProCollect = { profile, workspacePaths, tiers, skipExpensive, force, onLine in
        try await ReportEngine.collect(
            profile: profile,
            workspacePaths: workspacePaths,
            tiers: tiers,
            skipExpensive: skipExpensive,
            force: force,
            onLine: onLine
        )
    }

    /// Default production closure wrapping `ReportEngine.schoolCollect`.
    static let defaultSchoolCollect: SchoolCollect = { profile, workspacePaths, onLine in
        try await ReportEngine.schoolCollect(
            profile: profile,
            workspacePaths: workspacePaths,
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
