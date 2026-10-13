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
        var staleDays: Int = 30
        var installedVersion: String?
        var skipExpensive = false
        /// `ProfileAuthMethod`'s answer; nil when it could not ask, which skips nothing.
        var authMethod: String?
        var tenantLevel = false
        var collectSkip: Set<String> = []
    }

    let sources: [Source]

    func sources(for product: Product) -> [Source] { sources.filter { $0.product == product } }

    static func build(_ inputs: Inputs) -> CollectSourcesPlan {
        switch inputs.product {
        case .jamfSchool:
            return CollectSourcesPlan(sources: ReportEngine.schoolCommandMatrix(
                profile: inputs.profile
            ).map { Source(product: .school, kind: $0.kind, command: command($0.args),
                           skipReason: nil) })
        case .jamfPro:
            return CollectSourcesPlan(
                sources: matrix(inputs) + deviceScan(inputs) + afterMatrix(inputs)
                    + protect(inputs))
        }
    }

    private static func matrix(_ inputs: Inputs) -> [Source] {
        let commands = ReportEngine.collectCommandMatrix(
            profile: inputs.profile,
            specNames: JamfCLIInstaller.supportsSpecDerivedNames(inputs.installedVersion),
            staleDays: inputs.staleDays)
        let plan = ReportEngine.planCollect(
            commands: commands,
            inputs: ReportEngine.CollectPlanInputs(
                tiers: Set(CollectionTier.allCases), force: true,
                skipExpensive: inputs.skipExpensive,
                nonPlatformAuth: ReportEngine.nonPlatformAuthMethod(inputs.authMethod),
                tenantLevel: inputs.tenantLevel, collectSkip: inputs.collectSkip,
                dashboardSupported: JamfCLIInstaller.supportsDashboard(inputs.installedVersion),
                installedVersion: inputs.installedVersion, now: Date()),
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
        let resource = JamfCLIInstaller.supportsSpecDerivedNames(inputs.installedVersion)
            ? "declarative-device-management" : "ddm-status"
        return [
            Source(product: .jamfPro, kind: ReportEngine.ddmDeviceStatusKind,
                   command: "pro \(resource) status-items <management ID>, each DDM-enabled Mac",
                   skipReason: off),
            Source(product: .jamfPro, kind: ReportEngine.mdmCommandHealthKind,
                   command: "pro classic-computer-history get <id> --subset commands, each Mac",
                   skipReason: off),
        ]
    }

    private static func afterMatrix(_ inputs: Inputs) -> [Source] {
        let reason = text(.collectSkip)
        func skip(_ kind: String) -> String? { inputs.collectSkip.contains(kind) ? reason : nil }
        return [
            Source(product: .jamfPro, kind: ReportEngine.patchReleaseDatesKind,
                   command: "pro patch-software-title-configurations definitions <id>, each title",
                   skipReason: skip(ReportEngine.patchReleaseDatesKind)),
            Source(product: .other, kind: ReportEngine.sofaKind,
                   command: "SOFA macOS and iOS feeds (sofafeed.macadmins.io)",
                   skipReason: skip(ReportEngine.sofaKind)),
        ]
    }

    private static func protect(_ inputs: Inputs) -> [Source] {
        guard let profile = inputs.protectProfile else { return [] }
        return ReportEngine.protectCommandMatrix(profile: profile).map {
            Source(product: .protect, kind: $0.kind, command: command($0.args), skipReason: nil)
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
