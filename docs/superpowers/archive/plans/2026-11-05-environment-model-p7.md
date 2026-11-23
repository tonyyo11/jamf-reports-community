# Environment model P7: merging two workspaces into one environment — implementation plan

Status: shipped in 2.12 on `dev/2-12-0`. The boxes below are the original task list and were not ticked as the work landed; `CLAUDE.md` describes what was built.

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a user with two workspaces for one Jamf Pro (an OAuth one and a Platform API one, the 2.10 twin shape) can merge the Platform workspace into the OAuth one from Data Sources, with no data loss. The Platform profile becomes the target's `profiles.platform` slot. The source folder is moved aside, never deleted.

**Architecture:**
- **`WorkspaceMergePlan.make`** lists both workspaces once and decides, file by file, what to copy, skip, archive or fill, by spec §11's table. It returns a Codable plan: file steps, then a fixed tail (config, schedules, policy, pins, move).
- **`WorkspaceMergeExecutor.run`** applies a plan under the tick lock (`HoldPurpose.merge`). It refuses while a peer holds the shared claim on either workspace. It writes a journal (the whole plan plus the count of steps done) to the target after every step, and resumes from it after a crash. Every step can run twice safely.
- **`WorkspaceMergeSheet`**, from the Environment card on Data Sources, picks the source, confirms both workspaces reach the same Jamf Pro, shows the plan's counts, runs it, and offers Resume when a journal is pending.

**Tech stack:** Swift 6, SwiftUI, XCTest. Build with `swift build --build-tests` and test with `swift test`, both from `app/`.

**Spec:** `docs/superpowers/specs/2026-10-19-environment-model-design.md`, §11, D5, D6, D21 and the P7 row of §13. The spec is on branch `docs/env-model-z1-z3` (#379), and this branch carries it. P7 stacks on P6 (`feat/env-model-p6`, #385).

## Global constraints

- **No data loss (spec §11).** Nothing the user can see is deleted. A file the merge replaces or takes out of the target goes to the archive first. The source folder is moved to the merged folder, never deleted. The only file removed outright is the source's per-Mac pin file in Application Support (app state).
- **Target and source (D5).** The target is a Jamf Pro workspace whose own profile is not a Platform API profile. The source is a Jamf Pro workspace whose own profile is a Platform API profile. The source's profile goes into the target's `platform` slot through `ProfilesConfigWriter.save(.platform, to:workspace:)`, the one slot writer (it confirms the pin by token).
- **Snapshots are never renamed.** A suffix breaks `CloudStorage.snapshotTimestamp`'s canonical-name whitelist, which filters sync-conflict copies.
- **The lock and the claim.** The executor runs inside `CLIBridge.holdingTickLock(purpose: .merge)`. It refuses, before writing anything, when `SharedWorkspace.decide(existing: readClaim(profile:), me:now:)` is `.blocked` for the source or the target.
- **Paths.** Every folder comes from `WorkspacePaths` (`dataDir`, `stateDir`, `summariesDir`, `historicalDir`, `runHistoryDir`, `readableReportsDir`, `archiveDir`) and `ProfileService.workspaceURL(for:)`. Never build a workspace path by string interpolation. Listings refuse a folder that is a link (`FileManager.snapshotFolderEntries`, `WorkspacePaths.confinedFolder`).
- **Writes.** Files are written through `AtomicInstall` (or `FileManager.copyItem` into a staged name then `AtomicInstall.install`). A copy never writes through a link at the destination.
- Demo mode writes nothing and offers no merge. Controls are disabled with `DemoData.liveOnlyHelp`.
- User-visible GUI text goes through `L()` in whole sentences and is translated into all six catalog languages using `app/Localization/glossary.md`. Then run `app/scripts/sync-strings.zsh --prune-stale`. `LocalizationCatalogTests` must pass. Log lines stay English.
- Any SwiftUI layout change needs visual verification at `PageScaffold.minSupportedWidth`. If you can't verify it, write `DRAFT — needs visual verification` in the commit body.
- Lines are at most 100 characters. No force unwraps. Functions at most 100 lines. Comments explain why. Match the surrounding style. Tests never run jamf-cli and never touch the real tick lock, schedule store or Application Support: inject every effect, and use the `JRC_TEST_WORKSPACES_ROOT` root and `AppSupport`'s test directory the nearby tests use.
- Commit subjects are imperative, at most 72 characters, with no attribution lines. CHANGELOG `Unreleased` gets plain-language bullets tagged (#305). CLAUDE.md and AGENTS.md stay byte-identical.

## Rulings

- **R1:** the only entry point is Data Sources › Environment › "Merge another workspace into this one". Spec §5 step 7's adoption offer cannot arise: adoption runs only when no workspace exists (P5, P6). Config Doctor's `platform.twin` row points to the merge.
- **R2:** only the twin shape merges (Global constraints). A School, Protect-only or second OAuth workspace is never offered as a source. Cost if wrong: a later phase widens `WorkspaceMergeCandidates`.
- **R3:** the merge needs `PlatformHostCheck.verdict` to be `.same`. `.unknown` refuses, unlike the slot write, which fails open: a merge copies one fleet's history into another's folder, and a wrong merge can't be undone cleanly. The refusal says the slot can still be added from the Add sheet. Cost if wrong: a server that won't answer `jss-url:read` can't merge until it does.
- **R4:** a target whose `platform` slot names another profile is refused ("remove it first"). A slot that already names the source is fine.
- **R5:** the source's other `profiles` slots and settings are not carried over. The sheet lists the top-level config keys whose values differ, as spec §11 says.
- **R6:** from `automation/`, only `logs/` and `*_status.json` are copied. Coordination files (`.workspace-claim.json`, `hosts/`, day markers, the alert ledger, the journal) stay with the source folder.
- **R7:** one collision rule for every copy area: the target lacks the name, so copy; same name and same SHA-256, so skip; same name with different bytes, so keep the target's and copy the source's into the archive. Summaries and state have their own rules (spec §11).
- **R8:** state per kind: the side with the newer `<kind>.last` wins, and every `<kind>.*` file comes from that side. A target file of that kind that the winning source lacks is moved into the archive, so failure counters come from one side. A state file that belongs to no kind (no `.last` on either side) follows R7.
- **R9:** the merged folder is `<root>/_merged/<source>-<yyyyMMdd-HHmmss>/`. It holds `workspace/` (the moved source folder) and `archive/<area>/…`. This differs from spec §11's layout (the source folder *is* the merged folder) only so the archive can exist before the move. Discovery ignores `_merged`: it holds no top-level `config.yaml`, and a leading `_` is no canonical `ProfileName` encoding.
- **R10:** an area the source reads from outside its folder (an absolute `jamf_cli.data_dir`, `output.output_dir` or `charts.historical_csv_dir`) is copied from, but not moved. The plan records each such folder in `outsideSourceFolder`, and the sheet names it.
- **R11:** the journal holds the whole plan. Resume never recomputes the plan. When the merge finishes, the journal moves into the merged folder as `merge-journal.json`, the record of what was done.
- **R12:** no CLI subcommand and no headless entry point.
- **R13:** the archive copies use the area and the file's path relative to the area's root, so two areas never collide.
- **R14 (final review):** corrects spec §11's "Report groups, `excludedProfiles`" row for exclusions. 2.11's shipped `platform.twin` hint told users to exclude the OAuth workspace (the merge target), and P4's hint the Platform one (the source), so mapping the source's exclusion onto the target would stop or keep automation wrongly. After a merge the target is excluded only if both were excluded before. Report groups and schedule `workspace` keep the replace-and-dedupe rule.

---

### Task 1: `WorkspaceMergePlan`

**Files:**
- Create: `app/Sources/JamfReports/Services/WorkspaceMergePlan.swift`
- Test: `app/Tests/JamfReportsTests/WorkspaceMergePlanTests.swift`

**Interfaces produced:**

```swift
struct WorkspaceMergePlan: Codable, Equatable, Sendable {
    enum Area: String, Codable, CaseIterable, Sendable {
        case snapshots, state, summaries, chartHistory, sofa, runHistory, backups, reports, config
    }

    /// The fixed steps after the files, in this order.
    enum Tail: String, Codable, CaseIterable, Sendable {
        case archiveSourceConfig, writePlatformSlot, copyBenchmarks
        case retargetSchedules, rewritePolicy, removeSourcePin, moveSource
    }

    enum Action: Codable, Equatable, Sendable {
        /// The target lacks the name.
        case copy
        /// Same name, same SHA-256. Listed so the sheet can count it; the executor does nothing.
        case skipIdentical
        /// Same name, different bytes: the target keeps its file, the source's goes to `archive`.
        case archiveSource
        /// Both have the day: `target.filling(from: source)` is written to `target`, after both
        /// originals are copied into the archive (`archive` for the target's, `sourceArchive`).
        case fillSummary(sourceArchive: String)
        /// State: the source side is newer. The target's file (if any) goes to `archive`, then
        /// the source's file replaces it.
        case replaceState
        /// State: the source side is newer and lacks this target file. It moves to `archive`.
        case archiveTarget
        /// A backup folder the target lacks, copied whole with its `.jrc-host` stamp.
        case copyFolder
        case tail(Tail)
    }

    struct Step: Codable, Equatable, Sendable {
        var area: Area
        var action: Action
        /// Absolute paths. Empty for a tail step that needs none.
        var source: String
        var target: String
        var archive: String?
    }

    /// Workspace IDs.
    var source: String
    var target: String
    /// `yyyyMMdd-HHmmss`, local time.
    var stamp: String
    /// `<root>/_merged/<source path component>-<stamp>` (R9).
    var mergedFolder: String
    var steps: [Step]
    /// Top-level config keys whose values differ between the two config.yaml files (R5).
    var differingConfigKeys: [String]
    /// Source folders read from outside the source workspace (R10).
    var outsideSourceFolder: [String]

    /// How many steps of each action each area has, for the sheet. Tail steps are left out.
    func counts() -> [Area: [String: Int]]

    enum PlanError: Error, LocalizedError, Equatable {
        case noWorkspace(String)
        case sameWorkspace
        case unreadable(area: String, reason: String)
    }

    /// Lists both workspaces and decides each file. Hashes only names both sides hold.
    static func make(
        source: String, target: String, now: Date = Date(),
        root: URL = ProfileService.workspacesRoot()
    ) throws -> WorkspaceMergePlan
}
```

The key for `counts()` is the action's case name without its payload (`copy`, `skipIdentical`, `archiveSource`, `fillSummary`, `replaceState`, `archiveTarget`, `copyFolder`).

**Area rules (spec §11 and the rulings):**

| Area | Source root | Target root | Rule |
|---|---|---|---|
| snapshots | each kind folder under `dataDir(for: source)` except `state`, `sofa` and any `_`-prefixed folder | the same kind under `dataDir(for: target)` | R7, files only, one level |
| state | `stateDir` | `stateDir` | R8 |
| summaries | `summariesDir` | `summariesDir` | a canonical `summary_yyyy-MM-dd.json` only the source has: `copy`; both have it: `fillSummary`; any other file: R7 |
| chartHistory | `historicalDir` minus `summaries` | `historicalDir` | R7, recursive |
| sofa | `dataDir/sofa` | `dataDir/sofa` | R7 |
| runHistory | `runHistoryDir` and `automation/*_status.json` | same | R7 (R6) |
| backups | `<workspace>/backups/<folder>` | `<workspace>/backups/` | folder name absent: `copyFolder`; present: nothing listed (names are unique) |
| reports | `readableReportsDir` and its `archive` | same | R7 |
| config | — | — | no file steps; tail only |

Archive paths: `<mergedFolder>/archive/<area>/<path relative to the area root>`, and for `fillSummary` the source's original goes to `<mergedFolder>/archive/summaries/source/<name>` and the target's to `<mergedFolder>/archive/summaries/target/<name>`.

`differingConfigKeys`: read both files with `ConfigLoader.rawMapping`, compare each top-level key's value, and list keys that differ or that one file lacks, sorted. Leave out `profiles` and `jamf_cli`, which always differ.

**Tests (fixture workspaces under a temp root):**
- [ ] A snapshot only the source has is `copy`. Same name and same bytes is `skipIdentical`. Same name, different bytes is `archiveSource`, with the archive path under `archive/snapshots/<kind>/`.
- [ ] A summary day only the source has is `copy`. A day both have is `fillSummary`, with both archive paths.
- [ ] State: source `.last` newer gives `replaceState` for each of that kind's source files and `archiveTarget` for a target `.fail` the source lacks. Target newer gives no steps for that kind.
- [ ] Run History copies logs and `*_status.json`, and never `.workspace-claim.json` or `hosts/`.
- [ ] A backup folder name the target lacks is `copyFolder`.
- [ ] The tail is the seven `Tail` cases, in order, after every file step.
- [ ] `differingConfigKeys` lists a key whose value differs and leaves out `profiles` and `jamf_cli`.
- [ ] An absolute `jamf_cli.data_dir` outside the source folder is listed in `outsideSourceFolder`.
- [ ] A kind folder that is a link is refused with `unreadable`.
- [ ] `make` with `source == target` throws `sameWorkspace`. A missing workspace throws `noWorkspace`.
- [ ] The plan round-trips through `JSONEncoder` and `JSONDecoder` unchanged.

- [ ] Commit: `Plan a merge of two workspaces file by file (P7)`

### Task 2: `WorkspaceMergeExecutor`, the journal and the lock

**Files:**
- Create: `app/Sources/JamfReports/Services/WorkspaceMergeExecutor.swift`
- Modify: `app/Sources/JamfReports/Services/CLIBridge+TickLock.swift` (`HoldPurpose.merge`, label `L("Workspace merge")`, `runningHoldRefusal`)
- Modify: `app/Sources/JamfReports/Services/CLIBridge+Generation.swift` (`CLIBridgeError.mergeInProgress`, its message "A workspace merge is running — try again when it finishes", and `isCollectRefusal`)
- Modify: `app/Sources/JamfReports/Services/ScheduleStore.swift` (`retarget(from:to:)`)
- Modify: `app/Sources/JamfReports/Models/AutomationPolicy.swift` (`replacingWorkspace(_:with:)`)
- Test: `app/Tests/JamfReportsTests/WorkspaceMergeExecutorTests.swift`

**Interfaces produced:**

```swift
struct WorkspaceMergeJournal: Codable, Equatable, Sendable {
    var plan: WorkspaceMergePlan
    /// Steps finished, counted from the start of `plan.steps`.
    var done: Int

    /// `<target>/automation/.merge-journal.json`, through `WorkspacePaths.confinedFolder`.
    static func url(target: String) -> URL?
    /// The pending journal for `target`, nil when none (or unreadable: logged).
    static func pending(target: String) -> WorkspaceMergeJournal?
}

enum WorkspaceMergeExecutor {
    struct Dependencies: Sendable {
        var hold: @Sendable (_ body: @Sendable () async throws -> Void) async throws -> Void
        /// The live peer claim on a workspace, nil when none blocks.
        var blockingClaim: @Sendable (_ workspace: String) -> SharedWorkspace.Claim?
        var writePlatformSlot: @Sendable (_ profile: String, _ workspace: String) throws -> Void
        var copyBenchmarks: @Sendable (_ source: String, _ target: String) throws -> Void
        var retargetSchedules: @Sendable (_ from: String, _ to: String) throws -> Void
        var rewritePolicy: @Sendable (_ from: String, _ to: String) async -> Void
        var appSupport: URL
        /// `holdingTickLock(purpose: .merge)`, the shared-workspace claim, the real writers.
        /// `rewritePolicy` is supplied by the caller (the GUI owns the policy).
        static func live(rewritePolicy: @escaping @Sendable (String, String) async -> Void)
            -> Dependencies
    }

    enum RunError: Error, LocalizedError, Equatable {
        case peerClaim(workspace: String, host: String)
        case step(index: Int, reason: String)
    }

    /// Runs `journal.plan` from `journal.done`, saving the journal after each step. Test seam:
    /// `stopAfter` throws `CancellationError` once that many steps have run in this call.
    static func run(
        _ journal: WorkspaceMergeJournal, deps: Dependencies, stopAfter: Int? = nil,
        progress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws
}

extension ScheduleStore {
    /// Records naming `from` name `to`; `from` in `excludedWorkspaces` becomes `to`, de-duplicated.
    /// Labels are never changed, so tick state and status files stay linked.
    func retarget(from: String, to: String) throws
}

extension AutomationPolicy {
    /// `from` replaced by `to` in `excludedWorkspaces` and every report group, de-duplicated.
    func replacingWorkspace(_ from: String, with to: String) -> AutomationPolicy
}
```

**Step semantics (each can run twice safely):**
- `copy`, `archiveSource`: copy only when the destination is absent, or holds the same bytes (then nothing). A destination with other bytes is a `step` error (never overwritten).
- `fillSummary`: copy both originals into the archive when absent, then decode the target's file and the source's archived copy, and write `target.filling(from: source)` atomically. A second run fills an already filled file, which changes nothing.
- `replaceState`: copy the target's file into the archive when the archive lacks it, then install the source's file over it.
- `archiveTarget`: move the target file into the archive when it is still there.
- `copyFolder`: copy into a staged hidden sibling, then rename into place; skip when the destination exists.
- Tail: `archiveSourceConfig` copies the source `config.yaml` into `archive/config/config.yaml`; `writePlatformSlot` calls `deps.writePlatformSlot(source, target)` (skip when the slot already names the source); `copyBenchmarks` copies `platform.compliance_benchmarks` when the target has none, through `ConfigService.saveBlock`; `retargetSchedules`; `rewritePolicy`; `removeSourcePin` removes `SharedConfigPin.storeURL(workspace: source, appSupport:)` when present; `moveSource` moves the source folder to `<mergedFolder>/workspace` (skip when it is already there and the source path is gone), then moves the journal to `<mergedFolder>/merge-journal.json`.

Before the first step of any run (fresh or resumed): check `blockingClaim` for both workspaces and throw `peerClaim` without writing. The whole run is inside `deps.hold`, so a refused hold throws `CLIBridgeError.tickLockHeld`, `.collectInProgress` and so on before anything is written. The journal is written first, with `done: 0`, before step 0.

Logging: one `AppLogger.event(.collect, .notice, …)` at the start and the end naming the step count, never a path.

**Tests:**
- [ ] A full run on fixture workspaces: the target has every source snapshot, overlapping summary days are filled (a figure only the source measured is present, the target's own values stand), both originals are in the archive, and the source folder is under `_merged/<source>-<stamp>/workspace`.
- [ ] Same-name snapshots: identical ones are untouched; different ones keep the target's bytes and put the source's in the archive.
- [ ] `stopAfter: 3`, then `run(WorkspaceMergeJournal.pending(target:)!)` with no `stopAfter`, gives the same final tree as an uninterrupted run (compare file lists and bytes). Use a guard-let, not `!`, in the test.
- [ ] A step run twice (resume from `done - 1`) changes nothing.
- [ ] The hold throwing `CLIBridgeError.tickLockHeld` writes nothing (no journal, no file copied).
- [ ] A blocking claim on the target throws `peerClaim` and writes nothing.
- [ ] `ScheduleStore.retarget`: a record for the source names the target and keeps its label; `excludedWorkspaces` is replaced and de-duplicated.
- [ ] `AutomationPolicy.replacingWorkspace`: report groups and exclusions replaced and de-duplicated.
- [ ] The source pin file is removed; the target's pin file is untouched.
- [ ] `CLIBridgeError.mergeInProgress.isCollectRefusal` is true, and a collect hold started while a merge hold runs throws it.
- [ ] Nothing in the source is deleted: every source file is present under `_merged/…/workspace`.

- [ ] Commit: `Apply a workspace merge under the tick lock with a journal (P7)`

### Task 3: the merge sheet and the Environment card entry

**Files:**
- Create: `app/Sources/JamfReports/Services/WorkspaceMergeModel.swift`
- Create: `app/Sources/JamfReports/Views/WorkspaceMergeSheet.swift`
- Modify: `app/Sources/JamfReports/Views/EnvironmentCard.swift`
- Test: `app/Tests/JamfReportsTests/WorkspaceMergeModelTests.swift`

**Interfaces produced:**

```swift
enum WorkspaceMergeCandidates {
    /// Workspaces that can merge into `target` (R2, R4): a folder (`hasWorkspace`), Jamf Pro,
    /// a Platform API profile, not `target`. Empty when `target` is itself a Platform API
    /// profile, a School workspace, or its `platform` slot names a profile not in the list.
    static func list(
        target: String, targetPlatformSlot: String?, profiles: [JamfCLIProfile],
        hasWorkspace: (String) -> Bool
    ) -> [String]
}

@MainActor @Observable
final class WorkspaceMergeModel {
    enum Phase: Equatable {
        case choose
        case checking
        case refused(String)
        case ready(WorkspaceMergePlan)
        case running(done: Int, total: Int)
        case finished(mergedFolder: String)
        case failed(String)
    }
    struct Dependencies: Sendable {
        var hostVerdict: @Sendable (_ target: String, _ source: String) async
            -> PlatformHostCheck.Verdict
        var makePlan: @Sendable (_ source: String, _ target: String) async throws
            -> WorkspaceMergePlan
        var run: @Sendable (WorkspaceMergeJournal,
            @escaping @Sendable (Int, Int) -> Void) async throws -> Void
    }
    var phase: Phase
    init(target: String, pending: WorkspaceMergeJournal?, deps: Dependencies)
    func choose(source: String) async
    func merge() async
    func resume() async
}
```

**Behaviour:**
- `choose` sets `.checking`, asks `hostVerdict` off the main actor, and refuses unless it is `.same` (R3). The `.different` text names both hosts; the `.unknown` text says the Add sheet can still add the profile as the Platform API slot. Then it calls `makePlan` off the main actor and sets `.ready`.
- `merge` and `resume` set `.running`, run the executor, and end in `.finished` or `.failed` (the error's description; `CLIBridgeError.isCollectRefusal` errors read as their own message).
- The model's live dependencies use `PlatformHostCheck.live` with the located jamf-cli (`.unknown` when none), `WorkspaceMergePlan.make` and `WorkspaceMergeExecutor.run` with `.live(rewritePolicy:)` writing the policy through `WorkspaceStore` (read the stored policy, `replacingWorkspace`, store it, `applyAutomationPolicy()`).
- The sheet shows: a picker of candidates; the checking state; the refusal; for `.ready`, one line per area with its counts, the differing config keys, each `outsideSourceFolder` entry ("read from, not moved"), and the sentence "The source folder moves to <mergedFolder> and is never deleted." with Merge and Cancel; progress while running (the sheet cannot be closed then, `interactiveDismissDisabled`); the merged folder with a Reveal in Finder button when finished. Text from files goes through `ConfigSchema.displayText`.
- The Environment card shows a "Merge another workspace into this one" button when `WorkspaceMergeCandidates.list` is not empty and not in demo mode, and an amber banner "A merge into this workspace did not finish." with Resume when `WorkspaceMergeJournal.pending(target:)` is non-nil (read off the main actor when the card loads). After `.finished`, call `WorkspaceStore.credentialsChanged()` so discovery, the sidebar and the active profile (P5's owner switch) refresh.

**Tests (model, every dependency injected):**
- [ ] `list` offers a Platform workspace for an OAuth target, and nothing for a Platform target, a School target, or a target whose slot names another profile.
- [ ] `choose` with `.different` and with `.unknown` ends in `.refused` with the matching text and never calls `makePlan`.
- [ ] `choose` with `.same` ends in `.ready(plan)`.
- [ ] `merge` reports progress and ends in `.finished`; a thrown `CLIBridgeError.tickLockHeld` ends in `.failed` with its message.
- [ ] `init` with a pending journal and `resume` runs that journal unchanged.

**Visual verification:** render the sheet's `.ready` and `.refused` phases and the card's banner at `PageScaffold.minSupportedWidth` through `NSHostingController` (as P6 did), or mark the commit `DRAFT — needs visual verification`.

- [ ] Commit: `Offer the merge from the Environment card (P7)`

### Task 4: the twin Doctor row and the docs

**Files:**
- Modify: `app/Sources/JamfReports/Services/ConfigDoctorService+Products.swift` (the `platform.twin` hint)
- Modify: `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md`, `docs/wiki/03-App-Dashboards.md` (the Data Sources section), `app/Localization/Localizable.xcstrings`
- Test: the existing `platform.twin` test file (find it with `rg -l 'platform.twin' app/Tests`)

- [ ] The hint becomes: "Merge '<platform>' into '<twin>' from Data Sources › Environment › Merge another workspace into this one. '<twin>' keeps running the Jamf Pro commands and '<platform>' becomes its Platform API profile. Nothing is changed until you merge." Update the test's expected text.
- [ ] CHANGELOG `Unreleased`, Added: one bullet saying two workspaces for one Jamf Pro can be merged from Data Sources, with no data lost, and the source folder kept under `_merged` (#305).
- [ ] CLAUDE.md and AGENTS.md: a **Workspace merge (unreleased, environment model P7)** paragraph after the **profiles config** section: the plan, the area rules in one sentence each, the lock and claim, the journal and resume, the `_merged/<source>-<stamp>/{workspace,archive}` layout, R3's positive host check. Keep both files byte-identical (`cmp`).
- [ ] Wiki: a short "Merging two workspaces" subsection in the Data Sources part of `03-App-Dashboards.md`.
- [ ] Translate every new string into the six languages and run `app/scripts/sync-strings.zsh --prune-stale`.

- [ ] Commit: `Point the twin row to the merge and describe it (P7)`
