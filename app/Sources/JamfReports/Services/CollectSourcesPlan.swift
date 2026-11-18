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
        case securityCloud = "Jamf Security Cloud"
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
        /// A Protect-only environment (P8): nothing but the Protect list runs.
        var protectOnly = false
        /// Why `protectProfile` is not collected (a login of another product), or nil.
        var protectRefusal: String?
        /// The Jamf Security Cloud login the environment names, collected after the MDM.
        var securityCloudProfile: String?
        /// Why `securityCloudProfile` is not collected (a login of another product), or nil.
        var securityCloudRefusal: String?
        var staleDays: Int = 30
        var installedVersion: String?
        var skipExpensive = false
        /// `ProfileAuthMethod`'s answer; nil when it could not ask, which skips nothing.
        var authMethod: String?
        var tenantLevel = false
        /// The profile names a tenant, as a School profile needs for the Platform API.
        var hasTenantID = false
        /// What `jamf_cli.collect_skip` turns off on this Mac (`SharedConfigPin.collectSkipList`),
        /// as typed; the plan narrows it as the collects do.
        var collectSkipList: [String] = []
        /// config.yaml's own list while it differs from the pinned one (another Mac changed it).
        var collectSkipInFile: [String]?
        /// The kinds the collects leave out, as `collectSkipKinds` reads `collectSkipList`.
        var collectSkip: Set<String> {
            get {
                ReportEngine.collectSkipKinds(
                    collectSkipList, protectOnly: protectOnly, fleet: fleet)
            }
            set { collectSkipList = newValue.sorted() }
        }
        /// Jamf Pro's fleet sides (`FleetState.load`); unknown elsewhere.
        var fleet: FleetState = .unknown
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
    /// The list this Mac collects by, the file's while it differs, and whether the Protect
    /// computer list is core: what `switchState` reads.
    var listed: Set<String> = []
    var listedInFile: Set<String>?
    var protectOnly = false
    var fleet: FleetState = .unknown

    func sources(for product: Product) -> [Source] { sources.filter { $0.product == product } }

    static func build(_ inputs: Inputs) -> CollectSourcesPlan {
        var plan = CollectSourcesPlan(sources: sources(inputs))
        plan.listed = ReportEngine.listedSkipKinds(
            inputs.collectSkipList, protectOnly: inputs.protectOnly, fleet: inputs.fleet)
        plan.listedInFile = inputs.collectSkipInFile.map {
            ReportEngine.listedSkipKinds($0, protectOnly: inputs.protectOnly, fleet: inputs.fleet)
        }
        plan.protectOnly = inputs.protectOnly
        plan.fleet = inputs.product == .jamfPro && !inputs.protectOnly ? inputs.fleet : .unknown
        return plan
    }

    private static func sources(_ inputs: Inputs) -> [Source] {
        if inputs.protectOnly { return protect(inputs) }
        switch inputs.product {
        case .jamfSchool:
            let plan = ReportEngine.planSchoolCollect(
                profile: inputs.profile, tiers: Set(CollectionTier.allCases), force: true,
                collectSkip: inputs.collectSkip,
                platformFieldsMissing: inputs.authMethod != nil && !inputs.hasTenantID
            ) { _ in nil }
            return plan.map {
                Source(product: $0.kind == ReportEngine.schoolBlueprintsKind
                        ? .platformAPI : .school,
                       kind: $0.kind, command: command($0.args), skipReason: $0.skip.map(text))
            } + [sofa(inputs), schoolDeviceScan(inputs)] + protect(inputs) + securityCloud(inputs)
        case .jamfPro:
            return matrix(inputs) + deviceScan(inputs) + afterMatrix(inputs)
                + protect(inputs) + securityCloud(inputs)
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
                platformUnavailable: inputs.platformUnavailable,
                skippedSides: inputs.fleet.skipped),
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
        func off(_ kind: String) -> String? {
            if inputs.fleet.skipped.contains(.mac) { return text(.noDevices(.mac)) }
            return inputs.skipExpensive ? text(.settingsSkipExpensive) : skipped(kind, inputs)
        }
        return [
            Source(product: .jamfPro, kind: ReportEngine.ddmDeviceStatusKind,
                   command: "pro declarative-device-management status-items <management ID>, "
                       + "each DDM-enabled Mac",
                   skipReason: off(ReportEngine.ddmDeviceStatusKind)),
            Source(product: .jamfPro, kind: ReportEngine.mdmCommandHealthKind,
                   command: "pro classic-computer-history get <id> --subset commands, each Mac",
                   skipReason: off(ReportEngine.mdmCommandHealthKind)),
        ]
    }

    private static func skipped(_ kind: String, _ inputs: Inputs) -> String? {
        inputs.collectSkip.contains(kind) ? collectSkipText : nil
    }

    /// The skip text of a source turned off by `collect_skip`.
    static var collectSkipText: String { text(.collectSkip) }

    private static func afterMatrix(_ inputs: Inputs) -> [Source] {
        [
            Source(product: .jamfPro, kind: ReportEngine.patchReleaseDatesKind,
                   command: "pro patch-software-title-configurations definitions <id>, each title",
                   skipReason: inputs.fleet.skipped.contains(.mac) ? text(.noDevices(.mac))
                       : inputs.collectSkip.contains(ReportEngine.patchReleaseDatesKind)
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

    /// Runs after the collect, from the device list it landed, at most once a week.
    private static func schoolDeviceScan(_ inputs: Inputs) -> Source {
        Source(product: .school, kind: ReportEngine.schoolDeviceDetailKind,
               command: "school devices get <udid>, each device, once a week",
               skipReason: inputs.collectSkip.contains(ReportEngine.schoolDeviceDetailKind)
                   ? text(.collectSkip) : nil)
    }

    private static func protect(_ inputs: Inputs) -> [Source] {
        guard let profile = inputs.protectProfile else { return [] }
        return ReportEngine.protectCommandMatrix(profile: profile).map {
            Source(product: .protect, kind: $0.kind, command: command($0.args),
                   skipReason: inputs.protectRefusal ?? skipped($0.kind, inputs))
        }
    }

    private static func securityCloud(_ inputs: Inputs) -> [Source] {
        guard let profile = inputs.securityCloudProfile else { return [] }
        return ReportEngine.securityCommandMatrix(profile: profile).map {
            Source(product: .securityCloud, kind: $0.kind, command: command($0.args),
                   skipReason: inputs.securityCloudRefusal
                       ?? (inputs.collectSkip.contains($0.kind) ? text(.collectSkip) : nil))
        }
    }

    // MARK: - Data Sources switches

    /// What a source row's switch shows.
    enum SourceSwitch: Equatable, Sendable {
        /// Skipped for another reason (Settings, the profile's API or scope, jamf-cli): no switch.
        case hidden
        /// A core source: on, and cannot be turned off.
        case locked
        case on
        case off
        /// Off because `patch-status` is: no switch of its own.
        case followsPatchStatus
        /// Not collected: the fleet has none of this side's devices. No switch.
        case noDevices(FleetSide)
    }

    struct SwitchState: Equatable, Sendable {
        let control: SourceSwitch
        /// config.yaml turns this source on or off differently from what this Mac confirmed.
        let changedOnAnotherMac: Bool
    }

    /// The row's switch, from the same lists the collects read.
    func switchState(for source: Source) -> SwitchState {
        let changed = listedInFile.map { $0.contains(source.kind) != listed.contains(source.kind) }
            ?? false
        let control: SourceSwitch
        if let side = ReportEngine.skippedSide(of: source.kind, skipped: fleet.skipped) {
            control = .noDevices(side)
        } else if ReportEngine.isCoreKind(source.kind, protectOnly: protectOnly, fleet: fleet) {
            control = .locked
        } else if let reason = source.skipReason, reason != Self.collectSkipText {
            control = .hidden
        } else if listed.contains(source.kind) {
            control = .off
        } else if source.skipReason != nil {
            control = .followsPatchStatus
        } else {
            control = .on
        }
        return SwitchState(control: control, changedOnAnotherMac: changed)
    }

    /// A peer's edit is pending: every switch waits for Confirm in Config Doctor.
    var changedOnAnotherMac: Bool { listedInFile != nil }

    /// A skip in the words of the run log's `[skip]` line, else its `[plan]` label.
    private static func text(_ reason: ReportEngine.CollectSkipReason) -> String {
        reason.skipDetail ?? reason.planLabel
    }

    /// `args` as a person would type them: no `-p <profile>`, `--no-input` or `--output json`.
    static func command(_ args: [String]) -> String {
        var words: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            if word == "-p" || word == "--output" {
                index += 2
                continue
            }
            if word == "--no-input" {
                index += 1
                continue
            }
            words.append(word)
            index += 1
        }
        return words.joined(separator: " ")
    }
}
