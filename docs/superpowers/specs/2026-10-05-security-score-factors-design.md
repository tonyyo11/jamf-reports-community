# Security score factors — design

Status: approved by the owner on 2026-10-05 for 2.9.0 ("build the scoring factors into 2.9.0").
The factor list and the grace periods are the session's recommendation, which the owner accepted
by asking for the build.

The security score stops being eight fixed weights. An admin lists the factors the score counts,
adds or removes one, and gives each a weight. Every configured security agent can be its own
factor. Native Jamf Pro data comes first.

## What is true today (checked 2026-10-05 on beta 1592 and prod data)

- **Eight weights, five measured.** `security_policy.score_weights` has slots for FileVault, SIP,
  Firewall, EDR agent, mSCP, XProtect, CVE and Secure Boot. A live collect measures only the first
  five: today's prod `summary.json` has `securityScoreBasis: fileVault,sip,firewall,crowdstrike,mscp`
  and no `xprotectPct`, `cvePct`, `secureBootPct` or `bootstrapPct`. Those fields are filled only
  by summaries imported from the old Python tool. So 25 of the default 100 points do nothing, and
  an alert rule on those four figures can never fire. Gatekeeper is measured and not scored.
- **Zero is the only way to drop a factor.** Removing a factor means typing 0, and the tab still
  lists it.
- **One agent.** The EDR slot scores one agent, chosen on the Scoring tab. Prod has three
  (CrowdStrike, Nessus, Splunk UF).
- **No released build reads `score_weights`.** It was added on 2026-10-02, after the
  v2.9.0-beta1 tag. Prod's config.yaml has no `security_policy` block.
- **The data for native factors is there.** In prod's `computers` snapshot (664 Macs) every Mac
  has `security.gatekeeperStatus`, `secureBootLevel` (628 full, 27 medium, 6 none, 3 not
  supported), `bootstrapTokenEscrowedStatus` (638 escrowed), `xprotectVersion` (662; 434 on the
  newest), `operatingSystem.version` and `general.lastContact`.
- **SOFA gives what the currency factors need.** The cached macOS feed lists, per major version,
  every release with its date (`OSVersions[].SecurityReleases[]`), and the newest XProtect
  (`XProtectPlistConfigData["com.apple.XProtect"]`, "5363", released 2026-09-29).
  `SOFAFeedService` reads releases today, not XProtect.

## Config

```yaml
security_policy:
  score_factors:              # what the security score counts; absent = the defaults below
    - factor: filevault
      weight: 15
    - factor: sip
      weight: 10
    - factor: firewall
      weight: 10
    - factor: gatekeeper
      weight: 5
    - factor: secure_boot
      weight: 5
    - factor: bootstrap_token
      weight: 5
    - factor: os_current
      weight: 15
      grace_days: 30          # optional, default 30
    - factor: xprotect_current
      weight: 5
      grace_days: 14          # optional, default 14
    - factor: patch_compliance
      weight: 10
    - factor: checked_in
      weight: 5
    - factor: mscp            # only when compliance.baselines has one
      weight: 10
      baseline: "…"           # optional; default the first baseline
    - factor: agent           # one entry per agent, by security_agents name
      agent: "CrowdStrike Falcon"
      weight: 5
```

- A list, so it keeps the order the admin chose and each factor can carry its own options.
- **Absent block or absent `score_factors`: the defaults.** The defaults are the native factors
  above, plus `mscp` at 10 when a baseline is configured, plus one `agent` entry at 5 for each
  configured security agent. A workspace with no EAs is scored on native data alone.
- **Present `score_factors`: exactly those factors.** An empty list scores nothing and Config
  Doctor says so. A factor listed twice counts once (the last entry wins, as a repeated key does).
- A weight is a number from 0 to 100. Weights need not add up to 100: the score is
  Σ(weight × share) / Σ(weight) over the factors that have data, so a factor with no data drops
  out and the rest are rescaled. That is the rule today.
- An entry the app cannot use (an unknown `factor`, a missing or out-of-range `weight`, an `agent`
  entry without the agent's name) is skipped and named by Config Doctor; a `grace_days` that is
  not a whole number from 0 to 365 uses the default and is named too. An `agent` or `baseline`
  that matches no configured entry is left out of the score and named. None of these fails the
  decode, like the rest of `security_policy`.
- `score_weights` is retired: added to `ConfigSchema.retiredKeys` as "2.9", not read, worded by
  Config Doctor as no longer read, and dropped by the next save of the block. No released build
  reads it, so nothing is carried over.
- A control set to `ignore` under `security_policy.controls` is not scored even when its factor is
  listed, as today. Gatekeeper's level now matters for the score too.

## What each factor measures

Each factor is a share: Macs that pass over Macs the factor can judge. A Mac the factor cannot
judge is left out of that factor's denominator, never counted as failing.

| Factor | Passes | Left out |
|---|---|---|
| `filevault`, `sip`, `firewall`, `gatekeeper` | the control reads on under the workspace policy (`SecurityFleetCounts`, `warning` counts as passing) | not reported; `ignore` |
| `secure_boot` | `secureBootLevel` is full security | not supported, or no value |
| `bootstrap_token` | `bootstrapTokenEscrowedStatus` is escrowed | no value |
| `os_current` | the Mac's macOS is at least the newest release of its major version that came out more than `grace_days` ago | a major version SOFA does not list; no SOFA feed (no data) |
| `xprotect_current` | `xprotectVersion` is at least SOFA's newest, or that release is younger than `grace_days` | no value; no SOFA XProtect (no data) |
| `patch_compliance` | the fleet patch figure (`PatchStatusService.fleetCompliancePct`) | no patch titles with devices (no data) |
| `checked_in` | last contact within `thresholds.stale_device_days` | no last contact |
| `mscp` | the baseline's pass share (`MSCPComplianceService`) | Macs with no data for the baseline |
| `agent` | the agent's value matches `connected_value` (`SecurityAgentCoverage`), over the whole fleet as the summary's EDR figure is | — |

`os_current` takes the place of the old CVE slot, which no live collect measured. The grace period is what keeps the score from falling on the day Apple ships:
with 30 days, a Tahoe 26 Mac today needs 26.6.2 (2026-08-17), not 26.7.1 (2026-09-28). The
strict "on the latest release" figure stays where it is today (Overview, reports) and is not the
score.

## Score, basis and comparisons

- `summary.json` keeps `securityScore` and `securityScoreBasis`. The basis becomes the scored
  factors with their weights, in list order: `filevault=15,sip=10,…,agent:CrowdStrike Falcon=5`.
  Two scores compare only when their bases are equal, as today; a weight change is a definition
  change.
- The summary writer also fills `secureBootPct`, `bootstrapPct` and `xprotectPct` (share
  current, with the listed grace period or the default), whether or not the score lists them, so
  alert rules on them can fire. `gatekeeperPct` and the per-agent shares were already written.
- Every place that shows a change in the score compares same-basis summaries only: the Overview
  card says "Not comparable" across a change; Trends measures the pill's and the hero's change
  from the day the definition last changed, and its caption names that date (already); the HTML
  report and PDF, alerts (`sameBasis`) and the period report already did.

## Screens

- **Config › Scoring.** One "Security Score Factors" card replaces the weights card: a row per
  factor with its name, today's share from the latest data (or why it does not count), its part of
  the score in percent, its weight and a Remove button; an "Add factor" menu listing the factors
  not in the list (each configured agent and baseline appears by name); and "Use defaults". The
  first edit writes the whole list to `score_factors` through the scoped
  `SecurityPolicyConfigWriter`; the save drops `score_weights`. The EDR picker stays, renamed
  "Agent the EDR card shows": it chooses the agent the Overview's EDR card and `crowdstrikePct`
  describe, not the score. Grace periods are edited in config.yaml.
- **Security Posture.** Under the score ring, a breakdown: each scored factor, its share and its
  points.
- **Reports.** The workbook's Executive Summary lists each factor under the score; the HTML
  report's definitions list the factors and weights in force.

## Not in this change

- Per-device risk (`RiskScoringService`) keeps its own factors.
- Fleet rollups keep averaging the stored score; a group whose profiles score on different bases
  says so, as for compliance.

## Decisions (settled 2026-10-05)

1. The factor list above, native first, with `mscp` and each agent optional and added by default
   only when configured.
2. `os_current` has a 30-day grace and `xprotect_current` a 14-day one, each overridable per
   factor.
3. `score_weights` is retired rather than read, because no released build reads it.
4. The score's basis includes the weights.
