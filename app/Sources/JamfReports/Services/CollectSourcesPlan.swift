import Foundation

/// What a full collect runs for one workspace, for the Data Sources screen. It is built from
/// the lists the collects run (the command matrix through `ReportEngine.planCollect`, the device
/// scan, the sources fetched after the matrix, and the School and Protect lists), so the screen
/// cannot name a command a collect does not run, or miss one it does. Every tier is counted
/// and cadence is not: the question is what this workspace collects, not what the next run is
/// due to fetch.
struct CollectSourcesPlan: Equatable, Sendable {
    enum Product: String, CaseIterable, Sendable {
        case jamfPro = "Jamf Pro"
        case platformAPI = "Platform API"
        case protect = "Jamf Protect"
        case school = "Jamf School"
        case other = "Other sources"
    }

    struct Source: Equatable, Sendable, Identifiable {
        let product: Product
        let kind: String
        /// The jamf-cli command as typed, without the profile and output flags.
        let command: String
        /// Why a collect leaves it out (Settings, the profile's API or scope, collect_skip,
        /// the jamf-cli version); nil when it runs.
        let skipReason: String?
        var id: String { kind }
    }

    /// What the collects read about the workspace, all known without running jamf-cli.
    struct Inputs: Sendable {
        var product: ProfileProductType
        var profile: String
        var protectProfile: String?
        /// Why `protectProfile` is not collected (a login of another product), or nil.
        var protectRefusal: String?
        var staleDays: Int = 30
        var installedVersion: String?
        var skipExpensive = false
        /// `ProfileAuthMethod`'s answer; nil when it could not ask, which skips nothing.
        var authMethod: String?
        var tenantLevel = false
        /// The profile names a tenant, as a School profile needs for the Platform API.
        var hasTenantID = false
        var collectSkip: Set<String> = []
        /// Why the Platform-only kinds do not run (no Platform profile), or nil.
        var platformUnavailable: String?
    }

    /// The auth method and Platform skip reason Data Sources judges by. Only Jamf Pro has a
    /// `platform` slot; a School workspace keeps its own login's auth method.
    static func routedAuth(
        product: ProfileProductType, route: PlatformRoute, workspace: String,
        workspaceAuth: ProfileAuthMethod.Resolved?,
        resolve: (String) -> ProfileAuthMethod.Resolved?
    ) -> (auth: ProfileAuthMethod.Resolved?, unavailable: String?) {
        guard product == .jamfPro else { return (workspaceAuth, nil) }
        return EnvironmentProfiles.platformInputs(
            route: route, workspace: workspace, workspaceAuth: workspaceAuth, resolve: resolve)
    }

    let sources: [Source]

    func sources(for product: Product) -> [Source] { sources.filter { $0.product == product } }

    static func build(_ inputs: Inputs) -> CollectSourcesPlan {
        switch inputs.product {
        case .jamfSchool:
            let plan = ReportEngine.planSchoolCollect(
                profile: inputs.profile, tiers: Set(CollectionTier.allCases), force: true,
                platformFieldsMissing: inputs.authMethod != nil && !inputs.hasTenantID
            ) { _ in nil }
            return CollectSourcesPlan(sources: plan.map {
                Source(product: $0.kind == ReportEngine.schoolBlueprintsKind
                        ? .platformAPI : .school,
                       kind: $0.kind, command: command($0.args), skipReason: $0.skip.map(text))
            } + [sofa(inputs)] + protect(inputs))
        case .jamfPro:
            return CollectSourcesPlan(
                sources: matrix(inputs) + deviceScan(inputs) + afterMatrix(inputs)
                    + protect(inputs))
        }
    }

    private static func matrix(_ inputs: Inputs) -> [Source] {
        let commands = ReportEngine.collectCommandMatrix(
            profile: inputs.profile, staleDays: inputs.staleDays)
        let plan = ReportEngine.planCollect(
            commands: commands,
            inputs: ReportEngine.CollectPlanInputs(
                tiers: Set(CollectionTier.allCases), force: true,
                skipExpensive: inputs.skipExpensive,
                nonPlatformAuth: ReportEngine.nonPlatformAuthMethod(inputs.authMethod),
                tenantLevel: inputs.tenantLevel, collectSkip: inputs.collectSkip,
                dashboardSupported: JamfCLIInstaller.supportsDashboard(inputs.installedVersion),
                installedVersion: inputs.installedVersion, now: Date(),
                platformUnavailable: inputs.platformUnavailable),
            lastRun: { _ in nil })
        return plan.map { planned in
            Source(
                product: ReportEngine.platformOnlyKinds.contains(planned.kind)
                    ? .platformAPI : .jamfPro,
                kind: planned.kind, command: command(planned.args),
                skipReason: planned.skip.map(text))
        }
    }

    private static func deviceScan(_ inputs: Inputs) -> [Source] {
        let off = inputs.skipExpensive
            ? text(.settingsSkipExpensive) : nil
        return [
            Source(product: .jamfPro, kind: ReportEngine.ddmDeviceStatusKind,
                   command: "pro declarative-device-management status-items <management ID>, "
                       + "each DDM-enabled Mac",
                   skipReason: off),
            Source(product: .jamfPro, kind: ReportEngine.mdmCommandHealthKind,
                   command: "pro classic-computer-history get <id> --subset commands, each Mac",
                   skipReason: off),
        ]
    }

    private static func afterMatrix(_ inputs: Inputs) -> [Source] {
        [
            Source(product: .jamfPro, kind: ReportEngine.patchReleaseDatesKind,
                   command: "pro patch-software-title-configurations definitions <id>, each title",
                   skipReason: inputs.collectSkip.contains(ReportEngine.patchReleaseDatesKind)
                       ? text(.collectSkip) : nil),
            sofa(inputs),
        ]
    }

    /// The one fetch from a third-party host; a Jamf School collect makes it too, for OS
    /// currency in its daily summary.
    private static func sofa(_ inputs: Inputs) -> Source {
        Source(product: .other, kind: ReportEngine.sofaKind,
               command: "SOFA macOS and iOS feeds (sofafeed.macadmins.io)",
               skipReason: inputs.collectSkip.contains(ReportEngine.sofaKind)
                   ? text(.collectSkip) : nil)
    }

    private static func protect(_ inputs: Inputs) -> [Source] {
        guard let profile = inputs.protectProfile else { return [] }
        return ReportEngine.protectCommandMatrix(profile: profile).map {
            Source(product: .protect, kind: $0.kind, command: command($0.args),
                   skipReason: inputs.protectRefusal)
        }
    }

    /// A skip in the words of the run log's `[skip]` line, else its `[plan]` label.
    private static func text(_ reason: ReportEngine.CollectSkipReason) -> String {
        reason.skipDetail ?? reason.planLabel
    }

    /// `args` as a person would type them: no `-p <profile>` and no `--output json`.
    static func command(_ args: [String]) -> String {
        var words: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            if word == "-p" || word == "--output" {
                index += 2
                continue
            }
            words.append(word)
            index += 1
        }
        return words.joined(separator: " ")
    }
}
