# Security & Operational Considerations

This page covers secure workspace management, automation integrity, and audit trail
practices for fleet reporting in regulated environments.

## Cloud Sync and Workspace Boundaries

**The default paths are the safe ones.** A workspace at `~/Jamf-Reports/<profile>/`
on local disk, written by exactly one Mac, is the layout every guard in this app
assumes. Moving the workspace onto OneDrive, SharePoint, Box, Dropbox, iCloud
Drive, Google Drive, or a mounted share does not just change where bytes live —
it changes three assumptions the app cannot re-establish on its own. Read this
section before pointing anything at a synced folder.

### If you only want your team to read the reports

Publish, don't relocate. Keep the workspace local and point **only the generated
reports** at the shared folder:

```yaml
output:
  allow_absolute_paths: true    # required for any path outside the workspace
  output_dir: "~/Library/CloudStorage/OneDrive-Contoso/Team/Jamf Reports"
```

Raw snapshots, run logs, backups, and `config.yaml` stay on local disk, where
their permissions and single-writer assumptions still hold, while finished
workbooks and HTML land in the team folder. The Config Doctor confirms this
layout with a green **"Reports publish to …"** row. This is the supported way to
share output with a team.

`~/Library` is otherwise off-limits to output paths, but `~/Library/CloudStorage`
is deliberately carved out — that is where macOS mounts every modern sync
provider, and it holds user data rather than application state.

### Why not the whole workspace

**1. Sharing the workspace shares the fleet's PII.** `jamf-cli-data/` snapshots
and `automation/logs/` hold device serials, hostnames, usernames, and email
addresses in the clear. The app writes them `0600` inside `0700` directories, but
POSIX permissions are enforced by the local kernel — a sync provider does not
replicate them. Whoever can open the SharePoint site can read the files, the
server-side search index can surface their contents, and a Windows client has no
POSIX permission model at all. `.metadata_never_index` suppresses local Spotlight
only; it does nothing server-side. In a regulated environment, treat relocating
the workspace as widening the audience for that data and get it reviewed first.

**2. Modification times stop being trustworthy.** A file provider re-stamps
mtimes when it syncs or materializes a file. The app therefore orders snapshots
by the timestamp in the **filename**, never by mtime, and refuses to prune
scheduled backups at all while `backups/` is on a synced volume — ordering there
would decide which backups get deleted. Expect the backups folder to grow until
you remove old ones yourself.

**3. Two Macs writing one workspace will quietly disagree.** There is no locking
between installations. Both write the same `summary_<date>.json`, the same
per-kind cadence markers, and the same `automation/<label>_status.json`, so the
first machine to run each day claims the work and the others skip it while still
reporting success. A failed run on one Mac can be masked by a successful run on
another. If a workspace must be reachable from more than one Mac, treat exactly
one as the writer and the rest as readers.

**Conflict copies.** When two machines do write at once, providers keep both as
`summary_2026-08-20 2.json` or `computers_… (1).json`. The app ignores any file
whose name is not in its canonical form, so no report is ever built from a
duplicate — but the Config Doctor flags them, and their presence means something
else is writing to that folder.

**LaunchAgent plists are never safe to sync.** `~/Library/LaunchAgents/…` stays
local, always. launchd executes whatever lands on disk without a write-permission
check, so a synced plist turns a cloud-account compromise into arbitrary
scheduled execution. The app only ever writes these locally; do not copy them to
a share yourself. Retired agents that the app archives into the workspace have
their webhook URLs scrubbed, precisely because that archive often ends up on one.

**If you use cloud storage anyway**, run the Config Doctor (Health Audit →
Config) — it reports which of the layouts above is in effect and what each one
costs.

## Configuration Integrity

**`config.yaml` retention settings are honored when synced.** The `retention.mode` setting
(archive or delete) and `retention.snapshot_keep_days` are read from `config.yaml` at
collect time, not stored in the app. If a synced config is modified to `mode: delete` and
`snapshot_keep_days: 1`, a snapshot collection will purge older raw data before you notice.
Note that `retention.enabled` is **off by default** — raw `jamf-cli-data/` snapshots are
kept indefinitely until an admin opts in, so this risk only applies to workspaces that
have already turned retention on.

**`jamf_cli.require_manifest` hardens against tampered snapshots.** When set to `true`,
each collected raw snapshot gets a sibling SHA-256 `manifest.json`, and every report-
generation entry point (xlsx, HTML, PDF, School) refuses to run at all if the newest
snapshot in any kind folder fails verification (hash mismatch or a corrupt manifest) —
rather than silently generating a report from tampered data. It does not trigger on
`absent` or `omitted` results, since legacy snapshots and partial collects cannot be
retroactively verified. Off by default.

**Recommendation:** store `config.yaml` in version control (local git, internal GitHub, etc.)
if your operational security practices require configuration audit trails. Generated reports
themselves do not need version control — only the input config.

## Audit Trail and Log Retention

**Run logs and status files are local and self-pruning.** The app keeps the newest 50 run
logs in `~/Jamf-Reports/<profile>/automation/logs/` and cleans up older ones automatically.

**In regulated environments**, collect and ship logs to your SIEM (Splunk, Elastic, etc.)
for a durable audit trail, especially for the write-path `patch-managed` command:

```bash
# Example: tail-ship logs to syslog
tail -f ~/Jamf-Reports/<profile>/automation/logs/*.log | nc -q1 siem.example.com 514
```

Logs include timestamps, profile name, command, exit status, and error details — but NOT
credential/secret material (always redacted). The `patch-managed` command logs device IDs
affected and the managed-state change requested.

## Diagnostic Bundle Redaction Scope

**`diagnostic-bundle` redacts credentials and most PII, but not bare IP addresses.**

The diagnostic bundle includes:

- Redacted `config.yaml` (secrets always removed)
- Recent logs (secrets redacted)
- Snapshots (PII redacted with stable hash placeholders: `device-<8hex>`, `serial-<8hex>`)
- Workspace tree listing (paths visible, but no data)

**Exception:** if your Jamf Pro instance is addressed by IP (e.g., `https://192.168.1.10/`) 
instead of a hostname, those IPs remain in the bundle. Server URLs are NOT redacted by the
IP-redaction heuristic (which matches only hostnames with alphabetic TLDs).

**Before sharing a bundle**, review it and redact IP addresses or other infrastructure
details if your security policy requires it:

```bash
# Inspect the bundle contents
unzip -l ~/Jamf-Reports/<profile>/diagnostics/jamf-reports-diagnostic-*.zip
```

## Generated Report Handling

**Reports contain MDM inventory: serials, usernames, OS versions, security posture,
compliance status, and application inventory.** These are the same fields visible in your
Jamf Pro console to authenticated users — but a generated Excel workbook or PDF is a local
file, not access-controlled.

**Recommendation:**

- Handle reports with the same care as your Jamf Pro inventory exports.
- Apply your organization's data classification (confidential, internal-only, etc.) to the
  output format (Excel/PDF watermarks, email DLP, file permissions, etc.).
- Set output permissions: `chmod 600 ~/Jamf-Reports/<profile>/Generated Reports/*.xlsx`
  (owner read/write only, no group or world visibility).
- Use `output.archive_enabled: true` to move older reports into an archive for retention
  governance (they are moved, not deleted, so you can audit/recover them).

## Multi-Tenant and Team Access

**Each profile is an isolated workspace; one person can manage multiple profiles.**

For team access to the same Jamf Pro instance without sharing credentials:

1. Create one `config.yaml` and workspace per person or role (e.g., `prod-ops`, `prod-audit`,
   `prod-dev`).
2. Authenticate each profile independently via the app's Onboarding flow — each gets its own
   `jamf-cli` credential.
3. Share only the LaunchAgent `.plist` files (in version control) to keep schedules in sync;
   each person runs the schedules locally.

Do not share the workspace directory (`~/Jamf-Reports/<profile>/`) or the `jamf-cli` keychain
credential across team members — use separate profiles and credentials for audit trail
isolation.

## Webhook Egress

**The opt-in `notify:` webhook digest never carries report files or device-level rows —
only aggregate metrics, statuses, and operational names** (profile, schedule label, run
status, counts). It requires `notify.url` to be `https://`; an `http://` URL is treated as
not usable and no send is attempted.

**Scope note — the overdue digest is fleet-wide.** The dead-man switch cannot be scoped
to one profile, because the profile whose agent is dead is precisely the one that isn't
running. A headless scheduled run therefore evaluates *every* schedule on the machine and
posts the digest to the first profile that has a usable webhook. On a Mac with more than
one profile, that card names the other profiles' slugs (and, in `full` detail, their
schedule names). Excluded profiles are omitted. If your profiles map to different
audiences, use `notify.detail: minimal`, which sends only a count.

- **`notify.detail: minimal`** reduces every card to event facts only — counts and
  statuses ("2 alert rules tripped", "1 schedule overdue") with no metric values, no
  error text, and no schedule names. Use it for headless or high-security hosts where the
  webhook should act as a doorbell rather than a data channel. `full` (the default) sends
  metric names/values, error text, and schedule names.
- **Failure-card error text is redacted before it leaves the Mac** — the same secret and
  PII redaction used elsewhere in the app (server hostnames included) is applied to a run's
  error description before it is placed in a card fact.
- **Slack/Teams mention and link injection is escaped.** Every fact label and value is
  HTML-entity-escaped (`&`, `<`, `>`) before it enters a payload, which structurally
  destroys Slack's mention/directive syntax (`<!channel>`, `<@U123>`, `<https://…|…>`) —
  untrusted text in a fact value can never trigger a broadcast ping or a disguised link.

See [Automation Trust](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust) for the dead-man switch, metric alerts, and
notification setup this webhook serves.

## Managed Automation Policy and Validation

**The app's "Automation" policy is declarative, not scriptable.** Setting a master toggle
installs or removes the managed LaunchAgent plists and validates policy changes in real
time.

- **On enable:** the app installs up to four agents (freshness, scan, reports, backup),
  signed with your chosen schedule times, and logs the installation to Run History.
- **On disable:** the app removes those agents and logs the removal.
- **On change:** the app diffs the policy, applies only the differences, and never
  overwrites hand-built schedules (exact name match required for ownership).

The policy JSON is stored in macOS AppStorage (not visible from the CLI, and there is no
export/import affordance in Settings). To move an automation policy to another Mac,
re-create the same settings on the **Automation** screen — reconcile derives and installs
the same LaunchAgents from the policy on any host running the app, so there is nothing
else to migrate.

The same Automation screen that hosts this policy also drives the opt-in Notifications
webhook and shows Automation Health (the dead-man switch for overdue or failing
schedules) — see [Automation Trust](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust).
