# Environment model P3: Platform kinds on their own profile — Implementation Plan

Status: shipped in 2.12 on `dev/2-12-0`. The boxes below are the original task list and were not ticked as the work landed; `CLAUDE.md` describes what was built.

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Under a `profiles:` block, run the Platform-only kinds with the `platform` slot's profile, pin that slot, check it reaches the same Jamf Pro, and judge the collect's dead verdicts on the Jamf Pro profile alone. A workspace without the block collects exactly as today.

**Architecture:** One seam, `PlatformRoute` (from `EnvironmentProfiles`), answers who collects the Platform-only kinds; `ReportEngine.collect`, the Data Sources plan and the freshness strip all read it. `collect` keeps its order and its single `CollectRouter` closure: it reads the route from the config it already loads, so the router, its closures and the golden test do not change. Verdicts (D20) filter the outcomes to the Jamf Pro profile's group before the existing auth-dead and outage checks.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, XCTest. No new dependency.

**Spec:** `docs/superpowers/specs/2026-10-19-environment-model-design.md`, sections 3.1, 3.2, 3.3, 4.1, 7.1, 7.2, and decisions D18, D19, D20. Read 7.2 before Task 5.

## Global Constraints

- macOS 15 floor; CI builds with Swift 6.1, 6.2 and 6.4. Run `swift build --build-tests` in the `ci-macos15-xcode16.4` VM (`/vm-test`) before pushing.
- No new Swift package.
- Functions ≤100 lines, cyclomatic complexity ≤8, lines ≤100 characters, no force unwrap.
- Tests never run the installed jamf-cli. A stub must not be named `jamf-cli` (`CLIBridge.codesignGate`).
- A workspace without `profiles:` produces the same command lines and log lines as before. `EnvironmentProfilesGoldenTests` stays green unchanged.
- `[skip]` and `[plan]` wording: a reason text follows `[skip] <kind>: ` and is the `[plan] skipping N sources (<reason>)` label.
- CHANGELOG: plain language, no class names (CLAUDE.md "Changelog and release-notes style").
- Every edit: run `git log --oneline origin/main..HEAD -- <path>` first and state the count (CLAUDE.md "Anti-churn discipline").

## Not in this plan (spec D19)

Gate lift into the router (P8), one environment finalize (P9), whole-product `collect_skip` (dropped), a new `[partial] <product>: no source landed` line: the existing `unlandedSourcesLine` already names failed Platform kinds and `CollectHonestyWatcher` reads them per kind, so no new line is needed (Task 8 corrects spec 7.2 to say so).

## File map

| File | Change |
|---|---|
| `app/Sources/JamfReports/Services/EnvironmentProfiles.swift` | `PlatformRoute`; `platformRoute(platformPinAllows:)`; drop `resolve`'s `auth:` |
| `app/Sources/JamfReports/Services/SharedConfigPin.swift` | `profiles.platform` key, held at first sight when it differs from the workspace; `platformAllowed(profile:)` |
| `app/Sources/JamfReports/Engine/ReportEngine.swift` | `collectCommandMatrix(platformProfile:)`; `collect` reads the route; verdict group |
| `app/Sources/JamfReports/Engine/ReportEngine+CollectPlan.swift` | `CollectSkipReason.platformUnavailable`; `CollectPlanInputs.platformUnavailable` |
| `app/Sources/JamfReports/Services/PlatformHostCheck.swift` (new) | Host comparison and its live lookup |
| `app/Sources/JamfReports/Services/WorkspaceStore+Refresh.swift`, `WorkspaceStore+Automation.swift` | `expectedKinds` follows the route |
| `app/Sources/JamfReports/Services/CollectSourcesPlan.swift`, `Views/SourcesView.swift` | Data Sources plan follows the route |
| Tests | `EnvironmentProfilesTests`, `SharedConfigPinTests`, `CollectPlanTests`, new `PlatformRouteCollectTests`, new `PlatformHostCheckTests`, `CollectSourcesPlanTests`, `DataFreshnessHealthTests` (whichever suite holds `expectedKinds` tests) |
| `CLAUDE.md`, `AGENTS.md`, `config.example.yaml`, `CHANGELOG.md`, the spec | Task 8 |

---

### Task 1: `PlatformRoute` and the unused `auth:` parameter

**Files:**
- Modify: `app/Sources/JamfReports/Services/EnvironmentProfiles.swift:50-79`
- Test: `app/Tests/JamfReportsTests/EnvironmentProfilesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum PlatformRoute: Equatable, Sendable {
      case workspaceProfile
      case profile(String)
      case unavailable(String)
  }
  extension EnvironmentProfiles {
      static let noPlatformReason: String
      static let heldPlatformReason: String
      func platformRoute(platformPinAllows: Bool) -> PlatformRoute
  }
  static func EnvironmentProfiles.resolve(config: ReportConfig?, workspace: String) -> EnvironmentProfiles
  ```

- [ ] **Step 1: Update the test helper and the legacy-platform test, add route tests**

In `EnvironmentProfilesTests`, replace the helper and `testProWorkspaceOnAPlatformProfileFillsJamfProAndPlatform`:

```swift
    private func resolve(_ yaml: String) throws -> EnvironmentProfiles {
        EnvironmentProfiles.resolve(config: try ConfigLoader.loadFromString(yaml), workspace: ws)
    }

    /// D19: an old-shape file derives no `platform` slot, whatever the profile's auth method.
    /// Its Platform kinds run on the workspace's own profile, as before (`.workspaceProfile`).
    func testAnOldShapeDerivesNoPlatformSlot() throws {
        let environment = try resolve("jamf_cli:\n  data_dir: data\n")
        XCTAssertEqual(environment, EnvironmentProfiles(jamfPro: ws))
        XCTAssertNil(environment.platform)
        XCTAssertEqual(environment.platformRoute(platformPinAllows: true), .workspaceProfile)
        XCTAssertEqual(environment.platformRoute(platformPinAllows: false), .workspaceProfile,
                       "no slot, so nothing to hold")
    }

    func testABlockWithAPlatformSlotRoutesToIt() throws {
        let environment = try resolve("profiles:\n  jamf_pro: ws\n  platform: ws-API\n")
        XCTAssertEqual(environment.platformRoute(platformPinAllows: true), .profile("ws-API"))
    }

    func testABlockWithoutAPlatformSlotLeavesThePlatformKindsOut() throws {
        let environment = try resolve("profiles:\n  jamf_pro: ws\n")
        XCTAssertEqual(environment.platformRoute(platformPinAllows: true),
                       .unavailable(EnvironmentProfiles.noPlatformReason))
    }

    func testAHeldPlatformSlotLeavesThePlatformKindsOut() throws {
        let environment = try resolve("profiles:\n  jamf_pro: ws\n  platform: ws-API\n")
        XCTAssertEqual(environment.platformRoute(platformPinAllows: false),
                       .unavailable(EnvironmentProfiles.heldPlatformReason))
    }
```

Also remove `auth:` from `testProWorkspaceOverOAuthFillsJamfProWithTheWorkspace` (`try resolve("jamf_cli:\n  data_dir: data\n")`).

- [ ] **Step 2: Run, expect a compile failure**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head`
Expected: errors for `platformRoute`, `noPlatformReason`, `heldPlatformReason`.

- [ ] **Step 3: Implement**

In `EnvironmentProfiles.swift`, change `resolve` to drop the parameter and its one use:

```swift
    static func resolve(config: ReportConfig?, workspace: String) -> EnvironmentProfiles {
```

and delete the line `if auth?.method?.isPlatform == true { environment.platform = recorded }`. Update the type's doc comment where it mentions `auth`.

Add below the struct:

```swift
/// Who collects the Platform-only kinds (`ReportEngine.platformOnlyKinds`), spec 3.2 and D19.
/// The one answer for `collect`, the Data Sources plan and the freshness strip.
enum PlatformRoute: Equatable, Sendable {
    /// No `profiles:` block: the workspace's own profile, skipped by its auth method as before.
    case workspaceProfile
    /// The `platform` slot's profile.
    case profile(String)
    /// The block leaves them out; the text is the `[skip]` and `[plan]` reason.
    case unavailable(String)
}

extension EnvironmentProfiles {
    static let noPlatformReason = "no Platform API profile in this environment"
    static let heldPlatformReason =
        "profiles.platform changed in the shared config.yaml and is not confirmed on this Mac"

    /// `platformPinAllows` is `SharedConfigPin.platformAllowed`; it matters only under a block.
    func platformRoute(platformPinAllows: Bool) -> PlatformRoute {
        guard source == .profilesBlock else { return .workspaceProfile }
        guard let platform else { return .unavailable(Self.noPlatformReason) }
        guard platformPinAllows else { return .unavailable(Self.heldPlatformReason) }
        return .profile(platform)
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `cd app && swift test --filter EnvironmentProfiles 2>&1 | tail -5`
Expected: all pass, the golden suite included.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Services/EnvironmentProfiles.swift app/Tests/JamfReportsTests/EnvironmentProfilesTests.swift
git commit -m "Route Platform kinds through one PlatformRoute and drop resolve's auth:"
```

---

### Task 2: Pin `profiles.platform` (D18)

**Files:**
- Modify: `app/Sources/JamfReports/Services/SharedConfigPin.swift` (struct fields, `Key`, `text`, `copy`, `current`, `unconfirmedKeys`, `init(from:)`, a new `platformAllowed`)
- Test: `app/Tests/JamfReportsTests/SharedConfigPinTests.swift`

**Interfaces:**
- Produces: `SharedConfigPin.Key.platformProfile` (raw value `"profiles.platform"`), `static func SharedConfigPin.platformAllowed(profile: String, appSupport: URL = AppSupport.directory()) -> Bool`

- [ ] **Step 1: Write the failing tests**

Add to `SharedConfigPinTests`:

```swift
    private func writeBlock(platform: String) throws {
        let body = """
        shared_workspace:
          enabled: true
        profiles:
          jamf_pro: "\(profile)"
          platform: "\(platform)"
        """
        try body.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    /// D18: a Platform profile other than the workspace's own is an address this Mac would send
    /// `-p` to, so it waits for one Confirm, as `output.timestamp_authority` does.
    func testAPlatformSlotNamingAnotherProfileIsHeldAtFirstSight() throws {
        try writeBlock(platform: "\(profile)-API")
        XCTAssertEqual(check().drifts.map(\.key), [.platformProfile])
        XCTAssertFalse(SharedConfigPin.platformAllowed(profile: profile, appSupport: appSupport))
        try confirmAll()
        XCTAssertTrue(SharedConfigPin.platformAllowed(profile: profile, appSupport: appSupport))
    }

    func testAPlatformSlotNamingTheWorkspaceIsTrustedAtFirstSight() throws {
        try writeBlock(platform: profile)
        XCTAssertTrue(check().drifts.isEmpty)
        XCTAssertTrue(SharedConfigPin.platformAllowed(profile: profile, appSupport: appSupport))
    }

    func testAPeerChangingAConfirmedPlatformSlotIsDrift() throws {
        try writeBlock(platform: "\(profile)-API")
        try confirmAll()
        try writeBlock(platform: "other-tenant-API")
        XCTAssertFalse(SharedConfigPin.platformAllowed(profile: profile, appSupport: appSupport))
    }

    /// A pin written before the key existed adopts it at first sight, with the same hold.
    func testAnOlderPinAdoptsThePlatformKeyWithTheHold() throws {
        try writeConfig()
        _ = check()
        try writeBlock(platform: "\(profile)-API")
        XCTAssertTrue(check().drifts.map(\.key).contains(.platformProfile))
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head`
Expected: `platformProfile` and `platformAllowed` not found.

- [ ] **Step 3: Implement**

1. Field, after `timestampAuthorityHash`:
   ```swift
       /// `profiles.platform` as the decoder reads it; "" without a `profiles:` block.
       var platformProfile: String = ""
   ```
2. `Key`: add `case platformProfile = "profiles.platform"` after `protectProfile`; in `text(of:)` add `case .platformProfile: pin.platformProfile`; in `copy(from:into:)` add `case .platformProfile: pin.platformProfile = source.platformProfile`.
3. `current(workspace:)`: after the `protectProfile` line,
   ```swift
        let platformProfile = ConfigLoader.rawValue(at: ["profiles"], in: root) is [String: Any]
            ? raw("profiles", "platform") : nil
   ```
   and pass, last in the initializer:
   ```swift
            timestampAuthorityHash: authority.isEmpty ? "" : SharedConfigPin.sha256Hex(authority),
            platformProfile: (ConfigLoader.textValue(platformProfile) ?? "")
                .trimmingCharacters(in: .whitespaces)
   ```
4. `unconfirmedKeys`: before the `return`,
   ```swift
        // D18: a Platform profile other than the workspace's own is held until confirmed.
        let workspaceName = ProfileName.name(fromPathComponent: workspace.lastPathComponent)
        if !current.platformProfile.isEmpty, current.platformProfile != workspaceName {
            waiting.append(.platformProfile)
        }
   ```
5. `init(from:)`: `platformProfile = try c.decodeIfPresent(String.self, forKey: .platformProfile) ?? ""`. Do not add it to the `held` list (that list is pins from before `pinnedKeys`).
6. Beside `protectAllowed`:
   ```swift
    /// False when `profiles.platform` differs from the pinned one or waits for a Confirm: the
    /// Platform-only kinds are not collected (`PlatformRoute.unavailable`).
    static func platformAllowed(profile: String, appSupport: URL = AppSupport.directory()) -> Bool {
        !check(profile: profile, appSupport: appSupport).isDrifted(.platformProfile)
    }
   ```

- [ ] **Step 4: Run the suites**

Run: `cd app && swift test --filter 'SharedConfigPin|ConfigDoctor' 2>&1 | tail -5`
Expected: pass. If a Doctor test lists every `Key`, add the new key to its expectation.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Services/SharedConfigPin.swift app/Tests/JamfReportsTests/SharedConfigPinTests.swift
git commit -m "Pin profiles.platform and hold another profile until confirmed"
```

---

### Task 3: Matrix per family and the unavailable skip

**Files:**
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift:2596` (`collectCommandMatrix`)
- Modify: `app/Sources/JamfReports/Engine/ReportEngine+CollectPlan.swift:10-127`
- Test: `app/Tests/JamfReportsTests/CollectPlanTests.swift`

**Interfaces:**
- Consumes: `PlatformRoute` (Task 1) — not yet.
- Produces:
  ```swift
  static func collectCommandMatrix(profile: String, platformProfile: String? = nil, staleDays: Int)
      -> [(args: [String], kind: String)]
  case CollectSkipReason.platformUnavailable(String)
  CollectPlanInputs.platformUnavailable: String?   // `var`, default nil
  ```

- [ ] **Step 1: Write the failing tests**

```swift
    func testWithoutAPlatformProfileTheMatrixIsUnchanged() {
        XCTAssertEqual(
            ReportEngine.collectCommandMatrix(profile: "ws", staleDays: 30).map(\.args),
            ReportEngine.collectCommandMatrix(
                profile: "ws", platformProfile: "ws", staleDays: 30).map(\.args))
    }

    func testOnlyThePlatformKindsTakeThePlatformProfile() {
        for (args, kind) in ReportEngine.collectCommandMatrix(
            profile: "ws", platformProfile: "ws-API", staleDays: 30) {
            let expected = ReportEngine.platformOnlyKinds.contains(kind) ? "ws-API" : "ws"
            XCTAssertEqual(Array(args.prefix(2)), ["-p", expected], kind)
        }
    }

    func testAnUnavailablePlatformSkipsOnlyThePlatformKinds() {
        var inputs = planInputs()
        inputs.platformUnavailable = EnvironmentProfiles.noPlatformReason
        let plan = ReportEngine.planCollect(
            commands: ReportEngine.collectCommandMatrix(profile: "ws", staleDays: 30),
            inputs: inputs, lastRun: { _ in nil })
        for item in plan {
            if ReportEngine.platformOnlyKinds.contains(item.kind) {
                XCTAssertEqual(item.skip, .platformUnavailable(EnvironmentProfiles.noPlatformReason))
            } else {
                XCTAssertNotEqual(item.skip, .platformUnavailable(EnvironmentProfiles.noPlatformReason))
            }
        }
        let lines = ReportEngine.collectPlanLines(profile: "ws", plan: plan, deviceScan: .due)
        XCTAssertTrue(lines.contains { $0.contains(
            "sources (no Platform API profile in this environment)") }, "\(lines)")
    }
```

If `CollectPlanTests` has no `planInputs()` helper, add one:

```swift
    private func planInputs() -> ReportEngine.CollectPlanInputs {
        ReportEngine.CollectPlanInputs(
            tiers: Set(CollectionTier.allCases), force: true, skipExpensive: false,
            nonPlatformAuth: nil, tenantLevel: false, collectSkip: [],
            dashboardSupported: true, installedVersion: "1.35.0", now: Date())
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head`

- [ ] **Step 3: Implement**

`collectCommandMatrix`: add `platformProfile: String? = nil`, and after building the array map it so a Platform-only kind takes that profile. The `-p` value is always `args[1]`:

```swift
    static func collectCommandMatrix(
        profile: String, platformProfile: String? = nil, staleDays: Int
    ) -> [(args: [String], kind: String)] {
        let matrix = jamfProCommandMatrix(profile: profile, staleDays: staleDays)
        guard let platformProfile, platformProfile != profile else { return matrix }
        return matrix.map { command in
            guard platformOnlyKinds.contains(command.kind) else { return command }
            var args = command.args
            args[1] = platformProfile
            return (args, command.kind)
        }
    }
```

Rename the existing body to `private static func jamfProCommandMatrix(profile:staleDays:)` unchanged. Callers (`CollectSourcesPlan.swift:71`, `CommandCatalog.swift:177`) compile unchanged.

`ReportEngine+CollectPlan.swift`:
- `CollectSkipReason`: `case platformUnavailable(String)`; `skipDetail` returns the string; `planLabel` returns the string.
- `CollectPlanInputs`: add one stored property after `now`: `var platformUnavailable: String? = nil`. The others stay `let`; the memberwise initializer gains a defaulted last argument, so every existing call compiles.
- `profileSkip`, first check:
  ```swift
        if let reason = inputs.platformUnavailable, platformOnlyKinds.contains(kind) {
            return .platformUnavailable(reason)
        }
  ```

- [ ] **Step 4: Run**

Run: `cd app && swift test --filter 'CollectPlan|CommandCatalog|CLIHelpContract' 2>&1 | tail -5`
Expected: pass. `CLIHelpContractTests` must still see every argv.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Engine/ReportEngine.swift app/Sources/JamfReports/Engine/ReportEngine+CollectPlan.swift app/Tests/JamfReportsTests/CollectPlanTests.swift
git commit -m "Give the Platform kinds their own -p and a skip for a missing profile"
```

---

### Task 4: `collect` reads the route

**Files:**
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift:2141-2258` (inside `collect`)
- Create test: `app/Tests/JamfReportsTests/PlatformRouteCollectTests.swift`

**Interfaces:**
- Consumes: `PlatformRoute`, `platformRoute(platformPinAllows:)` (Task 1); `SharedConfigPin.platformAllowed` (Task 2); `collectCommandMatrix(platformProfile:)`, `CollectPlanInputs.platformUnavailable` (Task 3).
- Produces: a private helper used by Task 5 and 6:
  ```swift
  /// The Platform route for this run and the profile its kinds run as (`profile` when they
  /// run on the workspace's own or are skipped).
  static func platformRoute(config: ReportConfig?, workspace: WorkspaceID) -> PlatformRoute
  ```

- [ ] **Step 1: Write the failing test file**

```swift
import XCTest
@testable import JamfReports

/// P3 (spec 3.2, D19): under a `profiles:` block the Platform-only kinds run as the `platform`
/// slot's profile, and without the block exactly as before. A stub answers every command and
/// logs its argv; `config list` names both profiles.
final class PlatformRouteCollectTests: XCTestCase {
    private var root: URL!
    private var answers: URL!
    private let ws = "routecollect"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Route-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(ws, isDirectory: true),
            withIntermediateDirectories: true)
        answers = root.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        ProfileAuthMethod.invalidateCache()
        try answer("config", """
            [{"name":"\(ws)","auth-method":"oauth2"},
             {"name":"\(ws)-API","auth-method":"platform","environment-id":"e1"}]
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// NOT named `jamf-cli`. `answers/<name>` and `<name>.exit` answer `config list` (config),
    /// any command run as `-p <ws>-API` (platform) and any other (pro); the default is `[]`.
    private func makeStub() throws -> URL {
        let url = root.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        A="\(answers.path)"
        printf '%s\\n' "$*" >> "$A/calls.log"
        emit() { f="$A/$1"; if [ -f "$f.exit" ]; then code=$(cat "$f.exit"); else code=0; fi; \\
                 if [ -f "$f" ]; then cat "$f"; else printf '[]'; fi; exit "$code"; }
        case "$*" in
          "config list"*) emit config ;;
          "-p \(ws)-API "*) emit platform ;;
          *) emit pro ;;
        esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func answer(_ name: String, _ body: String, exit code: Int? = nil) throws {
        try body.write(to: answers.appendingPathComponent(name), atomically: true, encoding: .utf8)
        if let code {
            try "\(code)".write(to: answers.appendingPathComponent("\(name).exit"),
                                atomically: true, encoding: .utf8)
        }
    }

    private func writeConfig(_ yaml: String) throws {
        let dir = try XCTUnwrap(ProfileService.workspaceURL(for: ws))
        try yaml.write(to: dir.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    private func calls() -> [String] {
        let log = (try? String(contentsOf: answers.appendingPathComponent("calls.log"),
                               encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    @discardableResult
    func collect(tiers: Set<CollectionTier> = [.inventory]) async throws -> [String] {
        let stub = try makeStub()
        let lines = Lines()
        try await ReportEngine.collect(
            workspace: WorkspaceID(validating: ws), profile: ws,
            workspacePaths: WorkspacePaths.self, tiers: tiers, force: true,
            locateJamfCLI: { stub }, onLine: { lines.add($0.text) })
        return lines.all
    }

    func testABlockRunsThePlatformKindsAsThePlatformProfile() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        try await collect()
        let log = calls()
        XCTAssertTrue(log.contains { $0.hasPrefix("-p \(ws)-API ") &&
            $0.contains("compliance-benchmarks list") }, "\(log)")
        XCTAssertFalse(log.contains { $0.hasPrefix("-p \(ws) ") &&
            $0.contains("compliance-") }, "\(log)")
    }

    func testThePlanNamesThePlatformProfile() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        let lines = try await collect()
        XCTAssertTrue(lines.contains("[plan] Platform API kinds run as \(ws)-API"), "\(lines)")
    }

    func testABlockWithoutPlatformSkipsThePlatformKinds() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n")
        let lines = try await collect()
        XCTAssertFalse(calls().contains { $0.contains("compliance-") })
        XCTAssertTrue(lines.contains {
            $0 == "[skip] compliance-rules: \(EnvironmentProfiles.noPlatformReason)" }, "\(lines)")
    }

    /// Without the block, a workspace whose own profile is OAuth skips the Platform kinds by
    /// its auth method, worded as before.
    func testAnOldShapeSkipsByAuthMethodAsBefore() async throws {
        try writeConfig("jamf_cli:\n  data_dir: jamf-cli-data\n")
        let lines = try await collect()
        XCTAssertTrue(lines.contains {
            $0 == "[skip] compliance-rules: requires a Platform API profile (auth-method is oauth2)"
        }, "\(lines)")
    }
}
```

No collect test covers the organization-level line: `Resolved.isOrganizationLevel` is confirmed against jamf-cli's config file, which a test process never reads, so it is always false here. `ProfileAuthMethod`'s own tests cover the flag; the line is one `if`.

The shared-pin case is covered by Task 2's tests and `platformRoute(platformPinAllows:)`; a local workspace is never pinned, so `platformAllowed` is true here.

- [ ] **Step 2: Run, expect failures**

Run: `cd app && swift test --filter PlatformRouteCollect 2>&1 | tail -15`
Expected: the first two fail (Platform kinds run as `ws`).

- [ ] **Step 3: Implement in `collect`**

Add the helper near `collect`:

```swift
    /// The Platform route for this run (spec 3.2, D19), from the config `collect` loaded.
    static func platformRoute(config: ReportConfig?, workspace: WorkspaceID) -> PlatformRoute {
        EnvironmentProfiles.resolve(config: config, workspace: workspace.name)
            .platformRoute(platformPinAllows: SharedConfigPin.platformAllowed(profile: workspace.name))
    }
```

In `collect`, replace the block from `let commands = Self.collectCommandMatrix(` through `let tenantLevel = …` with:

```swift
        let route = Self.platformRoute(config: loadedConfig, workspace: workspace)
        let platformProfile: String
        var platformUnavailable: String?
        switch route {
        case .workspaceProfile: platformProfile = profile
        case .profile(let named): platformProfile = named
        case .unavailable(let reason):
            platformProfile = profile
            platformUnavailable = reason
        }
        let commands = Self.collectCommandMatrix(
            profile: profile, platformProfile: platformProfile,
            staleDays: loadedConfig?.thresholds?.resolvedStaleDays ?? 30)
```

Keep the `stateStore`, `collectStart`, `supportsQuietFlags` lines, then:

```swift
        // Resolved once per run, not per kind — it spawns `config list`.
        let profileAuth = ProfileAuthMethod.resolve(profile: profile, binary: bin)
        if profileAuth == nil, ProfileAuthMethod.isAbsent(profile: profile, binary: bin) {
            throw Self.reportDeadCollect(.profileNotFound(profile), onLine: onLine)
        }
        // The Platform kinds' own profile decides their auth-method and level skips.
        let platformAuth = platformProfile == profile
            ? profileAuth : ProfileAuthMethod.resolve(profile: platformProfile, binary: bin)
        let nonPlatformAuth = Self.nonPlatformAuthMethod(platformAuth?.authMethod)
        let tenantLevel = platformAuth?.isTenantLevel == true
        // Spec 3.1: an organization-level profile reaches no Jamf Pro report.
        if platformProfile != profile, platformAuth?.isOrganizationLevel == true {
            platformUnavailable = "profiles.platform names an organization-level profile"
        }
```

After `Self.logCollectPlan(...)`, name the second profile when there is one (spec 7.1); a workspace without a block logs nothing new:

```swift
        if platformProfile != profile, platformUnavailable == nil {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[plan] Platform API kinds run as \(platformProfile)"))
        }
```

Pass `platformUnavailable` into `CollectPlanInputs(...)` (`inputs.platformUnavailable = platformUnavailable` on a `var`, or as the last argument). In the loop, the benchmark branch passes `profile: platformProfile` to `collectBenchmarkReport`. The dashboard and `collectOneKind` branches keep `profile` (their `args` already carry the right `-p`).

`collect` is over 100 lines; this replaces lines rather than adding many. If it grows past its current length, move the route block into a `private static func platformInputs(...)` returning `(platformProfile, platformUnavailable, nonPlatformAuth, tenantLevel)`.

- [ ] **Step 4: Run**

Run: `cd app && swift test --filter 'PlatformRouteCollect|ComplianceBenchmarkCollect|CollectHonesty|EnvironmentProfilesGolden' 2>&1 | tail -5`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Engine/ReportEngine.swift app/Tests/JamfReportsTests/PlatformRouteCollectTests.swift
git commit -m "Collect the Platform kinds as the platform slot's profile"
```

---

### Task 5: Verdicts on the Jamf Pro profile (D20)

**Files:**
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift` (`collect` after the loop, `enforceCollectVerdicts:2307`)
- Test: `app/Tests/JamfReportsTests/PlatformRouteCollectTests.swift`

**Interfaces:**
- Consumes: Task 4's `platformProfile` local.
- Produces:
  ```swift
  static func jamfProGroup(
      outcomes: [CollectOutcome], savedKinds: Set<String>, platformSeparate: Bool
  ) -> (outcomes: [CollectOutcome], savedKinds: Set<String>)
  ```

- [ ] **Step 1: Write the failing tests**

Append to `PlatformRouteCollectTests`. The device scan is on the scan tier, so these collect `[.inventory, .scan]`; `computers` is an inventory kind the stub answers with one Mac, so a scan that runs makes a `classic-computer-history` call:

```swift
    private let oneMac = #"[{"id":"1","general":{"managementId":"m1"}}]"#

    /// The Jamf Pro credential is dead while the Platform kinds land: the run is auth-dead,
    /// no device scan fans out, and today's summary is not written.
    func testADeadJamfProProfileIsNotHiddenByPlatformKindsThatLanded() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        try answer("pro", #"{"error":"unauthorized"}"#, exit: 3)
        try answer("platform", #"[{"id":"1","title":"CIS"}]"#)
        let stub = try makeStub()
        do {
            try await ReportEngine.collect(
                workspace: WorkspaceID(validating: ws), profile: ws,
                workspacePaths: WorkspacePaths.self, tiers: [.inventory, .scan], force: true,
                authConfirmationProbe: { _, _ in .rejected },
                locateJamfCLI: { stub }, onLine: { _ in })
            XCTFail("expected authExpired")
        } catch ReportEngineError.authExpired(let named, _) {
            XCTAssertEqual(named, ws)
        }
        XCTAssertFalse(calls().contains { $0.contains("classic-computer-history") })
        let summaries = try WorkspacePaths.summariesDir(for: ws)
        XCTAssertNil(FileManager.newestJSONFile(in: summaries))
    }

    /// The Platform credential is dead while Jamf Pro lands: Partial, and the scan runs.
    func testADeadPlatformProfileLeavesTheJamfProRunStanding() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        try answer("pro", oneMac)
        try answer("platform", #"{"error":"unauthorized"}"#, exit: 3)
        let stub = try makeStub()
        let lines = Lines()
        try await ReportEngine.collect(
            workspace: WorkspaceID(validating: ws), profile: ws,
            workspacePaths: WorkspacePaths.self, tiers: [.inventory, .scan], force: true,
            authConfirmationProbe: { _, _ in .rejected },
            locateJamfCLI: { stub }, onLine: { lines.add($0.text) })
        XCTAssertTrue(lines.all.contains { $0.contains(ReportEngine.unlandedSourcesMarker)
            && $0.contains("compliance-") }, "\(lines.all)")
        XCTAssertTrue(calls().contains { $0.contains("classic-computer-history") })
    }

    func testOneProfileInBothSlotsIsOneGroup() {
        let outcomes = [ReportEngine.CollectOutcome(kind: "computers", exitCode: 0),
                        ReportEngine.CollectOutcome(kind: "compliance-rules", exitCode: 3)]
        let group = ReportEngine.jamfProGroup(
            outcomes: outcomes, savedKinds: ["computers"], platformSeparate: false)
        XCTAssertEqual(group.outcomes, outcomes)
        let split = ReportEngine.jamfProGroup(
            outcomes: outcomes, savedKinds: ["computers"], platformSeparate: true)
        XCTAssertEqual(split.outcomes.map(\.kind), ["computers"])
    }
```

If `collect` takes `refreshSOFA`, pass `refreshSOFA: { _ in (.empty, []) }` in both calls only if the inventory tier fetches SOFA (it is refresh tier, so it does not).

- [ ] **Step 2: Run, expect the first test to fail**

Run: `cd app && swift test --filter PlatformRouteCollect 2>&1 | tail -15`
Expected: the dead-Jamf-Pro test fails: no throw, because the Platform kinds landed.

- [ ] **Step 3: Implement**

Add near `isCollectDead`:

```swift
    /// The outcomes and landed kinds the dead verdicts judge (spec 7.2, D20): those that ran as
    /// the Jamf Pro profile. Platform-only kinds on a profile of their own are another
    /// credential: they never make the run dead, and never keep a dead Jamf Pro run alive.
    static func jamfProGroup(
        outcomes: [CollectOutcome], savedKinds: Set<String>, platformSeparate: Bool
    ) -> (outcomes: [CollectOutcome], savedKinds: Set<String>) {
        guard platformSeparate else { return (outcomes, savedKinds) }
        return (outcomes.filter { !platformOnlyKinds.contains($0.kind) },
                savedKinds.subtracting(platformOnlyKinds))
    }
```

Change `enforceCollectVerdicts` to take the group for the dead checks and keep all outcomes for the `[partial]` line: add a parameter `judged: (outcomes: [CollectOutcome], savedKinds: Set<String>)`; pass `judged.outcomes`/`judged.savedKinds` to `evaluateAuthDead`, `isCollectDead`, `deadRunCause` and `deadRunAllowsDeviceScan`; leave `degradedKinds(outcomes:savedKinds:)` and `unlandedSourcesLine(_:attempted:)` on the full `outcomes`/`savedKinds`.

In `collect`, after the loop:

```swift
        let judged = Self.jamfProGroup(
            outcomes: outcomes, savedKinds: savedKinds,
            platformSeparate: platformProfile != profile)
        let judgedNotDue = plan.filter {
            $0.skip?.isNotDue == true
                && (platformProfile == profile || !Self.platformOnlyKinds.contains($0.kind))
        }.count
        let deadAfterScan = try await Self.enforceCollectVerdicts(
            outcomes: outcomes, savedKinds: savedKinds, judged: judged,
            skippedNotDueCount: judgedNotDue, profile: profile, bin: bin,
            authConfirmationProbe: authConfirmationProbe, onLine: onLine
        )
        // Judged before the scan adds its kinds, on the Jamf Pro group: Platform kinds that
        // landed must not date cached Mac figures today (spec 7.2).
        let matrixLandedNothing = !judged.outcomes.isEmpty && judged.savedKinds.isEmpty
```

Delete the old `skippedNotDueCount` local if nothing else reads it.

- [ ] **Step 4: Run**

Run: `cd app && swift test --filter 'PlatformRouteCollect|CollectHonesty|DeviceScan|CollectPlan' 2>&1 | tail -5`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Engine/ReportEngine.swift app/Tests/JamfReportsTests/PlatformRouteCollectTests.swift
git commit -m "Judge a collect's dead verdicts on the Jamf Pro profile alone"
```

---

### Task 6: The `platform` slot must reach the same Jamf Pro

**Files:**
- Create: `app/Sources/JamfReports/Services/PlatformHostCheck.swift`
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift` (`collect` signature and route block)
- Create test: `app/Tests/JamfReportsTests/PlatformHostCheckTests.swift`; add a case to `PlatformRouteCollectTests`

**Interfaces:**
- Produces:
  ```swift
  enum PlatformHostCheck {
      typealias Lookup = @Sendable (_ jamfPro: String, _ platform: String, _ bin: URL)
          -> (jamfPro: String?, platform: String?)
      enum Verdict: Equatable, Sendable { case same, different(jamfPro: String, platform: String), unknown }
      static func verdict(jamfProURL: String?, platformJamfProURL: String?) -> Verdict
      static let live: Lookup
  }
  ```
  and a `collect` parameter `platformHosts: PlatformHostCheck.Lookup = PlatformHostCheck.live`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import JamfReports

final class PlatformHostCheckTests: XCTestCase {
    func testHostsCompareCaseInsensitivelyWithOrWithoutScheme() {
        XCTAssertEqual(PlatformHostCheck.verdict(
            jamfProURL: "https://Example.jamfcloud.com", platformJamfProURL: "example.jamfcloud.com/"),
            .same)
    }

    func testDifferentHostsAreNamed() {
        XCTAssertEqual(PlatformHostCheck.verdict(
            jamfProURL: "https://a.jamfcloud.com", platformJamfProURL: "https://b.jamfcloud.com"),
            .different(jamfPro: "a.jamfcloud.com", platform: "b.jamfcloud.com"))
    }

    /// We could not ask: a warning, never a block (spec 3.1).
    func testAnUnknownHostIsUnknown() {
        XCTAssertEqual(PlatformHostCheck.verdict(
            jamfProURL: "https://a.jamfcloud.com", platformJamfProURL: nil), .unknown)
        XCTAssertEqual(PlatformHostCheck.verdict(jamfProURL: nil, platformJamfProURL: "b"), .unknown)
    }
}
```

In `PlatformRouteCollectTests`:

```swift
    func testAPlatformSlotOnAnotherJamfProSkipsThePlatformKinds() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        let stub = try makeStub()
        let lines = Lines()
        try await ReportEngine.collect(
            workspace: WorkspaceID(validating: ws), profile: ws,
            workspacePaths: WorkspacePaths.self, tiers: [.inventory], force: true,
            locateJamfCLI: { stub },
            platformHosts: { _, _, _ in ("https://a.jamfcloud.com", "https://b.jamfcloud.com") },
            onLine: { lines.add($0.text) })
        XCTAssertFalse(calls().contains { $0.hasPrefix("-p \(ws)-API ") })
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("[warn] ") && $0.contains("b.jamfcloud.com") },
                      "\(lines.all)")
    }
```

Task 4's tests leave `platformHosts` at its default; under XCTest the live lookup reads no jamf-cli config file and the stub's `[]` is no URL, so the verdict is `.unknown` and the kinds still run. Pass `platformHosts: { _, _, _ in (nil, nil) }` in those calls if any test reads the network or the real config.

- [ ] **Step 2: Run, expect a compile failure**

- [ ] **Step 3: Implement `PlatformHostCheck.swift`**

```swift
import Foundation

/// Spec 3.1: a `platform` slot whose profile reaches another Jamf Pro than `jamf_pro` would mix
/// two servers' data in one folder. Unknown (the probe failed, `jss-url:read` missing) never
/// blocks: we could not ask.
enum PlatformHostCheck {
    typealias Lookup = @Sendable (_ jamfPro: String, _ platform: String, _ bin: URL)
        -> (jamfPro: String?, platform: String?)

    enum Verdict: Equatable, Sendable {
        case same
        case different(jamfPro: String, platform: String)
        case unknown
    }

    static func verdict(jamfProURL: String?, platformJamfProURL: String?) -> Verdict {
        guard let jamfPro = PlatformTwin.host(of: jamfProURL),
              let platform = PlatformTwin.host(of: platformJamfProURL) else { return .unknown }
        return jamfPro == platform ? .same : .different(jamfPro: jamfPro, platform: platform)
    }

    /// The Jamf Pro profile's URL from jamf-cli's config file, and the Jamf Pro URL the platform
    /// profile reaches: recorded on its `Connection` member, else asked once per process.
    static let live: Lookup = { jamfPro, platform, bin in
        let configured = ProfileService.readConfigFile(at: ProfileService.jamfCLIConfigFileURL())?
            .first { $0.name == jamfPro }?.url
        let learned = ConnectionStore().jamfProURL(profile: platform)
            ?? PlatformTwin.learnJamfProURL(profile: platform, binary: bin)
        return (configured, learned)
    }
}
```

In `collect`, add the parameter after `locateJamfCLI`:

```swift
        platformHosts: PlatformHostCheck.Lookup = PlatformHostCheck.live,
```

and in the route `switch`, replace `case .profile(let named): platformProfile = named` with:

```swift
        case .profile(let named) where named != profile:
            let hosts = platformHosts(profile, named, bin)
            switch PlatformHostCheck.verdict(
                jamfProURL: hosts.jamfPro, platformJamfProURL: hosts.platform) {
            case .different(let jamfPro, let reached):
                platformProfile = profile
                platformUnavailable = "profiles.platform reaches \(reached), not \(jamfPro)"
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] Platform API not collected: \(platformUnavailable ?? "")"))
            case .unknown:
                platformProfile = named
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] could not confirm that profiles.platform reaches the same "
                                + "Jamf Pro as profiles.jamf_pro; collecting the Platform API anyway"))
            case .same:
                platformProfile = named
            }
        case .profile(let named): platformProfile = named
```

The `switch` needs `bin`, so the route block must sit after `guard let bin = locateJamfCLI()`; it already does (Task 4 placed it at the `commands` line).

- [ ] **Step 4: Run**

Run: `cd app && swift test --filter 'PlatformHostCheck|PlatformRouteCollect' 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Services/PlatformHostCheck.swift app/Sources/JamfReports/Engine/ReportEngine.swift app/Tests/JamfReportsTests/PlatformHostCheckTests.swift app/Tests/JamfReportsTests/PlatformRouteCollectTests.swift
git commit -m "Skip Platform kinds whose profile reaches another Jamf Pro"
```

---

### Task 7: Data Sources and the freshness strip follow the route (C50)

**Files:**
- Modify: `app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift:508-529` (`expectedKinds(skipExpensive:…)`)
- Modify: `app/Sources/JamfReports/Services/WorkspaceStore+Refresh.swift:613-640` (`expectedKinds(profile:…)`)
- Modify: `app/Sources/JamfReports/Services/CollectSourcesPlan.swift:30-45, 70-90`
- Modify: `app/Sources/JamfReports/Views/SourcesView.swift:744-760`
- Test: the suites that already test `expectedKinds` and `CollectSourcesPlan` (`rg -l 'expectedKinds\(|CollectSourcesPlan.build' app/Tests`)

**Interfaces:**
- Consumes: `PlatformRoute`, `EnvironmentProfiles.platformRoute`, `SharedConfigPin.platformAllowed`.
- Produces: `expectedKinds(..., platformUnavailable: Bool = false)`; `CollectSourcesPlan.Inputs.platformUnavailable: String?` and `platformProfile: String?`.

Sweep first and paste the output in the PR body:

```bash
rg -n 'nonPlatformAuthMethod\(|collectCommandMatrix\(|expectedKinds\(' app/Sources
```

Every hit outside `ReportEngine.collect` gets the route or is named in the PR body as not needing it (`CommandCatalog`'s privilege list reads paths, not `-p`).

- [ ] **Step 1: Write the failing tests**

```swift
    func testABlockWithoutPlatformDoesNotExpectThePlatformKinds() {
        let kinds = WorkspaceStore.expectedKinds(
            skipExpensive: false, authMethod: "platform", platformUnavailable: true)
        XCTAssertTrue(Set(kinds).isDisjoint(with: ReportEngine.platformOnlyKinds))
    }

    func testTheSourcesPlanNamesTheMissingPlatformProfile() {
        var inputs = CollectSourcesPlan.Inputs(product: .jamfPro, profile: "ws")
        inputs.platformUnavailable = EnvironmentProfiles.noPlatformReason
        let plan = CollectSourcesPlan.build(inputs)
        let rules = plan.sources.first { $0.kind == "compliance-rules" }
        XCTAssertEqual(rules?.skipReason, EnvironmentProfiles.noPlatformReason)
    }

    func testTheSourcesPlanShowsThePlatformProfileInTheCommand() {
        var inputs = CollectSourcesPlan.Inputs(product: .jamfPro, profile: "ws")
        inputs.platformProfile = "ws-API"
        let plan = CollectSourcesPlan.build(inputs)
        XCTAssertNil(plan.sources.first { $0.kind == "compliance-rules" }?.skipReason)
    }
```

Adjust the `Inputs` initializer call to the struct's memberwise form if other fields lack defaults.

- [ ] **Step 2: Run, expect a compile failure**

- [ ] **Step 3: Implement**

`expectedKinds(skipExpensive:…)`: add `platformUnavailable: Bool = false` and change the last filter line to:

```swift
            let platformOut = platformUnavailable || skipsPlatform
            return !(platformOut && ReportEngine.platformOnlyKinds.contains(kind))
```

`expectedKinds(profile:…)`: after `config` is loaded,

```swift
        let route = EnvironmentProfiles.resolve(config: config, workspace: profile)
            .platformRoute(platformPinAllows: SharedConfigPin.platformAllowed(profile: profile))
        let platformAuth: ProfileAuthMethod.Resolved? = switch route {
        case .profile(let named) where named != profile: ProfileAuthMethod.resolve(profile: named)
        default: auth
        }
```

and pass `authMethod: platformAuth?.authMethod`, `tenantLevel: platformAuth?.isTenantLevel == true`, `platformUnavailable: { if case .unavailable = route { true } else { false } }()`.

`CollectSourcesPlan.Inputs`: add `var platformProfile: String?` and `var platformUnavailable: String?`. In `matrix(_:)`, call `collectCommandMatrix(profile: inputs.profile, platformProfile: inputs.platformProfile, staleDays:)` and set `platformUnavailable: inputs.platformUnavailable` on the plan inputs.

`SourcesView.reloadSourcesPlan`: compute the route as above, set `platformProfile` (for `.profile`), `platformUnavailable` (for `.unavailable`), and take `authMethod`/`tenantLevel` from the Platform profile's `ProfileAuthMethod.resolve` when it differs from the workspace's.

- [ ] **Step 4: Run**

Run: `cd app && swift test --filter 'CollectSourcesPlan|DataFreshness|WorkspaceStore' 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Services app/Sources/JamfReports/Views/SourcesView.swift app/Tests/JamfReportsTests
git commit -m "Follow the Platform route in Data Sources and the freshness strip"
```

---

### Task 8: Docs, config example, CHANGELOG, spec wording

**Files:**
- Modify: `CLAUDE.md` and `AGENTS.md` (same edits; AGENTS.md mirrors CLAUDE.md)
- Modify: `config.example.yaml:130-138`
- Modify: `CHANGELOG.md` (Unreleased)
- Modify: `docs/superpowers/specs/2026-10-19-environment-model-design.md` (7.2)

- [ ] **Step 1: CLAUDE.md and AGENTS.md**

In the `### profiles config (2.12, environment model P1)` section:
- Replace `platform: "Example-API"    # recorded, not read yet (P3)` with `platform: "Example-API"    # runs the Platform-only kinds (P3)`.
- Replace `EnvironmentProfiles.resolve(config:workspace:auth:)` with `EnvironmentProfiles.resolve(config:workspace:)`.
- Replace "`platform` too when `auth` says the profile is a Platform one," with nothing (old shapes derive no `platform` slot).
- Add after the paragraph that ends "Since P2 the only read of `jamf_cli.profile` is `EnvironmentProfiles.namedOwner`":

  > **Platform route (P3).** `EnvironmentProfiles.platformRoute(platformPinAllows:)` (`PlatformRoute`) is the one answer to who collects `ReportEngine.platformOnlyKinds`: without a block, the workspace's own profile, skipped by its auth method as before; under a block, the `platform` slot's profile (`collectCommandMatrix(platformProfile:)`, the benchmark listing too), or none with the reason as the `[skip]`/`[plan]` text (`CollectSkipReason.platformUnavailable`): no slot, a slot `SharedConfigPin` holds (`profiles.platform` is pinned, held at first sight when it is not the workspace's own profile, `platformAllowed`), or a slot whose profile reaches another Jamf Pro than `jamf_pro` (`PlatformHostCheck`; unknown logs a `[warn]` and collects). `collect`, `expectedKinds` and `CollectSourcesPlan` read it. The dead verdicts judge only the outcomes that ran as `jamf_pro` (`ReportEngine.jamfProGroup`), so a dead Platform credential is Partial and a dead Jamf Pro credential is `authExpired` even when Platform kinds landed; the device scan follows that verdict, and "no source landed" (no summary) is judged on the same group.

- In the `**Workspace identity (2.12, environment model P2).**` paragraph, replace "the slots are not pinned until P4" style wording if present with "`profiles.protect` and `profiles.platform` are pinned".

- [ ] **Step 2: `config.example.yaml`**

Replace the `platform:` line's comment "not used yet" with "runs the Platform-only reports (compliance benchmarks, DDM status, blueprints); leave blank for none". Keep `security_cloud` as "not used yet (P12)".

- [ ] **Step 3: CHANGELOG.md, under Unreleased**

```markdown
- A workspace whose config.yaml has a `profiles:` block now collects the compliance benchmark, DDM and blueprint reports with the Platform API profile named in `profiles.platform`, and skips them when none is named. A Platform API profile that reaches a different Jamf Pro is skipped with a warning, and on a shared workspace a new one waits for a Confirm in Config Doctor.
- When Jamf Pro sign-in fails but the Platform API reports still arrive, the run now reports the expired Jamf Pro sign-in instead of finishing as Partial.
```

- [ ] **Step 4: Spec 7.2**

Replace the bullet starting "A product that landed nothing logs `[partial] <product>: no source landed`" with:

> - A Platform kind that did not land is named in the run's existing `[partial] N of M source(s) did not land` line (`ReportEngine.unlandedSourcesLine`), which `CollectHonestyWatcher` reads per kind; `retryCouldHelp` then asks per kind as today, so a permanent failure is not retried all day. No new line.

and in the bullet "Today's summary is rebuilt only when a `jamf_pro` source landed" replace the first sentence with "Today's summary is not written when `jamf_pro` sources were attempted and none landed."

- [ ] **Step 5: Verify and commit**

```bash
cd app && swift build --build-tests 2>&1 | grep "error:" || echo OK
cd app && swift test 2>&1 | tail -3
git add CLAUDE.md AGENTS.md config.example.yaml CHANGELOG.md docs/superpowers/specs/2026-10-19-environment-model-design.md
git commit -m "Document the Platform route, its pin and per-profile verdicts"
```

Then run `/vm-test` on `ci-macos15-xcode16.4` (Swift 6.1 floor) before pushing.
