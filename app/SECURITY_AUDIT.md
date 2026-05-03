# JamfReports.app Security Audit

**Scope:** `app/Sources/JamfReports/`, `app/build-app.sh`, `app/iconset/`
**Date:** 2026-04-26
**Updated:** 2026-05-03
**Branch:** `dev-app/2.0` (post-feature-merge)
**Auditor:** Claude (Opus 4.7)

---

## Summary

| Severity | Count | Status |
|----------|-------|--------|
| MUST-FIX | 3 | All fixed in this audit |
| SHOULD-FIX | 5 | 4 fixed, 1 mitigated/deferred |
| CONSIDER | 4 | 2 fixed/documented, 2 documented |

The codebase already follows a strong defense-in-depth pattern: `ProfileService.isValid`,
`WorkspacePathGuard`, atomic `replaceItem` writes, no shell invocation, plist label
validation, and credential keys rejected at config load. The findings below close
trailing-slash prefix bugs, remove an unwired Protect snapshot prototype that had an
invalid-profile path fallback, shrink the file-opening allow-list, and harden the build
chain (Hardened Runtime + entitlements).

**Final pass, 2026-05-03:** expanded the review to the Python HTML report and the
Swift multi-profile manual-run path. The remaining findings were fixed: generated
HTML now escapes branding in title/topbar contexts, rejects unsafe CSS color
overrides and active SVG logos, and Swift manual multi-profile runs now validate
their saved `multi-launchagent-run` arguments plus status/stdout/stderr paths
before executing a trusted command.

---

## Audit checklist

### 1. Path traversal — every user-controlled path validated and symlink-resolved

**MUST-FIX 1** — `Services/SystemActions.swift:43`
`canonicalize(_:)` uses `resolved.path.hasPrefix($0.path)` *without* a trailing `/`.
A symlink target of `~/Jamf-Reports-evil/foo` would prefix-match `~/Jamf-Reports`
and pass canonicalization. Combined with `NSWorkspace.shared.open` this allows the
GUI to be coerced into opening files outside the workspace.
**Fix applied:** require `path == base || path.hasPrefix(base + "/")`.

**MUST-FIX 2** — removed Protect snapshot prototype invalid-profile fallback
An unwired Protect cache status prototype previously constructed a workspace path
from an invalid profile name, which could have let a future route enumerate JSON
outside `~/Jamf-Reports`. The view and its single-consumer snapshot service were
removed during dead-code cleanup.
**Fix applied:** removed the unreachable prototype surface and service.

**MUST-FIX 3** — `Services/TrendStore.swift:13`
`load(profile:range:)` does string-interpolation
`Jamf-Reports/\(profile)/snapshots/summaries` with no validation at the
boundary. All current callers happen to pass a validated profile, but
defense-in-depth requires the library function to refuse invalid input.
**Fix applied:** call `ProfileService.workspaceURL(for: profile)` and bail
on `nil`.

**SHOULD-FIX 1** — `Services/RunHistoryService.swift:33,39`
`safeDirPath` is a `path` without trailing `/`; `resolved.path.hasPrefix(safeDirPath)`
shares the same trailing-slash ambiguity as MUST-FIX 1. Currently low-impact because
the source enumerator only sees real children of `logsDir`, but a symlink whose
target resolves to a sibling directory like `…/automation/logsXXX` would pass.
**Fix applied:** append `/` to the prefix.

Other path-construction sites (`ConfigService.configURL`, `LaunchAgentWriter.write`,
`DeviceInventoryService.validatedWorkspaceRoot`, `WorkspacePathGuard.validate`,
`ReportLibrary.list`, `CSVInboxService.list`, `RunHistoryService.isInsideLogsDir`)
either validate the profile, append `"/"` to the prefix, or constrain paths through
`WorkspacePathGuard`. No additional findings.

### 2. Profile / slug sanitization

`ProfileService.isValid` (`^[a-z0-9][a-z0-9._-]*$`) is applied at:

- `ProfileService.workspaceURL(for:)` ✓
- `ProfileService.discoverLocal()` ✓
- `WorkspaceStore.setProfile(_:)` ✓
- `ConfigService.configURL(for:)` ✓
- `LaunchAgentWriter.write(_:jrcPath:)` ✓ (and `LaunchAgentService.parse(_:)`)
- `OnboardingFlow.createWorkspace`, `registerJamfCLIProfile`, `scaffoldCSV` ✓
- `RunHistoryService.list(profile:)` ✓
- `DeviceInventoryService.validatedWorkspaceRoot` ✓
- `CLIBridge+Run.runNow(...)` ✓

**Missing before this audit:**
- removed Protect snapshot prototype invalid-profile fallback (MUST-FIX 2 above)
- `TrendStore.load(profile:)` (MUST-FIX 3 above)

Slug sanitization (`LaunchAgentWriter.sanitizedSlug` + `isValidComponent`) matches
the same regex (lowercase letters, digits, `._-`, must start with alnum) and is
applied in `LaunchAgentWriter.write` and `label(for:)`. Both `delete(_:)` and
`load(_:)/unload(_:)` go through `isValidLabel` which enforces the
`com.tonyyo.jrc.` prefix and the same allowed characters.

### 3. Process invocation — arguments array, no shell

Four `Process()` callsites, all use `executableURL` + `.arguments` (array),
**none** spawn `/bin/sh`, `/bin/bash`, `/usr/bin/env`, or set `launchPath`:

| File | Line | Executable |
|------|------|------------|
| `CLIBridge.swift` | 64 | caller-supplied (`jrc` / `jamf-cli` resolved via `locate`) |
| `CLIBridge+Run.swift` (via `run`) | n/a | same |
| `JamfCLIInstaller.swift` | 22 | `locate("jamf-cli")` |
| `LaunchAgentWriter.swift` | 157 | `/bin/launchctl` (hardcoded) |
| `OnboardingFlow.swift` | 364 | `locate("jamf-cli")` or `locate("jrc")` |

Arguments are constructed as Swift `[String]` arrays from validated profile / mode /
URL values; no shell metacharacters can affect parsing because there is no shell.

### 4. Atomic writes

| Path | Mechanism |
|------|-----------|
| `~/Library/LaunchAgents/com.tonyyo.jrc.<…>.plist` | Hidden tmp file → `replaceItem` (or `moveItem` on first write). `LaunchAgentWriter.write` lines 68–78. ✓ |
| `~/Jamf-Reports/<profile>/config.yaml` | `String.write(to: tmp, atomically: true)` followed by `FileManager.replaceItemAt`. `ConfigService.save` lines 175–180. ✓ |
| `~/Jamf-Reports/<profile>/config.yaml` (onboarding minimal config) | `String.write(to: configURL, atomically: true, encoding: .utf8)`. `OnboardingFlow.createWorkspace` line 184. ✓ |
| Exported run logs (`RunsView.exportLog`) | User-chosen destination via `NSSavePanel` → `FileManager.copyItem`. Acceptable for a user-initiated export. ✓ |

### 5. Credential handling

- `OnboardingFlow.clientSecret` is never persisted. It is held in `@Observable`
  state during the onboarding flow only.
- The secret is passed to `jamf-cli` over **stdin**, never as a process argument
  (which would be visible in `ps`). See `OnboardingFlow.runWithPTY`.
- After the `jamf-cli profile add` call returns, `clearClientSecret()` overwrites
  the in-memory `String` with NUL bytes and removes it. The `Data` buffer is also
  zeroed via `resetBytes`.
- If profile registration fails, subprocess output is redacted before being shown
  so a future `jamf-cli` behavior change cannot echo the client secret into the UI.
- `ConfigService.rejectCredentialKeys` walks the parsed YAML and refuses to load
  any mapping containing `client_secret`, `password`, or `api_key`. Both load and
  save paths invoke this guard.
- No code reads `~/.jamf-cli` keychain entries, env vars, or service tokens.

**SHOULD-FIX 2 (deferred)** — Swift `String` is value-semantic and immutable.
`clearClientSecret()` overwrites the *current* binding, but any prior copies
that the Observation framework, SwiftUI rendering, or autorelease pool retain
will still hold the original bytes. Treating Swift strings as un-zeroable is
the standard advice; users with this concern should rely on Keychain via
`jamf-cli` (already the persistent store). Consider switching the input field
to a transient `Data` buffer in a future revision. **Full fix deferred.**

**Mitigation applied:** clear the secret when navigating backward from the
authentication step and redact client ID/secret values from profile-registration
failure output before surfacing it in the UI.

### 6. URL opening

| Site | Validation |
|------|------------|
| `SettingsView.openURL(_:)` (3 GitHub links) | Hard-coded constants, additionally validates `scheme == "https"` and non-empty host. ✓ |
| `SystemActions.open(_:)` / `openFolder(_:)` | Uses `canonicalize(_:)`. After MUST-FIX 1, the allow-list (`~/Jamf-Reports`, `~/Library/LaunchAgents`, `~/Documents`, `~/Downloads`, `/tmp`) only matches when the resolved path is exactly the parent or a true child. ✓ |
| `SystemActions.reveal(_:)` | Same `canonicalize` guard. ✓ |

**CONSIDER 1** — The `/Applications` entry in `SystemActions.allowedParents()` is
broader than the app needs. The GUI never opens anything inside `/Applications`
in current code paths. Removing it would shrink the surface, but doing so is a
behavior change worth a separate PR.

**Fix applied:** removed `/Applications` from the allow-list.

### 7. Privilege escalation

- No writes to `/Library/LaunchAgents/`, `/Library/LaunchDaemons/`, `/Applications/`,
  `/usr/local/`, `/etc/`, or any system path.
- `launchctl` is invoked only for `bootstrap gui/<uid>` and `bootout gui/<uid>/<label>` —
  the user-domain APIs that don't require elevation.
- No `AuthorizationCreate*`, no `sudo`, no `osascript` "with administrator privileges",
  no `SMJobBless`.

### 8. Code injection in YAML / plist emit

**plist** — `LaunchAgentWriter.write` builds a typed `[String: Any]` dictionary
and serializes via `PropertyListSerialization.data(...format: .xml)`. The
`Label` key is concatenated from a validated profile + slug; no untrusted strings
flow in.

**YAML** — `YAMLCodec.quotedIfNeeded` quotes any value that contains `:#&*!|>'"%`,
starts/ends with whitespace, parses as Int, or matches `true|false|null|~`.
Inside quoted values it escapes `\` and `"`.

**CONSIDER 2** — `quotedIfNeeded` does not escape literal newlines, tabs, or
other control characters. A user who pastes a multi-line value into a column
name would produce invalid YAML on save (the encoder writes a literal newline
inside the quoted string). This is a robustness issue, not a security one —
the worst outcome is a write that the next decode rejects, leading to the
config falling back to defaults. **No change.**

### 9. Log redaction

`RunsView` renders `CLIBridge.LogLine.text` directly. The lines are produced by:
- `CLIBridge.run` — captures stdout/stderr from `jrc`/`jamf-cli`. The Python
  `jamf-reports-community.py` helpers (`[ok]`, `[warn]`, `[fatal]`) do not log
  client secrets; only the Jamf URL, profile name, file paths, and counts are
  emitted.
- `RunHistoryService.parseLogTail` — last 1 KB of the log file from disk.
- `OnboardingFlow.runWithPTY` — captures the `jamf-cli profile add` output.

`OnboardingFlow.runWithPTY` does pipe the secret over **stdin**, so it does not
appear in stdout/stderr unless `jamf-cli` echoes it back (it does not).
Profile-registration failures are still redacted defensively before being shown.

**CONSIDER 3** — Full `logURL.path` is rendered in the log header at
`RunsView.swift:136` (with `home` replaced by `~`). This is intentional — users
need to know which file they are looking at — and the path contains only the
validated profile name plus a label slug (no PII). **No change.**

### 10. Bundle integrity

Before this audit, `build-app.sh` produced an ad-hoc-signed bundle with no
entitlements file and no Hardened Runtime flag. That is fine for local dev but
provides zero binary-integrity protection against library injection.

**SHOULD-FIX 3** — `build-app.sh` codesign invocation does not pass
`--options runtime`. Adding the Hardened Runtime opts the app into Apple's
process-integrity protections (DYLD_INSERT_LIBRARIES blocked, library
validation enforced) without requiring notarization for local dev runs.
**Fix applied.**

**SHOULD-FIX 4** — No `JamfReports.entitlements` file. Without one, codesign
embeds no entitlements at all, and the app silently inherits whatever the
template default is at `codesign` time. Make the security trade-off explicit:
- `com.apple.security.app-sandbox` = **false** (we shell out to `jrc` and
  `jamf-cli` outside our container — sandboxing would break the core feature).
- `com.apple.security.network.client` = **true** (the eventual jamf-cli HTTPS
  calls).
- `com.apple.security.files.user-selected.read-write` = **true** (CSV picker).
- `com.apple.security.cs.allow-jit` = **false**, `cs.disable-library-validation`
  = **false** (Hardened Runtime defaults).
**Fix applied.**

**SHOULD-FIX 5** — `Info.plist` lacks `NSHumanReadableCopyright` and an
`NSAppTransportSecurity` block. ATS already defaults to "deny non-HTTPS"; the
explicit block makes the policy auditable and prevents a future code change
from silently opting in to plaintext HTTP. `LSMinimumSystemVersion 14.0` is
already present.
**Fix applied.**

**CONSIDER 4** — `README.md` does not document that production distribution
needs Developer ID + notarization (current build is `codesign --sign -`,
i.e. ad-hoc, and `spctl -a` will reject it). Adding a "Distribution" note to
the README is worth doing in a follow-up.

**Documentation applied:** root `README.md` and `app/README.md` now describe the
Developer ID, notarization, and stapling requirements for distribution.

---

## Findings detail

### MUST-FIX 4 — generated HTML branding injection

`HtmlReport._render()` inserted `branding.org_name` and the Jamf instance URL
directly into the `<title>` and topbar brand text. `HtmlReport._css()` also
trusted `branding.accent_color` / `accent_dark` inside a `<style>` block, and
`_logo_html()` embedded any configured file as a data URI.

**Fix applied:** title/topbar values are escaped with `_html_text`, accent
overrides are limited to hex colors, chart SVG colors use the same sanitizer,
and inline logos must be small PNG/JPEG/GIF/WebP bitmap files. SVG logos are
rejected to avoid active-content surprises in shared reports.

### MUST-FIX 5 — multi-profile Run Now plist path trust

`LaunchAgentWriter.runMultiNow` validated that the command executable was trusted,
but still accepted `StandardOutPath`, `StandardErrorPath`, `WorkingDirectory`,
and `--status-file` values from the plist. A tampered user LaunchAgent could
redirect output/status writes outside the generated log directory.

**Fix applied:** manual multi-profile runs now require the generated
`multi-launchagent-run` argument contract, validate profile lists/filters and
workspace root, and only write `status.json`, `stdout.log`, and `stderr.log`
under `~/Library/Logs/JamfReports/<label>/`. Symlinked log files or log
directories are rejected.

### MUST-FIX 1 — `SystemActions.canonicalize` trailing-slash prefix

```swift
// Before
return allowed.contains(where: { resolved.path.hasPrefix($0.path) }) ? resolved : nil
```

`/Users/me/Jamf-Reports-evil/data` matched `/Users/me/Jamf-Reports`. Fixed by
requiring an exact match or a true child (`hasPrefix(base + "/")`).

### MUST-FIX 2 — removed Protect snapshot prototype invalid-profile fallback

The unwired Protect status prototype previously fell back to constructing a
workspace URL from an invalid profile name. The entire prototype view and its
single-consumer snapshot service were removed during dead-code cleanup, so the
path no longer exists.

### MUST-FIX 3 — `TrendStore.load(profile:range:)`

```swift
// Before
let summariesDir = home.appendingPathComponent("Jamf-Reports/\(profile)/snapshots/summaries")
```

Library-level path interpolation with no validation. Fixed by routing through
`ProfileService.workspaceURL(for:)` and bailing on nil.

### SHOULD-FIX 1 — `RunHistoryService.list` prefix check

Same trailing-slash ambiguity as MUST-FIX 1. Fixed by appending `/`.

### SHOULD-FIX 3–5 — Build chain hardening

`build-app.sh` now passes `--entitlements app/JamfReports.entitlements --options runtime`
to `codesign`. `Info.plist` now has `NSHumanReadableCopyright` and a strict
`NSAppTransportSecurity` block.

---

## What's NOT covered by this audit

- **Distribution signing.** Ad-hoc signing only protects against tampering on
  the developer's machine. Distribution to other Macs requires Apple Developer
  ID + notarization; that is a release-engineering concern, not a code change.
  The requirements are documented in root `README.md` and `app/README.md`.
- **Full Python CLI internals.** The 2026-05-03 pass covered the Python HTML
  report and reviewed the primary CLI subprocess/path handling. It was not a
  line-by-line audit of every workbook sheet writer.
- **`jamf-cli` itself.** Treated as a trusted external dependency installed by
  the user via Homebrew.

---

## Hardening fixes implemented

1. `Services/SystemActions.swift` — exact-match-or-child prefix in `canonicalize`.
2. Removed the unwired Protect snapshot prototype that had an invalid-profile
   fallback path.
3. `Services/TrendStore.swift` — validate profile via `ProfileService`.
4. `Services/RunHistoryService.swift` — `path + "/"` prefix in `list`.
5. `app/JamfReports.entitlements` — explicit, restrictive entitlements.
6. `app/build-app.sh` — pass `--entitlements` and `--options runtime`.
7. `app/build-app.sh` — `Info.plist` adds `NSHumanReadableCopyright` and
   `NSAppTransportSecurity`.
8. `jamf-reports-community.py` — escape HTML title/topbar branding, sanitize CSS
   colors, and restrict inline logos to safe bitmap formats.
9. `Services/LaunchAgentWriter.swift` — validate multi-profile manual-run
   arguments and status/log path destinations before launching.
