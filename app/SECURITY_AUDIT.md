# Security Audit

Security review findings and mitigations for the JamfReports macOS app.

Each entry records a review's date, scope, findings, and resolution.
Reviews are change-scoped unless explicitly noted as a full-project audit.

## 2026-06-01 — Export-path gate removal (B-04 follow-up)

**Scope:** removal of `SystemActions.userExportTargetIsAllowed(_:)` and its
two call sites (`AuditView.exportFindings`, `DevicesView.exportFilteredCSV`).

### Rationale

B-04 narrowed the reveal/open allow-list and introduced a secondary
path-prefix gate (Documents/Downloads/Desktop) for "user-initiated export
destinations". In production use the gate proved to be a defect, not a
control:

- `AuditView` returned **silently** when the gate rejected the user's
  NSSavePanel choice — "Export Findings" appeared to do nothing.
- The gate rejected destinations Mac admins legitimately use (network
  shares under `/Volumes`, iCloud Drive, workspace folders).
- The 2026-05-20 review already classified the equivalent ungated pattern
  in `PatchView.exportPatchComplianceCSV` as **verified clean**: "NSSavePanel
  constrains the write to a user-chosen path."

The save panel is per-action consent for one exact path — strictly stronger
than a static prefix check. All six export flows now share that single
pattern, with write failures surfaced in the UI.

**Unchanged:** the `allowedParents()` allow-list in `SystemActions.reveal` /
`openFolder` remains the boundary for all programmatic (non-panel) actions.

## 2026-06-06 — CONSIDER-grade hardening (v2.2.0 tail review)

**Scope:** two documentation items flagged in the 2026-06-06 security review;
no code or entitlement changes.

### Unsandboxed posture and inert entitlement keys

`JamfReports.entitlements` sets `com.apple.security.app-sandbox = false`.
This is intentional: the app shells out to `jamf-cli` via `Process`, writes
`~/Library/LaunchAgents` plists, and reads `/Volumes` for external-drive
workspaces — all require capabilities that macOS grants outside the sandbox
and restricts inside it. Adopting the sandbox would require sandbox extensions
for every LaunchAgent write and every direct subprocess, which is incompatible
with the security model (user-agent-only, no daemon, no privileged helper).

Three additional keys in the entitlements file are sandbox-scoped and have no
effect while the sandbox is off:

- `com.apple.security.files.user-selected.read-write` — grants sandbox
  extensions for user-selected files; inert when the sandbox is disabled.
- `com.apple.security.files.bookmarks.app-scope` — enables persisted security-
  scoped bookmarks; inert when the sandbox is disabled.
- `com.apple.security.network.client` — allows outbound TCP in the sandbox;
  inert when the sandbox is disabled (outbound network is unrestricted outside
  the sandbox under Hardened Runtime alone).

These keys are retained to document intent: if the app is ever sandboxed in the
future, the minimum required entitlements are already declared. They do not
weaken or change the current security posture.

### `output.allow_absolute_paths` knob

`WorkspacePaths.swift` exposes an `output.allow_absolute_paths` config key
(default `false`, opt-in only). When enabled, the output path is not required
to be a child of the profile workspace, allowing reports to land on a shared
mount (e.g. `/Volumes/SharedTeamDrive/reports`).

The sensitive-path blocklist in `WorkspacePaths` still applies even when
absolute paths are enabled, so paths under `/etc`, `/usr`, and similar are
rejected regardless of the setting.

Risk to note: if multiple profiles are configured to write to the same absolute
output path, reports from different tenants co-mingle in one directory. This is
a multi-tenant co-mingling risk, not a privilege-escalation risk. Operators
enabling this knob should use per-tenant subdirectories within the shared mount.
This key has no entry in `config.example.yaml` or `DEFAULT_CONFIG` and is not
documented in `README.md` — it is an undocumented power-user knob. If it is
promoted to a documented feature, the cross-tenant warning must accompany it.

## 2026-05-20 — PR-25 change review

**Scope:** the three changes in PR-25 — the `OOXMLWriter` xlsx ZIP/XML
generation fix, the new Patch Compliance CSV export
(`PatchStatusService.complianceCSV`, `PatchView.exportPatchComplianceCSV`),
and the sidebar monogram change.

### Findings

#### MUST-FIX — formula injection in the Patch CSV export (resolved)

`PatchStatusService.csvField` initially applied only RFC 4180 quoting and
did not neutralize values beginning with `=`, `+`, `-`, or `@`. Patch
titles originate from jamf-cli / Jamf Pro patch definitions, which can
include third-party Title Editor and community-sourced titles, so a
crafted title such as `=HYPERLINK(...)` could be evaluated as a formula
when the exported CSV is opened in Excel or Numbers.

The xlsx export path already neutralizes this in
`OOXMLWriter.sanitizeString`, and the Python CLI's `_safe_write` is the
documented contract; the CSV path diverging from it on the same class of
data was the defect.

**Resolution (PR-25):** `csvField` now prefixes a tab to any value that
starts with a formula character before RFC 4180 quoting, matching the
xlsx path. Covered by
`PatchStatusServiceTests.testComplianceCSVNeutralizesFormulaInjection`.

### Verified clean

- **`OOXMLWriter` ZIP-entry provider** — the chunked-provider slice logic
  is bounds-correct: a `start < data.count` guard, a
  `min(start + requested, data.count)` end clamp, and zero-length parts
  return empty `Data`.
- **`xmlEscape`** — replaces `&` first, so entity-introducing characters
  are not double-escaped; covers the five XML entities.
- **`CellValue.safe` / `sanitizeString`** — strips C0/C1 control
  characters (keeps tab/LF/CR), caps cell length, and neutralizes
  formula-injection prefixes.
- **`PatchView.exportPatchComplianceCSV`** — `NSSavePanel` constrains the
  write to a user-chosen path; the write is atomic; success and failure
  both surface a toast.
- **Sidebar monogram** — `prefix(4)` over a profile slug already validated
  by `ProfileService`; cosmetic, with no security surface.

### Notes

This is a change-scoped review, not a full-project audit. A broader audit
should cover the LaunchAgent surface, credential handling via the
`jamf-cli` stdin path, and the `SystemActions` path allow-list.
