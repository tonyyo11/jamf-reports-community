import ArgumentParser
import Foundation

/// `jamf-reports schedules` — list, add, remove, or run hand-built schedules
/// stored in `ScheduleStore`. Managed schedules (from Automation) are not
/// stored records and are not editable here.
struct Schedules: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, add, remove, or run hand-built schedules "
            + "(managed ones come from Automation).",
        subcommands: [List.self, Add.self, Remove.self, Run.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List stored schedules.")
        func run() async throws {
            let records = ScheduleStore().load()
            if records.isEmpty { print("no hand-built schedules"); return }
            for r in records {
                let target = r.allWorkspaces ? "all-profiles" : r.workspace
                let flag = r.enabled ? "" : " (disabled)"
                print("\(r.label)\t\(target)\t\(Self.effectiveMode(of: r))\t\(r.schedule)\(flag)")
            }
        }

        /// The mode a run uses: a pre-2.11 csv-assisted record runs as jamf-cli-full. An
        /// unknown future mode prints as stored.
        static func effectiveMode(of record: ScheduleRecord) -> String {
            guard let mode = Schedule.RunMode(stored: record.mode) else { return record.mode }
            return record.mode == Schedule.RunMode.retiredCSVAssistedRaw
                ? "\(mode.rawValue) (was \(record.mode))" : mode.rawValue
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add or replace a schedule.")
        @Option(help: "Display name; the label slug derives from it.") var name: String
        @Option(help: "Workspace profile slug (the base profile when --all-profiles).")
        var profile: String
        @Flag(help: "Run for every local profile.") var allProfiles = false
        @Option(help: "Comma-separated profiles to skip (--all-profiles); %2C is ',', %25 is '%'.")
        var exclude: String?
        @Option(help: "snapshot-only | jamf-cli-only | jamf-cli-full | backup")
        var mode: String
        @Option(help: "Cadence: 'Daily 06:20', 'Mon 07:00', 'Weekdays 09:00', 'Day 15 06:20'.")
        var cadence: String
        @Option(help: "Comma-separated collect tiers (refresh,inventory,scan).") var tiers: String?
        @Flag(help: "Store disabled.") var disabled = false

        struct Invalid: Error, CustomStringConvertible { let description: String }

        static func record(
            name: String, profile: String, allProfiles: Bool, exclude: String?,
            mode: String, cadence: String, tiers: String?, disabled: Bool
        ) throws -> ScheduleRecord {
            // Before the product pre-check below reads config.yaml: a case variant's would be
            // another spelling's.
            if let refusal = CLIRun.profileRefusal(profile) {
                throw Invalid(description: refusal)
            }
            guard mode != Schedule.RunMode.retiredCSVAssistedRaw else {
                throw Invalid(description: "csv-assisted mode was retired in 2.11; use jamf-cli-full")
            }
            guard let runMode = Schedule.RunMode(rawValue: mode) else {
                throw Invalid(description: "unknown mode '\(mode)'")
            }
            _ = try LaunchAgentWriter.calendarIntervals(for: cadence)
            // A schedule for a base profile of another product would only ever be skipped.
            if !allProfiles, runMode != .jamfCLIOnly {
                let config = collectRoutingConfig(profile: profile)
                // A School workspace collects and generates, but has nothing for `pro backup`.
                let refusal = runMode == .backup
                    ? CollectRouter.backupRefusal(profile: profile, config: config)
                    : CollectRouter.proRunRefusal(
                        profile: profile, operation: "A \(runMode.rawValue) schedule",
                        config: config)
                if let refusal { throw Invalid(description: refusal) }
            }
            let tierSet: Set<CollectionTier>? = tiers.map(CLIRun.parseTiers)
            let excluded = exclude?.split(separator: ",")
                .map(ProfileName.name(fromListElement:)).filter { !$0.isEmpty }
            let schedule = Schedule(
                name: name, profile: profile, schedule: cadence, cadence: "custom", mode: runMode,
                next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: !disabled,
                multiTarget: allProfiles ? MultiTarget(scope: .all, sequential: true) : nil,
                tiers: tierSet, excludedProfiles: allProfiles ? excluded : nil)
            guard let record = ScheduleRecord(schedule: schedule) else {
                throw Invalid(description: "'\(name)' does not make a valid, non-managed label")
            }
            return record
        }

        func run() async throws {
            let record: ScheduleRecord
            do {
                record = try Self.record(
                    name: name, profile: profile, allProfiles: allProfiles, exclude: exclude,
                    mode: mode, cadence: cadence, tiers: tiers, disabled: disabled)
            } catch { CLIRun.fail("\(error)") }
            try ScheduleStore().upsert(record)
            // The launch-time bootstrap ran before this record existed, so on
            // a zero-schedule host the ticker isn't registered yet; this call
            // is idempotent and picks it up now instead of the next launch.
            WorkspaceStore.bootstrapTickerHeadless()
            print("saved \(record.label)")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a schedule by label.")
        @Argument(help: "Full label as printed by `schedules list`.") var label: String
        func run() async throws {
            guard ScheduleStore().load().contains(where: { $0.label == label }) else {
                CLIRun.fail("no schedule with label '\(label)'")
            }
            try ScheduleStore().remove(label: label)
            print("removed \(label)")
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a schedule now and wait.")
        @Argument(help: "Full label (hand-built or managed).") var label: String
        func run() async throws {
            // Reject an unknown label here rather than spawning a tick that
            // would silently find nothing due and exit 0 — a typo must read as
            // a typo, not as a successful run.
            let profiles = ProfileService.discoverLocal()
            let baseProfile = ManagedAutomation.managedBaseProfile(
                profiles: profiles, policy: AutomationPolicy.current())
            let known = WorkspaceStore.loadSchedules(baseProfile: baseProfile)
                .compactMap(\.launchAgentLabel)
            guard known.contains(label) else {
                CLIRun.fail("no schedule with label '\(label)'")
            }
            let code = await TickRunner.spawnNow(
                label: label, wait: true, onLine: CLIRun.printLogLine)
            if code == TickRunner.queuedExitCode {
                print("queued — another run is in progress; it runs on the next wake")
                return
            }
            if code != 0 { CLIRun.fail("schedule exited \(code)", code: code) }
        }
    }
}
