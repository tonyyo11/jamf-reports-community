# Environment model P4: the Environment card, the block writer and its Doctor rows — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Data Sources shows the environment's product slots and can check or remove one; the app writes the `profiles:` block itself, without dropping the old keys; Config Doctor explains each way a block can be wrong; and the existing Protect writers keep working once a block exists.

**Architecture:** One scoped writer, `ProfilesConfigWriter`, owns every write of `profiles:` (the card's Remove, and the Protect connect and disconnect writers when a block exists). Its first write turns the slots `EnvironmentProfiles` derives from the old keys into the block, so a migrated file collects with the same profiles. Old keys stay in place (D14). Five Doctor rows live in one new family file, and each is a pure function with injected closures plus a live wrapper, as `platformTwinRows` is. The card is a pure state model (`EnvironmentCardState`) built off the main actor, plus a SwiftUI view.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftPM, XCTest. No new dependency.

**Spec:** `docs/superpowers/specs/2026-10-19-environment-model-design.md`, sections 3.1, 3.3, 3.4, 4.1, 6, the P4 row, and decisions D14, D17, D18, D21, D22, D23. Read 3.4 and 6 before Tasks 1 and 6.

## Global Constraints

- macOS 15 floor; CI builds with Swift 6.1, 6.2 and 6.4. Run `/vm-test` on `ci-macos15-xcode16.4` before pushing.
- No new Swift package.
- Functions ≤100 lines, cyclomatic complexity ≤8, lines ≤100 characters, no force unwrap.
- Tests never run the installed jamf-cli; a stub is never named `jamf-cli`.
- A workspace without `profiles:` behaves exactly as before until something writes the block. Nothing in P4 writes it except an action the person takes (Remove, or connecting or disconnecting Protect, on a file that already has one).
- Old keys (`jamf_cli.profile`, `protect.*`, `school_cli.*`) are never deleted and never enter `ConfigSchema.retiredKeys` (D14, spec 3.4).
- Every user-visible string goes through `L("…")` and is translated into fr, es, de, pt-BR, it and ja, with state `translated`. Follow `app/Localization/glossary.md` (never translate Jamf product names, `config.yaml` keys or anything in backticks). Run `app/scripts/sync-strings.zsh` after adding strings. `LocalizationCatalogTests` must pass.
- SwiftUI layout primitives need visual verification at `PageScaffold.minSupportedWidth` (CLAUDE.md). Render the card with the Xcode MCP `RenderPreview` (CLAUDE.local.md: `JamfReportsKit` scheme, `.preferredColorScheme(.dark)`, `#if DEBUG` preview) and mark the commit body `DRAFT — needs visual verification`. Tony gives the visual sign-off.
- Demo mode never reads or writes a workspace: the card's actions are disabled with `DemoData.liveOnlyHelp`.
- Every edit: run `git log --oneline origin/main..HEAD -- <path>` first and state the count.
- CHANGELOG: plain language, no class names.

## Not in this plan

- **Pin-aware re-resolve after the checkpoint (#305 follow-up).** Moot: under D17 the MDM slot equals the workspace and is refused otherwise, so it cannot drift, and `protect` and `platform` already skip on drift (`collectProtect`, `ReportEngine.platformRoute`). Re-resolving to the pinned value would turn those skips into substitutions. Task 7 closes the #305 item with that reason.
- **The card's Add and Change steps aimed at a slot (P5/P6), and hiding a removed product's screens (P8)** (D23). Add and Change open today's Add sheet with the product preselected.
- **The binding's `jamf_cli.profile` write** stays as it is (D22).
- **A Security Cloud row** (P12).

## File map

| File | Change |
|---|---|
| `app/Sources/JamfReports/Services/ProfilesConfigWriter.swift` (new) | The one writer of `profiles:` |
| `app/Sources/JamfReports/Services/ConfigEditedKeys.swift` | Probe the new writer |
| `app/Sources/JamfReports/Services/OnboardingFlow.swift` (`writeProductBlock`) and `Services/ProtectConnection.swift` (`disconnect`) | Under a block, write the slot through the new writer |
| `app/Sources/JamfReports/Services/ConfigDoctorService+Environment.swift` (new) | The five `environment.*` rows |
| `app/Sources/JamfReports/Services/ConfigDoctorService.swift` (`run`) | Add the family |
| `app/Sources/JamfReports/Services/ConfigDoctorService+Products.swift` (`platformTwinRows`) | D21 wording |
| `app/Sources/JamfReports/Services/EnvironmentCardState.swift` (new) | The card's pure model |
| `app/Sources/JamfReports/Views/EnvironmentCard.swift` (new), `Views/SourcesView.swift` | The card and its placement |
| `app/Localization/Localizable.xcstrings` | New and changed strings, six languages |
| Tests | `ProfilesConfigWriterTests` (new), `ProtectConnectionTests`, `ProfilesBlockEntryPointTests`, `EnvironmentDoctorRowsTests` (new), `PlatformTwinTests`, `EnvironmentCardStateTests` (new) |
| `CLAUDE.md`, `AGENTS.md`, `CHANGELOG.md`, the spec | Task 7 |

---

### Task 1: `ProfilesConfigWriter`

**Files:**
- Create: `app/Sources/JamfReports/Services/ProfilesConfigWriter.swift`
- Modify: `app/Sources/JamfReports/Services/ConfigEditedKeys.swift:14-22`
- Test: `app/Tests/JamfReportsTests/ProfilesConfigWriterTests.swift` (model on `ChartsConfigStoreTests.swift`: temp root, `JRC_TEST_WORKSPACES_ROOT`, `write`, `readBack`)

**Interfaces:**
- Produces:
  ```swift
  enum ProfilesConfigWriter {
      enum Slot: String, CaseIterable, Sendable {
          case jamfPro = "jamf_pro", platform, jamfSchool = "jamf_school", protect
          case securityCloud = "security_cloud"
      }
      enum WriteError: Error, LocalizedError, Equatable {
          case invalidProfile(String)
          case invalidSlotProfile(String)
          case mdmIsTheWorkspace
      }
      /// Sets (`name`) or clears (nil) one slot. On a file without `profiles:`, first writes the
      /// slots `EnvironmentProfiles` derives from the old keys, so the run that follows uses the
      /// same profiles; the old keys are left in place (D14).
      static func apply(
          _ slot: Slot, to name: String?, derived: EnvironmentProfiles,
          root: inout YAMLCodec.YAMLMapping)
      @discardableResult
      static func save(_ slot: Slot, to name: String?, workspace profile: String,
                       appSupport: URL = AppSupport.directory()) throws -> ConfigSaveReport
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import JamfReports

final class ProfilesConfigWriterTests: XCTestCase {
    private var root: URL!
    private let ws = "profileswriter"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JRC-ProfilesWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var configURL: URL { root.appendingPathComponent(ws).appendingPathComponent("config.yaml") }
    private func write(_ text: String) throws {
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }
    private func readBack() throws -> String { try String(contentsOf: configURL, encoding: .utf8) }
    private func environment() throws -> EnvironmentProfiles {
        EnvironmentProfiles.resolve(
            config: try ConfigLoader.load(from: configURL), workspace: ws)
    }

    /// The first write turns the derived slots into the block and leaves the old keys (D14).
    func testTheFirstWriteKeepsTheDerivedSlotsAndTheOldKeys() throws {
        try write("""
            # team note
            jamf_cli:
              data_dir: jamf-cli-data
            protect:
              enabled: true
              profile: "\(ws)-Protect"
            """)
        try ProfilesConfigWriter.save(.platform, to: "\(ws)-API", workspace: ws)
        let after = try environment()
        XCTAssertEqual(after.source, .profilesBlock)
        XCTAssertEqual(after.jamfPro, ws)
        XCTAssertEqual(after.platform, "\(ws)-API")
        XCTAssertEqual(after.protect, "\(ws)-Protect")
        let text = try readBack()
        XCTAssertTrue(text.contains("profile: \"\(ws)-Protect\""), "old protect.profile kept")
        XCTAssertTrue(text.contains("# team note"), "comment outside the block kept")
    }

    func testClearingASlotRemovesOnlyThatSlot() throws {
        try write("profiles:\n  jamf_pro: \(ws)\n  protect: \(ws)-Protect\n  platform: \(ws)-API\n")
        try ProfilesConfigWriter.save(.protect, to: nil, workspace: ws)
        let after = try environment()
        XCTAssertNil(after.protect)
        XCTAssertEqual(after.platform, "\(ws)-API")
        XCTAssertEqual(after.jamfPro, ws)
    }

    /// D17: the MDM slot is always the workspace; the writer never names another profile there.
    func testTheMDMSlotCannotNameAnotherProfile() throws {
        try write("profiles:\n  jamf_pro: \(ws)\n")
        XCTAssertThrowsError(try ProfilesConfigWriter.save(.jamfPro, to: "other", workspace: ws)) {
            XCTAssertEqual($0 as? ProfilesConfigWriter.WriteError, .mdmIsTheWorkspace)
        }
        XCTAssertThrowsError(try ProfilesConfigWriter.save(.jamfPro, to: nil, workspace: ws))
    }

    func testAnUnusableSlotNameIsRefused() throws {
        try write("profiles:\n  jamf_pro: \(ws)\n")
        XCTAssertThrowsError(try ProfilesConfigWriter.save(.platform, to: "bad\u{7}name", workspace: ws))
        XCTAssertFalse(try readBack().contains("bad"))
    }

    /// D14: a scoped save of another block on a file without `profiles:` keeps the old keys.
    func testTheBackupsProtectSwitchKeepsProtectProfile() throws {
        try write("protect:\n  enabled: true\n  profile: \"\(ws)-Protect\"\n")
        try BackupChoiceConfigWriter.save(.protect, on: true, profile: ws)
        XCTAssertEqual(try environment().protect, "\(ws)-Protect")
    }

    func testTheWriterKeysAreKnownToTheConfigScreen() {
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["profiles", "platform"]))
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["profiles", "protect"]))
    }
}
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head`

- [ ] **Step 3: Implement**

`ProfilesConfigWriter.swift`:

```swift
import Foundation

/// The one writer of config.yaml's `profiles:` block (spec 3.4). A scoped `saveBlock` like
/// `ChartsConfigWriter`: other blocks and the comments outside this one stay, and a dropped
/// comment is copied out first. The old keys are never removed (D14).
enum ProfilesConfigWriter {
    enum Slot: String, CaseIterable, Sendable {
        case jamfPro = "jamf_pro", platform, jamfSchool = "jamf_school", protect
        case securityCloud = "security_cloud"
    }

    enum WriteError: Error, LocalizedError, Equatable {
        case invalidProfile(String)
        case invalidSlotProfile(String)
        case mdmIsTheWorkspace

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let name):
                L("'\(ConfigSchema.displayText(name))' is not a valid workspace")
            case .invalidSlotProfile(let name):
                L("'\(ConfigSchema.displayText(name))' is not a usable jamf-cli profile name")
            case .mdmIsTheWorkspace:
                L("The Jamf Pro or Jamf School slot always names this workspace's own profile")
            }
        }
    }

    static func apply(
        _ slot: Slot, to name: String?, derived: EnvironmentProfiles,
        root: inout YAMLCodec.YAMLMapping
    ) {
        var block = root.value(for: "profiles")?.mapping ?? seeded(from: derived)
        if let name {
            block.set(slot.rawValue, value: .scalar(.string(name)))
        } else {
            block.entries.removeAll { $0.key == slot.rawValue }
        }
        root.set("profiles", value: .mapping(block))
    }

    /// The block a file without one starts from: the slots the old keys give today.
    private static func seeded(from derived: EnvironmentProfiles) -> YAMLCodec.YAMLMapping {
        var block = YAMLCodec.YAMLMapping(entries: [])
        let slots: [(Slot, String?)] = [
            (.jamfPro, derived.jamfPro), (.jamfSchool, derived.jamfSchool),
            (.protect, derived.protect),
        ]
        for case let (slot, value?) in slots { block.set(slot.rawValue, value: .scalar(.string(value))) }
        return block
    }

    @discardableResult
    static func save(
        _ slot: Slot, to name: String?, workspace profile: String,
        appSupport: URL = AppSupport.directory()
    ) throws -> ConfigSaveReport {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        if slot == .jamfPro || slot == .jamfSchool, name != profile {
            throw WriteError.mdmIsTheWorkspace
        }
        if let name, !ProfileService.isValid(name) { throw WriteError.invalidSlotProfile(name) }
        let config = ProfileService.workspaceURL(for: profile).flatMap {
            try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
        }
        let derived = EnvironmentProfiles.resolve(config: config, workspace: profile)
        let report = try ConfigService.saveBlock(key: "profiles", profile: profile) {
            apply(slot, to: name, derived: derived, root: &$0)
        }.report
        // The operator's own act: confirm what it wrote, so the next run does not read it as drift.
        let keys: [SharedConfigPin.Key] = switch slot {
        case .platform: [.platformProfile]
        case .protect: [.protectProfile]
        default: []
        }
        if !keys.isEmpty {
            SharedConfigPin.confirmBestEffort(profile: profile, keys: keys, appSupport: appSupport)
        }
        return report
    }
}
```

`ConfigEditedKeys.derive()`: after `BackupChoiceConfigWriter.apply(.pro, …)` add:

```swift
        for slot in ProfilesConfigWriter.Slot.allCases {
            ProfilesConfigWriter.apply(slot, to: "probe", derived: .none, root: &root)
        }
```

If `YAMLCodec.YAMLMapping.set` or `entries` have other names, use the ones `ChartsConfigWriter` uses. If the localized `errorDescription` strings need catalog entries, add them with their six translations.

- [ ] **Step 4: Run** `swift test --filter 'ProfilesConfigWriter|ConfigWriterKeys|ConfigEditedKeys|SharedConfigPin|LocalizationCatalog'`, then the full suite once.

- [ ] **Step 5: Commit** — `git commit -m "Add the profiles block writer"`

---

### Task 2: The Protect writers follow the block

**Files:**
- Modify: `app/Sources/JamfReports/Services/OnboardingFlow.swift` (`writeProductBlock`, ~1372)
- Modify: `app/Sources/JamfReports/Services/ProtectConnection.swift` (`disconnect`, ~43)
- Test: `ProtectConnectionTests.swift`, `ProfilesBlockEntryPointTests.swift`

**Interfaces:**
- Consumes: `ProfilesConfigWriter.save(_:to:workspace:appSupport:)` (Task 1).

Today both refuse under a block (`ConfigError.profilesBlock`), so once Task 6's card writes the block, Data Sources could no longer connect or disconnect Protect (EGM review C34). Under a block they write `profiles.protect` instead; without one they write `protect.*` exactly as now. `school_cli` keeps its refusal under a block: a Jamf School environment's slot is its workspace (D17), and onboarding writes a new workspace, which has no block.

- [ ] **Step 1: Write the failing tests** (in `ProtectConnectionTests` / `ProfilesBlockEntryPointTests`, beside the existing refusal tests — replace any test that asserts the Protect refusal under a block):

```swift
    func testConnectingProtectUnderABlockWritesTheSlot() throws {
        // A workspace whose config.yaml has `profiles:\n  jamf_pro: <ws>\n`
        try OnboardingFlow.writeProductBlock("protect", profile: "\(ws)-Protect", for: ws)
        let environment = EnvironmentProfiles.resolve(config: try load(), workspace: ws)
        XCTAssertEqual(environment.protect, "\(ws)-Protect")
        XCTAssertFalse(try readBack().contains("enabled: true"), "no protect block written")
    }

    func testDisconnectingProtectUnderABlockClearsTheSlot() throws {
        // `profiles:\n  jamf_pro: <ws>\n  protect: <ws>-Protect\n`
        try ProtectConnection.disconnect(workspace: ws, appSupport: appSupport)
        XCTAssertNil(EnvironmentProfiles.resolve(config: try load(), workspace: ws).protect)
    }

    func testSchoolStillRefusesUnderABlock() throws {
        // `profiles:\n  jamf_pro: <ws>\n`
        XCTAssertThrowsError(
            try OnboardingFlow.writeProductBlock("school_cli", profile: "s", for: ws))
    }
```

Use the file's existing helpers for the workspace, config text and `appSupport`; add `load()` / `readBack()` only if the file has none.

- [ ] **Step 2: Run, expect failures** (the two Protect tests throw `profilesBlock`).

- [ ] **Step 3: Implement**

`writeProductBlock`: before the `saveBlock` call,

```swift
        if key == "protect", Self.hasProfilesBlock(workspace: profileSlug) {
            return try ProfilesConfigWriter.save(.protect, to: name, workspace: profileSlug)
        }
```

`ProtectConnection.disconnect`: first line of the body,

```swift
        if OnboardingFlow.hasProfilesBlock(workspace: profile) {
            return try ProfilesConfigWriter.save(
                .protect, to: nil, workspace: profile, appSupport: appSupport)
        }
```

and a shared helper (in `OnboardingFlow` or `ProfilesConfigWriter`, wherever the file reads better):

```swift
    /// Whether the workspace's config.yaml has a `profiles:` mapping (read as the decoder reads it).
    static func hasProfilesBlock(workspace profile: String) -> Bool {
        let config = ProfileService.workspaceURL(for: profile).flatMap {
            try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
        }
        return config?.profiles != nil
    }
```

The existing `writeProtectConfig` confirms the pin after writing; `ProfilesConfigWriter.save` already confirms `.protectProfile`, so do not confirm twice.

- [ ] **Step 4: Run** `swift test --filter 'ProtectConnection|ProfilesBlockEntryPoint|OnboardingFlow|ProfilesConfigWriter'`, then the full suite.

- [ ] **Step 5: Commit** — `git commit -m "Write profiles.protect when connecting Protect under a block"`

---

### Task 3: Five `environment.*` Doctor rows

**Files:**
- Create: `app/Sources/JamfReports/Services/ConfigDoctorService+Environment.swift`
- Modify: `app/Sources/JamfReports/Services/ConfigDoctorService.swift` (`run`, ~60-100: add after `profileOwnerRows`)
- Test: `app/Tests/JamfReportsTests/EnvironmentDoctorRowsTests.swift` (model on `PlatformTwinTests.testDoctorNamesTheTwinOnEitherWorkspace`)

**Interfaces:**
- Produces (pure; live wrappers have the same names with only `profile:` and `config:`):
  ```swift
  static func twoMDMRows(environment: EnvironmentProfiles) -> [DoctorRow]
  static func oldKeyRows(environment: EnvironmentProfiles, config: ReportConfig) -> [DoctorRow]
  static func unknownSlotProfileRows(
      environment: EnvironmentProfiles, listed: [String]?) -> [DoctorRow]
  static func profileSharedRows(
      profile: String, environment: EnvironmentProfiles,
      others: [(workspace: String, environment: EnvironmentProfiles)]) -> [DoctorRow]
  static func platformHostRows(
      profile: String, environment: EnvironmentProfiles,
      hosts: (jamfPro: String?, platform: String?)?) -> [DoctorRow]
  ```

Rules (spec 3.1, 3.3; wording below is the English source, translate it):

| id | When | Severity | Title / detail |
|---|---|---|---|
| `environment.two_mdms` | block names both `jamf_pro` and `jamf_school` | `.fail` | "One environment has one MDM" / "profiles names both jamf_pro and jamf_school, so collect refuses to run. Keep one and add the other as a workspace of its own." |
| `environment.old_keys` | block present and any of `jamf_cli.profile`, `protect.enabled`, `protect.profile`, `school_cli.enabled`, `school_cli.profile` in the file | `.suggest` | "Old profile keys are not read" / "While profiles is set these keys are not read: <list>. Delete the lines when every Mac sharing this workspace runs this version." |
| `environment.unknown_profile` | a filled `platform` or `protect` slot names a profile `config list` does not list (skip when the list is nil: could not ask) | `.warn` | "profiles.<slot> names a profile jamf-cli does not have" / "'<name>' is not in jamf-cli's profiles, so <Platform API reports / Jamf Protect> fail on every run." |
| `environment.profile_shared` | another workspace on this Mac names the same profile in an add-on slot (`platform`, `protect`, `security_cloud`) | `.fail` | "Two environments collect one tenant" / "'<name>' is profiles.<slot> here and in '<other>'. Every rollup counts that tenant twice." (Doctor only: collect does not refuse, spec 3.1) |
| `environment.platform_host` | `platform` names another profile than `jamf_pro` and the hosts differ | `.warn` | "profiles.platform reaches a different Jamf Pro" / "'<platform>' reaches <host> and '<jamf_pro>' reaches <host>, so Platform API reports are skipped. Choose the Platform profile for this Jamf Pro." The hosts appear only in this row, which stays on this Mac (spec 3.1, the P3 warn line names profiles only). Unknown hosts give no row. |

Live wrappers: `listed` from `ProfileService.listJamfCLIProfiles(scheduleCounts: [:])?.map(\.name)`; `others` from every workspace folder under the workspaces root except this one (`ProfileService.discoverLocal` or the folder listing the sidebar uses; read each `config.yaml` with `ConfigLoader.load`, skipping any that does not decode); `hosts` from `PlatformHostCheck.live(jamfPro, platform, bin)` only when `bin = ExecutableLocator.locate("jamf-cli")` exists and the platform slot is a separate profile. Doctor runs off the main actor today; keep it there.

- [ ] **Step 1: Write the failing tests** — one per row, each with a positive and a silent case, through the pure functions:

```swift
import XCTest
@testable import JamfReports

final class EnvironmentDoctorRowsTests: XCTestCase {
    private func env(_ yaml: String, ws: String = "ws") throws -> (EnvironmentProfiles, ReportConfig) {
        let config = try ConfigLoader.loadFromString(yaml)
        return (EnvironmentProfiles.resolve(config: config, workspace: ws), config)
    }

    func testTwoMDMsFail() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  jamf_school: ws\n")
        XCTAssertEqual(ConfigDoctorService.twoMDMRows(environment: e).map(\.id),
                       ["environment.two_mdms"])
        let (one, _) = try env("profiles:\n  jamf_pro: ws\n")
        XCTAssertTrue(ConfigDoctorService.twoMDMRows(environment: one).isEmpty)
    }

    func testOldKeysUnderABlockAreNamed() throws {
        let (e, c) = try env("profiles:\n  jamf_pro: ws\nprotect:\n  enabled: true\n  profile: p\n")
        let rows = ConfigDoctorService.oldKeyRows(environment: e, config: c)
        XCTAssertEqual(rows.map(\.id), ["environment.old_keys"])
        XCTAssertTrue(rows[0].detail.contains("protect.profile"))
        let (legacy, lc) = try env("protect:\n  enabled: true\n  profile: p\n")
        XCTAssertTrue(ConfigDoctorService.oldKeyRows(environment: legacy, config: lc).isEmpty,
                      "without a block the old keys are live")
    }

    func testASlotProfileJamfCLIDoesNotListWarns() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  platform: ws-API\n")
        XCTAssertEqual(ConfigDoctorService.unknownSlotProfileRows(
            environment: e, listed: ["ws"]).map(\.id), ["environment.unknown_profile"])
        XCTAssertTrue(ConfigDoctorService.unknownSlotProfileRows(
            environment: e, listed: ["ws", "ws-API"]).isEmpty)
        XCTAssertTrue(ConfigDoctorService.unknownSlotProfileRows(
            environment: e, listed: nil).isEmpty, "could not ask: no row")
    }

    func testAProfileInTwoEnvironmentsFails() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  protect: shared-P\n")
        let (o, _) = try env("profiles:\n  jamf_pro: other\n  protect: shared-P\n", ws: "other")
        XCTAssertEqual(ConfigDoctorService.profileSharedRows(
            profile: "ws", environment: e, others: [("other", o)]).map(\.id),
            ["environment.profile_shared"])
        XCTAssertTrue(ConfigDoctorService.profileSharedRows(
            profile: "ws", environment: e, others: []).isEmpty)
    }

    func testAPlatformSlotOnAnotherJamfProNamesBothHosts() throws {
        let (e, _) = try env("profiles:\n  jamf_pro: ws\n  platform: ws-API\n")
        let rows = ConfigDoctorService.platformHostRows(
            profile: "ws", environment: e,
            hosts: ("https://a.jamfcloud.com", "https://b.jamfcloud.com"))
        XCTAssertEqual(rows.map(\.id), ["environment.platform_host"])
        XCTAssertTrue(rows[0].detail.contains("a.jamfcloud.com"))
        XCTAssertTrue(rows[0].detail.contains("b.jamfcloud.com"))
        XCTAssertTrue(ConfigDoctorService.platformHostRows(
            profile: "ws", environment: e,
            hosts: ("https://a.jamfcloud.com", "https://a.jamfcloud.com")).isEmpty)
        XCTAssertTrue(ConfigDoctorService.platformHostRows(
            profile: "ws", environment: e, hosts: nil).isEmpty)
    }
}
```

- [ ] **Step 2: Run, expect a compile failure.**
- [ ] **Step 3: Implement** the five pure functions and their live wrappers in `ConfigDoctorService+Environment.swift`, following `ConfigDoctorService+Products.swift`'s pattern. Use `PlatformHostCheck.verdict` and `PlatformTwin.host(of:)` for the comparison and the hosts shown; text from the file goes through `ConfigSchema.displayText`. Wire the live wrappers into `run` after `profileOwnerRows`. Add the strings and translations.
- [ ] **Step 4: Run** `swift test --filter 'EnvironmentDoctorRows|ConfigDoctor|LocalizationCatalog'`, then the full suite.
- [ ] **Step 5: Commit** — `git commit -m "Add Config Doctor rows for the profiles block"`

---

### Task 4: `platform.twin` says to keep the OAuth workspace (D21)

**Files:**
- Modify: `app/Sources/JamfReports/Services/ConfigDoctorService+Products.swift` (`platformTwinRows`, ~163-171)
- Modify: `app/Localization/Localizable.xcstrings`
- Test: `app/Tests/JamfReportsTests/PlatformTwinTests.swift` (~237-258)

- [ ] **Step 1: Update the tests** to assert the new hint names the OAuth workspace as the one to keep and mentions `profiles.platform`:

```swift
        XCTAssertTrue(row.hint?.contains("profiles.platform") == true)
        XCTAssertTrue(row.hint?.contains("Keep '\(twin)'") == true, "the OAuth workspace is kept")
```

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.** Keep the id, severity, title and detail. New hint (English source):

  "Keep '<twin>' as the workspace: it runs the Jamf Pro commands. Add '<platform>' to it as profiles.platform in its config.yaml (`profiles:` with `jamf_pro: <twin>` and `platform: <platform>`), then exclude '<platform>' under Automation > Excluded profiles. Nothing is changed for you."

  Run `sync-strings.zsh`, write the six translations (following the old hint's wording in each language where the sentences are the same), keep state `translated`, `--prune-stale` the old key.
- [ ] **Step 4: Run** `swift test --filter 'PlatformTwin|LocalizationCatalog'`.
- [ ] **Step 5: Commit** — `git commit -m "Point the twin hint at one environment with the OAuth profile"`

---

### Task 5: `EnvironmentCardState`

**Files:**
- Create: `app/Sources/JamfReports/Services/EnvironmentCardState.swift`
- Test: `app/Tests/JamfReportsTests/EnvironmentCardStateTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct EnvironmentCardState: Equatable, Sendable {
      struct Row: Equatable, Sendable, Identifiable {
          let slot: ProfilesConfigWriter.Slot
          let product: String          // display name, localized
          let profile: String?         // nil: the slot is empty
          let authMethod: String?
          let level: String?           // "environment", "tenant", nil
          let newestSnapshot: Date?
          let pinNeedsConfirming: Bool
          var canRemove: Bool { profile != nil && slot != .jamfPro && slot != .jamfSchool }
          var id: String { slot.rawValue }
      }
      let workspace: String
      let fromBlock: Bool               // false: derived from the old keys
      let rows: [Row]

      static func build(
          workspace: String, environment: EnvironmentProfiles,
          resolve: (String) -> ProfileAuthMethod.Resolved?,
          newest: (ProfilesConfigWriter.Slot) -> Date?,
          drifted: (SharedConfigPin.Key) -> Bool) -> EnvironmentCardState
  }
  ```
  Rows, in order: the MDM (Jamf Pro or Jamf School, whichever the environment has), Platform API (Jamf Pro environments only), Jamf Protect. Security Cloud is not shown (P12). `newest` maps a slot to its kinds' newest snapshot (MDM: `computers` or `school-devices`; Platform: the newest of `platformOnlyKinds`; Protect: the newest `protect-*`); the live caller uses `SourcesView.newestSnapshots` data. `drifted` is `SharedConfigPin.check(profile:).isDrifted`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import JamfReports

final class EnvironmentCardStateTests: XCTestCase {
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock(); private var names: [String] = []
        func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    private func state(
        _ yaml: String, ws: String = "ws", drifted: Set<SharedConfigPin.Key> = [],
        asked: Asked = Asked()
    ) throws -> EnvironmentCardState {
        let environment = EnvironmentProfiles.resolve(
            config: try ConfigLoader.loadFromString(yaml), workspace: ws)
        return EnvironmentCardState.build(
            workspace: ws, environment: environment,
            resolve: { asked.add($0); return .init(authMethod: "oauth2", isTenantLevel: false) },
            newest: { _ in nil }, drifted: { drifted.contains($0) })
    }

    func testAnOldShapeWorkspaceShowsItsDerivedSlots() throws {
        let card = try state("protect:\n  enabled: true\n  profile: ws-P\n")
        XCTAssertFalse(card.fromBlock)
        XCTAssertEqual(card.rows.map(\.slot), [.jamfPro, .platform, .protect])
        XCTAssertEqual(card.rows.map(\.profile), ["ws", nil, "ws-P"])
    }

    func testABlockMarksAHeldPlatformSlot() throws {
        let card = try state("profiles:\n  jamf_pro: ws\n  platform: ws-API\n",
                             drifted: [.platformProfile])
        XCTAssertTrue(card.fromBlock)
        XCTAssertEqual(card.rows.first { $0.slot == .platform }?.pinNeedsConfirming, true)
    }

    func testASchoolEnvironmentHasNoPlatformRow() throws {
        let card = try state("school_cli:\n  enabled: true\n")
        XCTAssertEqual(card.rows.map(\.slot), [.jamfSchool, .protect])
    }

    func testTheMDMRowCannotBeRemoved() throws {
        let card = try state("profiles:\n  jamf_pro: ws\n  protect: ws-P\n")
        XCTAssertEqual(card.rows.first { $0.slot == .jamfPro }?.canRemove, false)
        XCTAssertEqual(card.rows.first { $0.slot == .protect }?.canRemove, true)
    }

    func testOnlyFilledSlotsAreResolved() throws {
        let asked = Asked()
        _ = try state("profiles:\n  jamf_pro: ws\n", asked: asked)
        XCTAssertEqual(asked.all, ["ws"])
    }
}
```

If `ProfileAuthMethod.Resolved`'s memberwise initializer needs more arguments, pass the defaults the other tests use.
- [ ] **Step 2: Run, expect a compile failure.**
- [ ] **Step 3: Implement** as a pure function; product names through `L(…)` with translations.
- [ ] **Step 4: Run** `swift test --filter 'EnvironmentCardState|LocalizationCatalog'`.
- [ ] **Step 5: Commit** — `git commit -m "Add the Environment card's model"`

---

### Task 6: The Environment card on Data Sources

**Files:**
- Create: `app/Sources/JamfReports/Views/EnvironmentCard.swift`
- Modify: `app/Sources/JamfReports/Views/SourcesView.swift` (body, ~45-123; `reloadSourcesPlan`, ~737-780)

**Interfaces:**
- Consumes: `EnvironmentCardState` (Task 5), `ProfilesConfigWriter.save` (Task 1), `CLIDoctorService.run(profile:)`, `Notification.Name.showAddSheet` with `userInfo["product"]` (`AddSheetPlan.NewProduct`).

Layout (spec 6, D23), using the house components (`Card(padding: 18)`, `Kicker`/`SectionHeader`, `Pill`, `PNPButton(style: .ghost, size: .sm)`; `ConnectionCard.memberRow` and `ProtectProductControl` are the templates):
- Header: "Environment" and the workspace name; a caption when `fromBlock` is false: "From this workspace's settings. The first change writes a profiles block to config.yaml."
- One row per `Row`: product, profile (or "Not set"), auth method and level Pills, newest snapshot as a relative date, a warn Pill "Confirm in Config Doctor" when `pinNeedsConfirming`.
- Actions per row: **Check** (filled rows; runs `CLIDoctorService().run(profile:)` for that profile and shows its verdict inline in the row); **Remove** (when `canRemove`; `confirmationDialog` naming the profile and saying the jamf-cli profile and snapshots stay; calls `ProfilesConfigWriter.save(slot, to: nil, workspace:)` off the main actor, then reloads); **Add** (empty Platform row: posts `.showAddSheet` with `product: AddSheetPlan.NewProduct.platformAPI`; empty Protect row: opens the existing `ProductConnectSheetView`, as `additionalProductsCard` does); **Change** (filled Platform row: same as Add).
- Errors from a write show as a caption in `Theme.Colors.danger` under the card, as `ConnectionCard.actionError` does.
- Demo mode: rows from `DemoData` (one Jamf Pro and one Protect row), every action disabled with `.help(DemoData.liveOnlyHelp)`.
- Placement: directly under `header`, above the `cliCard` row. The `additionalProductsCard` Protect control stays for now (P8 consolidates it).

- [ ] **Step 1:** Build `EnvironmentCardState` inside `reloadSourcesPlan`'s existing `Task.detached` and publish it with the plan (same profile/demo guard). No new main-actor work.
- [ ] **Step 2:** Write `EnvironmentCard` and place it. Skeleton (match `ConnectionCard`'s spacing and fonts; fill the row body with the Pills and buttons above):

```swift
import SwiftUI

/// Data Sources' Environment card (spec 6, D23): one row per product slot, with Check and
/// Remove. Add and Change go through the Add sheet until P5 and P6.
struct EnvironmentCard: View {
    @Environment(WorkspaceStore.self) private var workspace
    let state: EnvironmentCardState
    let onChanged: () -> Void
    @State private var pendingRemoval: EnvironmentCardState.Row?
    @State private var checks: [String: String] = [:]
    @State private var actionError: String?

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                header
                ForEach(state.rows) { row in rowView(row) }
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(Theme.Colors.danger)
                }
            }
        }
        .confirmationDialog(
            L("Remove from this environment?"), isPresented: removalBinding, presenting: pendingRemoval
        ) { row in
            Button(L("Remove"), role: .destructive) { remove(row) }
        } message: { row in
            Text(L("The jamf-cli profile \(row.profile ?? "") and its snapshots stay."))
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private func remove(_ row: EnvironmentCardState.Row) {
        let profile = state.workspace
        Task {
            do {
                try await Task.detached {
                    try ProfilesConfigWriter.save(row.slot, to: nil, workspace: profile)
                }.value
                actionError = nil
                onChanged()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
    // header, rowView(_:), check(_:), add(_:) follow the layout above.
}
```

Add a `#if DEBUG` `#Preview` with a three-row state, `.preferredColorScheme(.dark)` and a frame of `PageScaffold.minSupportedWidth`.
- [ ] **Step 3:** Strings and translations; `swift build --build-tests`; `swift test --filter 'LocalizationCatalog|LocalizationLayout|AccessibilitySweep|LightModeRender'` (whichever exist), then the full suite.
- [ ] **Step 4: Visual check.** Render the preview with the Xcode MCP `RenderPreview` (switch to the `JamfReportsKit` scheme first) at `PageScaffold.minSupportedWidth`; save the PNG beside the report. Check no row truncates its action buttons or overflows horizontally.
- [ ] **Step 5: Commit** with the body line `DRAFT — needs visual verification` — `git commit -m "Show the environment's products on Data Sources"`

---

### Task 7: Docs and #305

**Files:** `CLAUDE.md`, `AGENTS.md` (identical edits), `CHANGELOG.md`, the spec (P4 row status only if the code differs from it).

- [ ] **Step 1:** CLAUDE.md/AGENTS.md, in "profiles config": `ProfilesConfigWriter` is the one writer of the block (first write seeds the derived slots, old keys stay, the operator's write confirms the pin); the Protect writers write `profiles.protect` under a block; the five `environment.*` Doctor rows with ids; the Environment card (rows, Check, Remove; Add and Change through the Add sheet). Replace "the block is hand-written until P4".
- [ ] **Step 2:** CHANGELOG Unreleased, plain language: Data Sources lists the environment's products and can check or remove one; Config Doctor explains a profiles block that cannot work; Jamf Protect can be connected and disconnected after a profiles block exists; the Platform API twin suggestion now says to keep the Jamf Pro workspace. Add `(#305)`.
- [ ] **Step 3:** Verify (`swift build --build-tests`, full `swift test`, both totals), commit — `git commit -m "Document the Environment card and the profiles writer"`.
- [ ] **Step 4 (controller, after merge approval):** on #305's follow-ups comment, check off "Re-resolve the environment pin-aware…" with the moot reason from "Not in this plan", and check off the P4 items this plan delivers in the 2026-11-03 comment.
