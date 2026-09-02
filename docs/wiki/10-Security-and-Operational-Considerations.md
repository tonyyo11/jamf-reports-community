# Security & Operational Considerations

This page covers secure workspace management, automation integrity, and audit trail
practices for fleet reporting in regulated environments.

## Cloud Sync and Shared Workspaces

Two layouts are supported, and they answer different questions. Pick the
narrower one that does what you need.

| You want | Layout | What syncs |
|---|---|---|
| Teammates to **read the reports** | Publish | Finished workbooks and HTML only |
| Several Macs to **run the reporting** | Shared workspace | Everything, including raw device data |

### Publish: share the reports, keep the workspace local

The narrowest option. Keep the workspace on local disk and point only the
generated reports at the shared folder:

```yaml
output:
  allow_absolute_paths: true    # required for any path outside the workspace
  output_dir: "~/Library/CloudStorage/OneDrive-Contoso/Team/Jamf Reports"
```

Raw snapshots, run logs, backups, and `config.yaml` stay local, where their
permissions and single-writer assumptions still hold. Run Check confirms this
with a green **"Reports publish to …"** row.

`~/Library` is otherwise off-limits to output paths, but `~/Library/CloudStorage`
is deliberately carved out — that is where macOS mounts every modern sync
provider, and it holds user data rather than application state.

### Shared workspace: several Macs, one history

Choose the folder in **Settings → Workspace location**. Every profile, snapshot,
report and trend then lives there, and any Mac pointed at it contributes to one
pooled history rather than keeping a private copy.

That path is per-Mac and is stored in this Mac's preferences, not in
`config.yaml` — a sync provider mounts the same team folder under each user's
home, so `/Users/alice/Library/CloudStorage/…` on one machine is
`/Users/bob/…` on the next. What every machine must agree on lives in the
workspace's own config:

```yaml
shared_workspace:
  enabled: true                  # omit to decide from the folder itself
  claim_ttl_minutes: 45          # how long a run's claim stays valid
  min_collect_interval_hours: 12 # 0 disables the freshness check
```

Coordination turns itself on when the workspace is on a synced volume. Two
guards then run:

- **Freshness.** A scheduled collect stands down when another Mac collected
  inside `min_collect_interval_hours`, naming which one and when. Pressing
  Refresh in the app always collects anyway — an explicit request wins.
- **Claims.** Each run publishes a short lease at
  `automation/.workspace-claim.json` naming the host, the operation and an
  expiry, so a second machine can see one is already working. A machine that
  sleeps or shuts down mid-run leaves its claim behind; expiry is what lets the
  next run take over rather than waiting forever.

Each Mac also records its own last run under `automation/hosts/<host-id>.json`
— one file per machine, never a shared one, so this state cannot itself produce
conflict copies.

**The claim is advisory, not a lock.** Sync is eventual, so two machines
starting within seconds of each other can both proceed. Nothing is corrupted
when that happens: snapshots are written under unique timestamped names and read
back in filename order, never by modification date. You simply get two collects
where you wanted one.

**Coordination covers Jamf Pro collects only.** A Jamf School profile on a
shared workspace gets none of the stand-down or claim behavior above — School
collects on its own schedule with no cross-Mac awareness. Jamf Protect data is
collected inside the same run as Jamf Pro, so it is covered in practice.

### What a shared workspace still costs you

**Everyone with folder access can read the fleet's PII.** `jamf-cli-data/`
snapshots and `automation/logs/` hold device serials, hostnames, usernames and
email addresses in the clear, and `config.yaml` holds any webhook URL you have
configured. The app writes them `0600` inside `0700` directories, but POSIX
permissions are enforced by the local kernel — a sync provider does not
replicate them. Whoever can open the SharePoint site can read the files, the
server-side search index can surface their contents, and a Windows client has no
POSIX permission model at all. `.metadata_never_index` suppresses local
Spotlight only; it does nothing server-side.

This is the one thing coordination does not solve. The app asks you to confirm
it when you choose the folder, and Run Check repeats it on every shared
workspace — but the decision is yours to make and to justify. In a regulated environment, decide deliberately who the
folder is shared with, and get it reviewed before the first collect. If the
audience for the reports is wider than the audience for device-level inventory,
use the publish layout instead — or both: a private shared workspace plus an
`output_dir` pointing at a wider folder.

**Backups are pruned per-machine.** Each scheduled backup records the Mac that
made it, and each machine prunes only its own — an unscoped prune would spend
one machine's retention budget on everyone's backups. Backups made before this
version carry no ownership record and are never auto-removed, so clear those out
once by hand.

**Keep every Mac on the same app version.** Versions before 2.7.0 order
snapshots by modification date and prune backups without checking whose they
are. Run Check warns when it sees a peer reporting a different version.

**Clocks matter.** Freshness compares timestamps written by different machines,
so leave "Set date and time automatically" on everywhere. Run Check warns when a
peer's timestamps are more than five minutes ahead.

**Conflict copies.** When two machines do write the same file at once, providers
keep both as `summary_2026-08-20 2.json` or `computers_… (1).json`. The app
ignores any file whose name is not in canonical form, so no report is ever built
from a duplicate. Run Check lists them so you can delete them; if they keep
appearing, raise `min_collect_interval_hours`.

**LaunchAgent plists are never safe to sync.** `~/Library/LaunchAgents/…` stays
local, always — including on a shared workspace, where only the data moves.
launchd executes whatever lands on disk without a write-permission check, so a
synced plist turns a cloud-account compromise into arbitrary scheduled
execution. The app only ever writes these locally; do not copy them to a share
yourself. Retired agents that the app archives into the workspace have their
webhook URLs scrubbed, precisely because that archive often ends up on one.

**`jamf_cli.require_manifest` and a shared workspace don't mix well.** If two
Macs happen to write a snapshot with the same filename stamp — a same-second
collision — the surviving file after sync may not be the one whose hash was
recorded, leaving a manifest that mismatches the file on disk and blocks
generate until you delete the manifest by hand. Leave `require_manifest` off
on a shared workspace.

**A scheduled run needs the folder mounted to start at all.** If the shared
folder isn't mounted when a LaunchAgent fires, launchd can't start the job and
nothing is written — no log line, no entry in Run History. The Automation
Health overdue check is what surfaces this: the schedule simply looks like it
stopped firing.

**`retention.snapshot_keep_count` counts files, not days per Mac.** The count
floor keeps the newest N snapshot files in a kind's folder regardless of which
Mac wrote them. With N Macs collecting daily into the same shared folder, that
floor protects roughly `keep_count / N` days of any one machine's history.

**Backup diffs: Raw mode is unredacted.** Summary mode and its Copy button
redact credential-shaped values (password hashes, recovery keys, and similar);
Raw mode shows the full payload as jamf-cli returned it.

### Check it

**Config → Run check** reports the whole picture for the active profile: which
layout is in effect, whether the workspace folder is reachable and writable,
which other Macs write there and when each last collected, whether their clocks
and app versions agree, any live or stale claim, and every conflict copy it can
see — each with what to do about it.

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

## Known Issues

**`pro report security` on jamf-cli 1.24+ requires a Jamf Security Cloud subscription.**
From jamf-cli 1.24.0, this Jamf Pro report is routed through the Jamf Security Cloud client
and fails on any tenant without a subscription — Security Posture, the weighted security
score, and every FileVault, SIP, firewall and Gatekeeper figure derived from it will show
their last collected values until this is fixed upstream. See the CHANGELOG's Known Issues
entry for the current workaround (pinning jamf-cli to 1.23.x).
