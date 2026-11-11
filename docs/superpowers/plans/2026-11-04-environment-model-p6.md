# Environment model P6: adoption proposals and the slot-aware Add sheet — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the first-launch adoption screen and the Add sheet propose environments, not one workspace per profile.
- An OAuth profile and the Platform profile that reaches the same Jamf Pro become one workspace. The OAuth profile is its MDM, and the Platform profile is its `platform` slot.
- Protect logins are offered to an environment, with a name-prefix suggestion that is labelled as one.
- The Add sheet can add a Platform API profile to the current environment. It can pick a profile jamf-cli already has, or connect a new one.

**Architecture:**
- **`EnvironmentProposal.propose`** is a pure function. It holds spec §5's seven rules, and it replaces `twinOf` in `ExistingCLISetupFlow` and `twinNotes` in `AddSheetPlan`.
- **Adoption** accepts each proposed environment the way it accepts a profile today: connection check, `initializeWorkspace`, School routing, then first collect. Between the workspace and the collect, it writes the environment's `platform` slot (`ProfilesConfigWriter.save`) and its Protect profile (`OnboardingFlow.writeProtectConfig`), so the first collect already runs every product.
- **The Add sheet** gets one new add-on slot, Platform API, beside Protect. Its pick path and its Connect new path both end in `PlatformHostCheck` and then `ProfilesConfigWriter.save(.platform, …)`.

**Tech stack:** Swift 6, SwiftUI, XCTest. Build with `swift build --build-tests` and test with `swift test`, both from `app/`.

**Spec:** `docs/superpowers/specs/2026-10-19-environment-model-design.md`, §5, §5.1 and the P6 row of §13. The spec is on branch `docs/env-model-z1-z3` (#379), and this branch carries it. P6 stacks on P5 (`feat/env-model-p5`, #384).

## Global constraints

- **D25 (Tony, 2026-11-04):** the Add sheet's Platform API add-on includes **Connect new**: register through `OnboardingFlow.registerPlatformProfile`, run `ConnectionCheck`, run `PlatformHostCheck`, then write `profiles.platform`. There is no workspace step.
- **D26 (Tony, 2026-11-04):** the adoption cards ship **Remove** for the Platform row and an environment picker for each Protect login. Nothing else moves between cards.
- **D17:** the MDM slot is the workspace's own profile, and the folder is named after it. `ProfilesConfigWriter.save` refuses `.jamfPro` and `.jamfSchool`. Never write either slot.
- **D24:** only workspaces run. A Platform profile that becomes a slot gets no folder.
- Protect and Security Cloud are never paired automatically (spec §5 rule 5, D7).
- No pin bypass. Every slot write goes through `ProfilesConfigWriter.save` or `OnboardingFlow.writeProtectConfig`, which confirm by token (`confirmWritten`).
- Secrets are held as `Data`, wiped on every clear path (`Data.wipe()`), and go to jamf-cli over the PTY's stdin only. Never log a secret or a client ID. The secret never becomes a `String`.
- Demo mode writes nothing and runs no jamf-cli. Controls are disabled with `DemoData.liveOnlyHelp`.
- User-visible GUI text goes through `L()` in whole sentences and is translated into all six catalog languages using `app/Localization/glossary.md`. Then run `app/scripts/sync-strings.zsh --prune-stale`. `LocalizationCatalogTests` must pass. Log lines stay English.
- Any SwiftUI layout change needs visual verification at `PageScaffold.minSupportedWidth`. If you can't verify it, write `DRAFT — needs visual verification` in the commit body.
- Lines are at most 100 characters. No force unwraps. Comments explain why. Match the surrounding style. Tests never run jamf-cli: inject every effect.
- Commit subjects are imperative, at most 72 characters, with no attribution lines. CHANGELOG `Unreleased` gets plain-language bullets tagged (#305). CLAUDE.md and AGENTS.md stay byte-identical.

## Rulings

- **R1:** onboarding's "Add to Example" offer after a Platform profile validates (spec §5, last paragraph) is out of P6. It isn't in the P6 row, and the Add sheet's Platform API add-on covers the same need. Cost if wrong: one more phase item.
- **R2:** `environment.protect_match` is in P9's row (§13), not P6's.
- **R3:** if a Platform profile already has a workspace of its own and its OAuth twin has none, the twin keeps today's note. Under D17 the Platform workspace's MDM slot can't take the OAuth profile, so joining the two is P7's merge.
- **R4:** the Security Cloud slot waits for P12. Security Cloud logins are listed as unassigned, with `ExistingCLISetupFlow.securityCloudReason`.
- **R5:** `propose` takes no `connections` argument. A proposed environment holds at most one Platform profile, so Connection siblings can never share one. A test asserts this.
- **R6:** the Protect prefix match is case-insensitive. The MDM name must be followed in the login's name by a character that is not a letter or digit: `Example-Protect` matches `Example`, but `ExampleCorp-Protect` does not. Longest match wins, so `Example-Dev-Protect` goes to `Example-Dev`.
- **R7:** the adoption picker preselects the suggested environment, with the label "Suggested by name". Accept is the confirmation. Cost if wrong: a wrong pairing that the user skimmed past. P9's match-rate row is the net.
- **R8:** adoption no longer adds OAuth twins to `excludedWorkspaces`. The twin is now the workspace, and the Platform profile is its slot. `twinsLeftOut` and the policy loop go away.

---

### Task 1: `EnvironmentProposal`

**Files:**
- Create: `app/Sources/JamfReports/Services/EnvironmentProposal.swift`
- Test: `app/Tests/JamfReportsTests/EnvironmentProposalTests.swift`

**Interfaces produced:**

```swift
struct EnvironmentProposal: Equatable, Sendable {
    struct Environment: Identifiable, Equatable, Sendable {
        /// The folder and MDM profile (D17).
        var workspace: String
        var isSchool: Bool
        /// A Platform profile other than `workspace`, or nil. A Platform MDM collects its
        /// Platform kinds itself (the writer's seed), so it never appears here.
        var platform: String?
        var learnedJamfProURL: String?
        var id: String { workspace }
    }
    /// A profile to add to a workspace that already exists (rule 7).
    struct Extension: Identifiable, Equatable, Sendable {
        var workspace: String
        var slot: ProfilesConfigWriter.Slot  // .platform in P6
        var profile: String
        var learnedJamfProURL: String?
        var id: String { "\(workspace)/\(profile)" }
    }
    struct ProtectChoice: Identifiable, Equatable, Sendable {
        var profile: String
        /// The environment or workspace that rule 5's prefix suggests (R6), or nil.
        var suggested: String?
        var id: String { profile }
    }
    var environments: [Environment]
    var extensions: [Extension]
    var protectChoices: [ProtectChoice]
    /// Profiles placed nowhere, each with the reason shown beside it.
    var unassigned: [String: String]

    static func propose(
        profiles: [JamfCLIProfile],
        learnedJamfProURLs: [String: String],
        existingWorkspaces: [String: EnvironmentProfiles]
    ) -> EnvironmentProposal
}
```

The rules, applied in this order. Each one is a test.

1. **Already used.** Leave out profiles that `existingWorkspaces` names: as a key (by `ProfileName.folderKey`) or in any `connectedProfiles`.
2. **Refused.** A profile with `ExistingCLISetupFlow.scopeRefusal`, or one in `ProfileService.unusableProfiles`, goes to `unassigned` with that reason. Security Cloud goes there too (R4).
3. **Platform pairs.** For each Platform profile with a learned URL, find twins with `PlatformTwin.twins(reaching:among:)`, searched among unassigned OAuth or token profiles *and* among the existing workspaces' MDM profiles. Rule 1 drops those workspace profiles from placement, not from this search: their URLs come from their own `profiles` entries, matched to `existingWorkspaces` keys by `ProfileName.folderKey`.
   - **Two or more Platform profiles reach one host:** every one of them goes to `unassigned` with "Two Platform profiles reach the same Jamf Pro (<host>). Add the one you want from the Add sheet." Their twin becomes an environment with no platform.
   - **The twin is an existing workspace:**
     - Its `platform` slot is empty, so the result is an `Extension`.
     - Its `platform` slot names another profile, so the Platform profile goes to `unassigned` with "<ws> already has Platform API profile <p>."
   - **The twin is unassigned:** one `Environment(workspace: twin, platform: platformProfile)`.
   - **Two twins share one host:** take the first by name, and leave the others as environments of their own.
4. **Platform alone.** A Platform profile that has no twin, or no learned URL, is `Environment(workspace: itself, platform: nil)`.
5. **School.** A Jamf School login is `Environment(workspace: it, isSchool: true)`.
6. **Remaining OAuth.** Every remaining OAuth or unknown-auth Pro profile is an environment of its own.
7. **Protect.** Each Protect login becomes a `ProtectChoice`. Its `suggested` value is the longest boundary prefix (R6) among proposed environments and existing workspaces that have no `protect` slot.

Ordering: environments sorted by workspace name, and `extensions` likewise, so the cards are stable.

- [ ] **Step 1: Write the failing tests.** Build `JamfCLIProfile` fixtures inline (`authMethod: "platform"`, `"oauth2"`; `product: .pro/.school/.protect/.securityCloud`):
  - `testFourProfileExampleGivesTwoEnvironments`: `Example` (oauth2, url `example.jamfcloud.com`), `Example-API` (platform), `Example-Dev` (oauth2, `example-dev.jamfcloud.com`) and `Example-Dev-API` (platform), with learned URLs mapping each API profile to its host. The result is two environments, `Example` with platform `Example-API` and `Example-Dev` with platform `Example-Dev-API`.
  - `testConnectionSiblingsAreNeverOneEnvironment` (R5): two Platform profiles to different hosts, and no OAuth profiles, give two environments, each with `platform == nil`.
  - `testTwoPlatformProfilesOnOneHostAreFlaggedAndUnpaired`.
  - `testExistingWorkspaceIsExtendedNotDuplicated`: `existingWorkspaces["Example"]` has no platform slot, and the result is one `Extension` and no environment.
  - `testExistingWorkspaceWithAnotherPlatformLeavesTheProfileUnassigned`.
  - `testProtectSuggestedByBoundaryPrefix` covers `Example-Protect` → `Example`, `ExampleCorp-Protect` → nil, and `Example-Dev-Protect` → `Example-Dev`.
  - `testProtectIsNeverPlacedInAnEnvironment`: no `Environment` carries a Protect profile.
  - `testSchoolIsItsOwnEnvironment`.
  - `testSecurityCloudAndOrganizationLevelAreUnassignedWithReasons`.
  - `testProfilesExistingWorkspacesNameAreLeftOut`.
- [ ] **Step 2:** Run `swift test --filter EnvironmentProposalTests` and confirm it fails (the type doesn't exist yet).
- [ ] **Step 3:** Implement `propose`, using `PlatformTwin.host(of:)` and `PlatformTwin.twins(reaching:among:)`. No new host parsing.
- [ ] **Step 4:** Run `swift test --filter EnvironmentProposalTests` and confirm it passes.
- [ ] **Step 5:** Commit with the subject `Propose environments from jamf-cli's profiles`.

### Task 2: Adoption runs proposals

**Files:**
- Modify: `app/Sources/JamfReports/Services/ExistingCLISetupFlow.swift`:
  - the twin section (about lines 116–300)
  - `run` (about line 334)
  - `configuredPolicy`
- Test: `app/Tests/JamfReportsTests/ExistingCLISetupFlowTests.swift`. Change the twin tests and add new ones.

**Interfaces:**
- Consumes `EnvironmentProposal.propose` (Task 1).
- Produces these members on `ExistingCLISetupFlow`:

```swift
private(set) var proposal: EnvironmentProposal
/// Workspaces the user wants created; defaults to every proposed environment.
var selected: Set<String>
/// Platform slots the user removed from their card (D26); the profile then stays unassigned.
private(set) var removedPlatform: Set<String>
/// Each Protect login's chosen environment; starts at its suggestion (R7). nil leaves it out.
var protectAssignment: [String: String?]
func removePlatform(from workspace: String)
func resolveProposal(learn: @escaping @Sendable (String) async -> String?) async
// run(...) gains:
//   writePlatform: (_ workspace: String, _ platform: String) throws -> Void
//       = { try ProfilesConfigWriter.save(.platform, to: $1, workspace: $0) }
//   writeProtect: (_ workspace: String, _ protect: String) throws -> Void
//       = { _ = try OnboardingFlow.writeProtectConfig(profileSlug: $0, protectProfileName: $1) }
```

`profileNames` and `statuses` stay keyed by name. The rows a run creates are `proposal.environments.map(\.workspace)` filtered by `selected`.

- **`init`** calls `propose` with no learned URLs, so the first paint lists every environment and needs no probe.
- **`resolveProposal`** learns each Platform profile's URL the way `resolveTwins` did, stops if `isRunning` or `didComplete`, and calls `propose` again. If the user had already touched a selection, it carries that selection over by workspace name.
- **`run`**, for each selected environment:
  - Run the connection check for the workspace profile when it is Platform. Also run it for `platform` when that is set and not removed. A refusal of the platform profile drops only that slot, with a note on the row. A refusal of the workspace profile fails the row, as it does today.
  - Run `initialize`, then `configureSchool` when the environment is School.
  - Run `writePlatform` when `platform` is set and not removed.
  - Run `writeProtect` for each Protect login assigned to this workspace.
  - Run `collect`.
  - A slot-write failure is a note on the row (`connectionNotes`), never a failed workspace, because the workspace exists and collects its MDM.
- **`recordLearnedURLs`** keeps working from `proposal.environments[].learnedJamfProURL`.
- **`configuredPolicy`** loses the `twinsLeftOut` loop (R8).

- [ ] **Step 1: Write the failing tests.** Use the injected `initialize`, `collect`, `writePlatform` and `writeProtect` spies, and `connectionRunner: nil`, except in the refusal test.
  - `testPairedEnvironmentCreatesOneWorkspaceAndWritesItsPlatformSlot`: profiles `Example`/`Example-API`, with `learn` returning `https://example.jamfcloud.com`. The result: `initialize` is called with `["Example"]` only, `writePlatform` with `("Example","Example-API")`, and `collect` with `["Example"]`.
  - `testRemovedPlatformIsNotWritten`.
  - `testProtectWrittenOnlyToItsAssignedWorkspace`, plus an assignment set to nil, which writes nothing.
  - `testPlatformSlotWriteFailureLeavesTheWorkspaceDone`: the status is `.done` and a note is present.
  - `testConfiguredPolicyNoLongerExcludesTwins`.
  - Update or delete the existing `resolveTwins` and `twinsLeftOut` tests to the new shape, and say which ones you changed in the report.
- [ ] **Step 2:** Run `swift test --filter ExistingCLISetupFlowTests` and confirm the new tests fail.
- [ ] **Step 3:** Implement. Delete `twinOf`, `twinNote(for:)`, `resolveTwins`, `twinsLeftOut` and `touched`, and point their callers at the new members. `rg -n 'twinOf|twinNote|resolveTwins|twinsLeftOut' app` must return nothing outside Task 3's view.
- [ ] **Step 4:** Run `swift test --filter 'ExistingCLISetupFlowTests|AddSheetPlanTests'` and confirm both pass.
- [ ] **Step 5:** Commit with the subject `Adopt proposed environments with their Platform and Protect slots`.

### Task 3: Adoption screen shows one card per environment

**Files:**
- Modify: `app/Sources/JamfReports/Views/ExistingCLISetupView.swift`. Replace `profilesCard`, and change `.task` to call `resolveProposal`.
- Modify: `app/Sources/JamfReports/Views/AddSheet.swift`, only where it read the removed twin members.
- Catalog: `app/Localization/Localizable.xcstrings`.

**Card layout** (step 1, "Environments to set up"):
- Each environment is a `Card` holding:
  - A checkbox titled with the workspace name. A School environment adds "(Jamf School)" through the existing `profileTitle`.
  - A row reading "Jamf Pro · <workspace>" or "Jamf School · <workspace>".
  - When `platform` is set and not removed, a row "Platform API · <platform>" with a `Remove` button that calls `removePlatform(from:)`.
  - One row per Protect login assigned here, reading "Jamf Protect · <login>".
- "Jamf Protect logins" lists each `ProtectChoice` with a `Picker`. Its options are every selected environment plus "Not now". Under the picker, show "Suggested by name" while the choice equals `suggested` and the user hasn't changed it.
- "Not set up" lists `proposal.unassigned` as name plus reason, in the existing `profileNote` style.
- Keep the footer line about per-tenant workspaces, reworded to "Each environment gets its own workspace…".
- The controls are disabled while `isLocked`.

- [ ] **Step 1:** Implement the view, with no new service code.
- [ ] **Step 2:** Add a `#if DEBUG` `#Preview` that builds the flow from fixture profiles, using the four-profile example plus `Example-Protect` and one Security Cloud login.
- [ ] **Step 3:** Translate the new strings, run `sync-strings.zsh --prune-stale`, then run `swift test --filter LocalizationCatalogTests`.
- [ ] **Step 4:** Verify visually: render the preview at `PageScaffold.minSupportedWidth` in dark mode. Without a render, the commit body says `DRAFT — needs visual verification`.
- [ ] **Step 5:** Commit with the subject `Show adoption as one card per proposed environment`.

### Task 4: Add sheet — Platform API add-on (pick) and Re-check suggestions

**Files:**
- Modify: `app/Sources/JamfReports/Services/AddSheetPlan.swift`, in both `AddSheetPlan` and `AddSheetDiscovery`.
- Modify: `app/Sources/JamfReports/Views/AddSheet.swift`.
- Test: `app/Tests/JamfReportsTests/AddSheetPlanTests.swift`.

**Interfaces:**
- `UnassignedProfile.Use.addToCurrent` becomes `.addToCurrent(ProfilesConfigWriter.Slot)` (`.protect` or `.platform`). Update every `== .addToCurrent` comparison.
- `AddSheetDiscovery` gains these fields, filled in `load`:
  - `currentPlatform: String?`: the current workspace's `platform` slot, or the workspace itself when its own profile is Platform.
  - `currentHasJamfPro: Bool`: the workspace has a `jamf_pro` slot. A School workspace has no Platform add-on, since its Platform access lives in the School profile.
  - `suggestions: [EnvironmentProposal.Extension]`.
- `twinNotes` stays only for R3's case, a Platform workspace beside an unassigned OAuth twin. `AddSheetPlan.twinNotes` narrows to that direction.
- `load(currentWorkspace:probeTwins:)` builds `existingWorkspaces` from `EnvironmentProfiles.read(workspace:)` for each workspace and calls `EnvironmentProposal.propose`. It keeps the two-pass load: stored URLs first, the probe second.
- `use(of:)`: a Platform profile (`auth?.isPlatform == true`, not organization level) that is free becomes `.addToCurrent(.platform)` when the current workspace has `jamf_pro` and no platform slot. Otherwise it is `.newWorkspace`, as today.
- `preselection` (spec §5.1): a suggestion whose `workspace` is the current one preselects `.addToCurrent`. A free Platform profile on a workspace that takes one also preselects `.addToCurrent`. The existing rules stay otherwise.
- Add to current lists Protect rows under a "Jamf Protect" heading and Platform rows under a "Platform API" heading. A slot that is already filled shows its profile greyed, with no rows.
- **Pick a Platform row:**
  - Run `PlatformHostCheck.lookup` (live, off the main actor) and then `verdict`.
  - `.different(a, b)`: show the error "<p> reaches <b>, not this workspace's Jamf Pro (<a>). Nothing was changed."
  - `.same` or `.unknown`: run `ProfilesConfigWriter.save(.platform, to:, workspace:)`, show the message "Platform API profile <p> added to <ws>. The next collect uses it for the Platform reports.", call `workspace.credentialsChanged()`, then Re-check.
- **Suggestions** sit at the top of either step. Each one reads "<profile> reaches the same Jamf Pro as <workspace>. Add it?" and has an **Add** button. Add runs the same host check and write against `suggestion.workspace`, not the current one.

- [ ] **Step 1: Write the failing tests** in `AddSheetPlanTests`:
  - `testFreePlatformProfileIsAddToCurrentWhenSlotEmpty`.
  - `testPlatformProfileIsNewWorkspaceWhenCurrentHasPlatform`.
  - `testSchoolWorkspaceOffersNoPlatformAddOn`.
  - `testSuggestionForCurrentPreselectsAddToCurrent`.
  - `testRecheckListsAProfileAddedAfterLaunch`: a second `AddSheetDiscovery` value with a new row, through `recheck`, yields it in `visibleRows`.
  - The existing Protect tests stay green under `.addToCurrent(.protect)`.
- [ ] **Step 2:** Run `swift test --filter AddSheetPlanTests` and confirm the new tests fail.
- [ ] **Step 3:** Implement the plan code and the view. Run the host check and the write through a small closure seam on the view (`@State` is not needed), so no test runs jamf-cli.
- [ ] **Step 4:** Run `swift test --filter 'AddSheetPlanTests|EnvironmentProposalTests|LocalizationCatalogTests'` and confirm all three pass.
- [ ] **Step 5:** Verify the Add to current step visually with both slots, one filled and one with rows, plus a suggestion. Then translate the strings and sync.
- [ ] **Step 6:** Commit with the subject `Add a Platform API profile to the current environment`.

### Task 5: Add sheet — Platform API Connect new (D25)

**Files:**
- Create: `app/Sources/JamfReports/Services/PlatformSlotConnectModel.swift`. Its caller lands in this task.
- Modify: `app/Sources/JamfReports/Views/AddSheet.swift`. Add a "Connect new" disclosure under the Platform API heading.
- Test: `app/Tests/JamfReportsTests/PlatformSlotConnectModelTests.swift`.

**Interfaces produced:**

```swift
@MainActor @Observable
final class PlatformSlotConnectModel {
    struct Dependencies {
        var jamfCLI: () -> URL?
        var register: (_ binary: URL, _ profile: String, _ gatewayURL: String,
                       _ scope: PlatformScope, _ scopeID: String,
                       _ clientID: String, _ secret: Data) async throws -> Void
        var check: (_ binary: URL, _ profile: String) async -> ConnectionCheck.Verdict
        var hostVerdict: (_ workspace: String, _ platform: String, _ binary: URL) async
            -> PlatformHostCheck.Verdict
        var writeSlot: (_ workspace: String, _ platform: String) throws -> Void
        var existingProfiles: () -> [String]
        static func live() -> Dependencies
    }
    enum Outcome: Equatable { case added(String), refused(String), failed(String) }
    let workspace: String
    var profileName: String          // default "<workspace>-API"
    var region: GatewayRegion        // .us
    var scope: PlatformScope         // environment (GA default)
    var scopeID: String
    var clientID: String
    private(set) var isRunning: Bool
    private(set) var outcome: Outcome?
    func setSecret(_ data: Data)
    func clearSecret()
    var canConnect: Bool   // valid name not in existingProfiles, usable scope ID, client ID, secret
    func connect() async
}
```

What `connect` does:

1. Run `signatureGate` through `register`'s live closure, as `ConnectionCredentialsModel+Live` does.
2. Register the profile. A throw becomes `.failed(redacted message)`. The registration helper already redacts.
3. Run `check`:
   - `.rejectedID` or `.noJamfPro` becomes `.refused(message + " The profile <p> is still in jamf-cli; remove it with jamf-cli config remove-profile <p>.")`, with the shell word quoted through `ProfileName.shellWord`.
   - `.missingPermission` and `.undecided` continue, carrying the note.
4. Run `hostVerdict`. `.different` is refused with the Task 4 text plus the remove-profile line.
5. Run `writeSlot`, then `.added(note)`.
6. Wipe the secret in `defer`. `clearSecret` also runs when the sheet closes.

The live closures call:
- `OnboardingFlow.registerPlatformProfile`
- `ConnectionCheck.run(profile:runner: ConnectionCheck.runner(binary:))`
- `PlatformHostCheck.live`, wrapped in `Task.detached`
- `ProfilesConfigWriter.save(.platform, …)`

The view uses the existing pieces: `GatewayRegion` picker, `SecureSecretField`, and the scope picker the onboarding Platform step uses. Find them with `rg -n 'GatewayRegion|SecureSecretField' app/Sources/JamfReports/Views`.

- [ ] **Step 1: Write the failing tests** with spy dependencies, none touching jamf-cli:
  - `testAcceptedAddsTheSlot`: `writeSlot` is called once, and the outcome is `.added`.
  - `testRejectedIDRefusesAndNamesRemoveProfile`: `writeSlot` is never called.
  - `testDifferentHostRefuses`.
  - `testSecretIsWipedAfterConnect`: expose a test-only `secretByteCount` under `#if DEBUG`, or assert through the spy that the bytes it received were zeroed afterward.
  - `testExistingProfileNameCannotConnect`.
- [ ] **Step 2:** Run the tests and confirm they fail.
- [ ] **Step 3:** Implement the model and the view's disclosure. The view is disabled in demo mode.
- [ ] **Step 4:** Run `swift test --filter 'PlatformSlotConnectModelTests|LocalizationCatalogTests'` and confirm both pass.
- [ ] **Step 5:** Verify the expanded form visually, then translate the strings and sync.
- [ ] **Step 6:** Commit with the subject `Connect a new Platform API profile to the current environment`.

### Task 6: Docs

- [ ] CHANGELOG `Unreleased`, tagged (#305). Three bullets:
  - **Changed:** first launch proposes one workspace per environment and adds a Platform profile to its Jamf Pro.
  - **Added:** the Add sheet adds a Platform API profile, existing or new, to the current environment.
  - **Added:** Re-check suggests where a new profile belongs.
- [ ] CLAUDE.md and AGENTS.md:
  - Update the `ExistingCLISetupFlow` / `PlatformTwin` row: proposals replace unticking the twin, and twins are no longer excluded.
  - Add one row for `EnvironmentProposal`.
  - Name `PlatformSlotConnectModel` in the Add sheet text.
  - Check with `cmp CLAUDE.md AGENTS.md`.
- [ ] Run the full `swift test` and report the real counts.
- [ ] Commit with the subject `Document environment proposals and the Platform add-on`.
