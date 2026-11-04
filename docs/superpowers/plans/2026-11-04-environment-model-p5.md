# Environment model P5: discovery — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Only workspaces run and appear in the sidebar. A jamf-cli profile that no workspace uses is listed on Data Sources in a "Profiles not in an environment" card.

**Architecture:**
- `ProfileService.runnableProfiles` becomes `runnableWorkspaces` and requires a workspace folder for every product.
- `WorkspaceStore` builds the sidebar menu from workspaces, plus the active profile.
- The active-profile fallback follows any slot (`connectedProfiles`), not only Protect.
- The new card reuses `AddSheetDiscovery` and opens the Add sheet for its actions. Adoption code is not duplicated.

**Tech stack:** Swift 6, SwiftUI, XCTest; `swift build --build-tests` and `swift test` from `app/`.

**Spec:** `docs/superpowers/specs/2026-10-19-environment-model-design.md`, §4.2 and the P5 row of §13. It is on branch `docs/env-model-z1-z3` (#379), and this branch carries it.

## Global constraints

- **D24 (Tony, 2026-11-04):** "workspaces only". Neither all-profiles schedules, nor catch-up, nor any multi-profile run runs a profile without a workspace folder (a folder holding `config.yaml`). A single-profile schedule that names a profile is unchanged.
- `WorkspaceStore.profiles` keeps every discovered profile. The first-launch routing in `ContentView` (empty list leads to the chooser; profiles with no folder lead to `ExistingCLISetupView`), Cmd-N, the Settings connections list and the redaction seeds read it. Do not filter it.
- No renames beyond `runnableProfiles` → `runnableWorkspaces`. `activeProfile` → `activeWorkspace` and `activeCLIProfile` → `profile(for:)` from §4.2 are deferred (Ruling R1).
- "Add to this environment" and "New environment" open the existing Add sheet (`.showAddSheet`). P6 replaces that sheet, so the card does not build its own adoption (Ruling R2).
- User-visible GUI text goes through `L()`, in whole sentences, translated into all six catalog languages with `app/Localization/glossary.md`. Then run `app/scripts/sync-strings.zsh --prune-stale`. `LocalizationCatalogTests` must pass.
- Any SwiftUI layout change needs visual verification at `PageScaffold.minSupportedWidth`. If you cannot do it, write `DRAFT — needs visual verification` in the commit body.
- 100-character lines. No force unwraps. Comments explain why. Match the surrounding style.
- Commit subjects are imperative and at most 72 characters, with no attribution lines.
- CHANGELOG `Unreleased`: plain-language bullets tagged (#305).
- CLAUDE.md and AGENTS.md stay byte-identical.

## Rulings

- **R1:** Skip the `activeWorkspace` and `profile(for:)` renames. They change no behaviour and touch about 100 call sites. Cost if wrong: a later rename PR.
- **R2:** The card lists rows and opens the Add sheet, which already has "Set up workspace" and "Add to <current>" for these same rows (`AddSheetPlan.unassigned`). P6's one Add flow then replaces both at once. Cost if wrong: one more click until P6.
- **R3:** The sidebar menu still shows the active profile when it has no folder (for example, right after onboarding), so the menu always holds the current entry.

---

### Task 1: Run workspaces only

**Files:**
- Modify: `app/Sources/JamfReports/Services/ProfileService.swift` (the `runnableProfiles` definition, about line 338)
- Modify the callers:
  - `app/Sources/JamfReports/App/Tick.swift` (lines 163, 214, 237, 400 and 411)
  - `app/Sources/JamfReports/App/HeadlessRun.swift` (line 799)
  - `app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift` (line 1012)
- Tests:
  - `app/Tests/JamfReportsTests/ProfileProductTests.swift` (`testRunnableProfilesNeverRunAProtectLoginAndNeedAFolderForSchool`)
  - `OrganizationLevelProfileTests.swift` (`testRunnableProfilesLeaveAnOrganizationProfileOutUntilItHasAFolder`)
  - `PairedProductProfileTests.swift` (`testPairedProfileIsNotARunTarget`)
  - any other `runnableProfiles` reference (`rg -n runnableProfiles app`)

**Interfaces produced:**

```swift
static func runnableWorkspaces(
    _ profiles: [JamfCLIProfile],
    excluding excluded: Set<String>,
    hasWorkspace: (String) -> Bool = { ProfileService.hasWorkspace($0) }
) -> [JamfCLIProfile]
```

- [ ] **Step 1: Write the failing test.** Add this to `ProfileProductTests`:
  - A Jamf Pro `oauth2` profile with no folder is not returned. Use `hasWorkspace: { _ in false }`.
  - The same profile with `hasWorkspace: { _ in true }` is returned.
  - Rename the existing runnable tests to the new name. Their School and organization-level cases now hold for every product.
- [ ] **Step 2:** Run `swift test --filter ProfileProductTests`. It should fail: compile error (no `runnableWorkspaces`).
- [ ] **Step 3: Implement.**

```swift
/// The workspaces a multi-profile run collects (D24): exclusions applied, and only profiles
/// with a workspace folder. An `.error` profile (unsupported name, or a case variant sharing
/// another's folder) and a Protect or Security Cloud login are never run. A jamf-cli
/// profile with no workspace waits on Data Sources' "Profiles not in an environment" card;
/// before 2.12 a run created its folder.
static func runnableWorkspaces(
    _ profiles: [JamfCLIProfile],
    excluding excluded: Set<String>,
    hasWorkspace: (String) -> Bool = { ProfileService.hasWorkspace($0) }
) -> [JamfCLIProfile] {
    applyingExclusions(profiles, excluding: excluded).filter { profile in
        profile.status != .error && !profile.product.isNeverAWorkspace
            && hasWorkspace(profile.name)
    }
}
```

  Rename every caller, and update the comments at the callers that describe the old rule.
- [ ] **Step 4:** Run `swift test --filter 'ProfileProduct|OrganizationLevelProfile|PairedProductProfile|Tick|HeadlessRun|Catch'`. Every test must pass; a failing test that relied on a profile without a folder being run has to change with D24. In each test you change, say why in the report.
- [ ] **Step 5:** Add a CHANGELOG `Unreleased` › Changed bullet: "Scheduled runs for all workspaces and the catch-up collect run only workspaces. A jamf-cli profile without one no longer gets a workspace made for it by a run; add it from Data Sources or the Add sheet. (#305)"
- [ ] **Step 6:** Commit `Run only workspaces in multi-profile runs (D24)`.

### Task 2: Sidebar lists workspaces; the active fallback follows any slot

**Files:**
- Modify: `app/Sources/JamfReports/Services/WorkspaceStore.swift`:
  - `connectionGrouping` (about line 270)
  - `initialProfile(in:)` and `activeProfile(keeping:in:protectProfile:)` (about lines 1206-1224)
  - init (about line 377)
  - `reloadFromDisk` (about line 473)
- Tests:
  - `ProfileProductTests.testTheActiveProfileMovesToTheWorkspaceNamingItsProtectLogin`
  - `ProfileSlugCaseTests` (lines 94-106)
  - a new `WorkspaceMenuTests.swift` (or extend an existing sidebar or grouping test file, if one exists)

**Interfaces produced:**

```swift
/// Workspaces for the sidebar menu (§4.2), plus the active profile when it has no folder (R3).
var workspaceMenuProfiles: [JamfCLIProfile]
nonisolated static func initialProfile(
    in profiles: [JamfCLIProfile], hasWorkspace: (String) -> Bool
) -> JamfCLIProfile?
nonisolated static func activeProfile(
    keeping current: String, in profiles: [JamfCLIProfile],
    hasWorkspace: (String) -> Bool = { ProfileService.hasWorkspace($0) },
    connectedProfiles: (String) -> [String] = {
        EnvironmentProfiles.read(workspace: $0).connectedProfiles
    }
) -> String?
```

- [ ] **Step 1: Write the failing tests.**
  - `initialProfile` returns the first non-`.error` profile that has a workspace. If none has one, it returns the first non-`.error` profile; if every profile is `.error`, the first profile. The existing `ProfileSlugCaseTests` cases keep their expectations when `hasWorkspace` is `{ _ in false }`.
  - `activeProfile(keeping: "plat", …)`, where "plat" is no longer listed and workspace "pro" has `connectedProfiles` `["plat"]`, returns "pro". The same holds for a Protect and a Security Cloud name. The existing Protect test keeps passing after its closure is changed to `connectedProfiles`.
  - `workspaceMenuProfiles` returns, from profiles `[a (folder), b (no folder), c (folder)]`, `[a, c]` when the active profile is "a", and `[a, b, c]` in discovery order when the active profile is "b". `initializedProfiles` already has the folder rule, so build on it. Demo mode returns `profiles`.
- [ ] **Step 2:** Run the tests and confirm they fail.
- [ ] **Step 3: Implement.**
  - `initialProfile(in:hasWorkspace:)`: `profiles.first { $0.status != .error && hasWorkspace($0.name) } ?? profiles.first { $0.status != .error } ?? profiles.first`.
  - The init call site passes `hasWorkspace: { ProfileService.hasWorkspace($0) }`. Keep a single-argument overload only if some caller cannot pass the closure; otherwise update every caller.
  - `activeProfile`: the owner is the first non-`.error` listed profile whose `connectedProfiles($0.name)` contains `current`. Otherwise use `initialProfile(in:hasWorkspace:)`.
  - `workspaceMenuProfiles`: `initializedProfiles` plus the active profile when it is missing from that list, in `profiles` order.
  - `connectionGrouping` groups `workspaceMenuProfiles`.
  - Update the doc comments: the menu lists workspaces, and the fallback follows any slot.
- [ ] **Step 4:** Run `swift test --filter 'ProfileProduct|ProfileSlugCase|WorkspaceMenu|Connection'` and confirm it passes.
- [ ] **Step 5:** Add a CHANGELOG Changed bullet: "The workspace menu lists workspaces only; jamf-cli profiles without one are on Data Sources. When a profile becomes another workspace's Platform API, Protect or Security Cloud login, the app opens that workspace. (#305)"
- [ ] **Step 6:** Commit `List only workspaces in the menu, follow any slot on reload`.

### Task 3: "Profiles not in an environment" card on Data Sources

**Files:**
- Create: `app/Sources/JamfReports/Views/UnassignedProfilesCard.swift`
- Modify:
  - `app/Sources/JamfReports/Views/SourcesView.swift` (place the card after the Environment card, about line 66, and reload it on `sourceChanged()`)
  - `app/Localization/Localizable.xcstrings` (through `sync-strings.zsh`, then translations)
  - CHANGELOG
  - CLAUDE.md and AGENTS.md (one sentence in the `ProfileService` row, the `Connection` row or the Data Sources text near the Environment card)
- Test: `app/Tests/JamfReportsTests/UnassignedProfilesCardTests.swift`

**Interfaces consumed:**
- `AddSheetDiscovery.load(currentWorkspace:)` returns `unassigned: [AddSheetPlan.UnassignedProfile]?` (nil means jamf-cli could not be read). It runs `jamf-cli config list`, so call it off the main actor, as `AddSheet` does.
- `UnassignedProfile`: `name`, `product: JamfCLIProduct`, `url`, `authMethod`, `use` (`.newWorkspace`, `.addToCurrent` or `.unavailable(reason)`).
- `.showAddSheet` (`NotificationCenter`, `object: nil`) opens the Add sheet, whose "Profiles jamf-cli already has" section does the adoption.

**Interfaces produced:**

```swift
struct UnassignedProfilesCard: View {
    let rows: [AddSheetPlan.UnassignedProfile]
}
enum UnassignedProfilesCardText {
    /// The row's subtitle: product name, auth method and host. The host is
    /// `URL(string:)?.host`, else the url as stored, through `ConfigSchema.displayText`.
    static func subtitle(for row: AddSheetPlan.UnassignedProfile) -> String
}
```

- [ ] **Step 1: Write the failing tests** for `subtitle`:
  - A Jamf Pro `oauth2` row with url `https://acme.jamfcloud.com` reads with the product name, "oauth2" and "acme.jamfcloud.com". Assert that it contains each part.
  - A row with an empty url leaves the host out.
  - A row with `.unavailable("reason")`: the view shows the reason. If that logic is pure, test it; otherwise skip it.
- [ ] **Step 2:** Run the tests and confirm they fail.
- [ ] **Step 3: Implement the card.** Match `EnvironmentCard`'s look (read `Views/EnvironmentCard.swift` and copy its card container, header and row style).
  - Title: "Profiles not in an environment".
  - One line of explanation: "jamf-cli has these profiles, but no workspace uses them, so nothing collects them."
  - One row per profile: the name (`ConfigSchema.displayText`), the subtitle, and the unavailable reason when there is one.
  - Footer button: "Add or set up…". It posts `.showAddSheet` with `object: nil`.
  - The card is hidden when the list is empty or nil, and in demo mode (`workspace.demoMode`).
  - In `SourcesView`: add `@State private var unassigned: [AddSheetPlan.UnassignedProfile] = []`, loaded with `Task.detached { AddSheetDiscovery.load(currentWorkspace: profile).unassigned ?? [] }` in the same task and `sourceChanged()` path that reloads the Environment card. Do not load in demo mode.
  - Use `WrappingRow` for anything that can run long, as `EnvironmentCard` does.
  - Add a `#Preview`, wrapped in `#if DEBUG`, with two rows (one `.unavailable`), pinned `.preferredColorScheme(.dark)`.
- [ ] **Step 4:** Run `app/scripts/sync-strings.zsh --prune-stale`, translate the new keys into every catalog language (fr, es, de, pt-BR, it, ja) with `app/Localization/glossary.md`, then run `swift test --filter 'UnassignedProfilesCard|LocalizationCatalog'` and confirm it passes.
- [ ] **Step 5:** Add a CHANGELOG Added bullet: "Data Sources lists the jamf-cli profiles that no workspace uses, with a button to add them. (#305)". In CLAUDE.md and AGENTS.md, add one sentence near the Environment card text in the `ProfileService` row: the card name, that it reads `AddSheetDiscovery`, and that it opens the Add sheet (R2).
- [ ] **Step 6:** Commit `List profiles not in an environment on Data Sources`. The commit body says `DRAFT — needs visual verification`; the controller renders the preview.
