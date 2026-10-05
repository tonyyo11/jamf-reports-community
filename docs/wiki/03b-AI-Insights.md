# AI Insights

Opt-in, on-device fleet insights using Apple's Foundation Models framework. Off by
default. Requires macOS Golden Gate 27 or later — on any earlier macOS, every AI surface
is hidden entirely, not shown as unavailable.

## What it is

Seven surfaces, all built from data the app has already collected, and none of them sends
a device, user or host name to the model:

- **AI Fleet Insight** (Overview) — the current daily summary as a headline and
  severity-tagged findings, with changes against the prior period. A share is always given
  with its other side ("FileVault on 94%, not encrypted on 6%") and changes in percentage
  points are marked better or worse.
- **AI Trend Insight** (Trends) — how the metrics offered on the screen moved over the
  selected range.
- **AI Audit Insight** (Audit) — which categories to work first and what changed since the
  previous audit. Only counts, check names and categories go to the model; a finding's
  detail and resource text stay behind.
- **AI Posture Insight** (Security Posture, Compliance Posture) — which control, and on
  Compliance which macOS version, accounts for most of the gap. It follows your security
  policy, so a hardware-encrypted Mac with FileVault off is a warning, never "unencrypted".
- **"Explain this run"** (Run History) — appears next to a failed scheduled run. Produces
  a one-sentence summary of the failure, a likely cause, and one concrete first
  troubleshooting step.
- **AI-generated executive summary** — an optional paragraph prepended to the Executive
  Summary sheet in generated `.xlsx` workbooks and the equivalent HTML report section, for
  reports generated from the app's GUI. Generate Report on the Overview includes it after a
  collect too.

Every card is hidden below macOS 27, in demo mode, and while AI insights are off for the
profile.

## Requirements and honesty about what runs where

- Requires macOS Golden Gate 27 or later with Apple Intelligence available on the Mac.
- On macOS 26 and earlier, every insight card and the Settings "AI Insights" panel do
  not appear at all — the app doesn't advertise a feature it can't run there.
- **The app uses the On-Device Foundation Model (Apple Intelligence) only. No fleet data
  leaves the Mac,** and there is no setting that can change that. Apple's framework also
  offers Private Cloud Compute, but Apple grants its entitlement only to App Store apps, so
  this app does not use it and carries no code to reach it. Settings shows a plain
  "On-Device Foundation Model (Apple Intelligence)" row rather than a picker, because there
  is nothing to choose between.
- There is one tier, `on_device`. A config that still names `external` or `pcc` runs
  on-device, and the next Settings save removes the old `tier` value and the `external:`
  block.

## Data-handling specifics

- **"Explain this run" is on-device only.** The explainer only ever builds
  the on-device model, so a log excerpt has no off-device path. The excerpt is
  also fully redacted (credential patterns, then hostnames/emails/serials/usernames)
  before it is ever stored in the value that reaches the model; there is no code path that
  can construct an unredacted excerpt.
- **The report narrative is built only from the same aggregate metrics the Executive
  Summary sheet already shows** (device counts, percentages, a security grade) — no
  device identifiers, usernames, or free-text fields reach the model.
- **The report narrative only runs during GUI-initiated report generation.** Headless
  runs — scheduled runs, the included `jamf-reports` command-line tool, and the
  Schedules "Run now" dispatcher — never call it, so scheduled/CLI reports never carry an
  AI section.
- Narrative generation is raced against a 10-second timebox; on timeout, an error, or
  empty output, the report is produced without the AI section rather than waiting.
- Model output that lands in an HTML report is escaped before insertion.

## Turning it on

Settings → **AI Insights** (only visible on a macOS Golden Gate 27 or later host):

- **Enable AI insights** — the master toggle; off by default.
- **On-Device Foundation Model (Apple Intelligence)** — a statement, not a control. The
  model runs entirely on this Mac. Each insight card's corner reads "On-Device · Apple
  Intelligence".
- A status line reports the live availability (for example, "On-device intelligence is
  ready," "Turn on Apple Intelligence in System Settings to use insights," or the model
  still warming up).

Settings writes only the `ai:` block of `config.yaml`; every other key is left alone. The
same block can be hand-edited directly:

```yaml
ai:
  enabled: false            # opt-in; inert on macOS < 27
  tier: "on_device"         # on_device (the only tier)
  reasoning_level: "light"  # light | moderate | deep
```

`reasoning_level` has no dedicated Settings control today — set it directly in
`config.yaml` if the on-device model on your Mac advertises reasoning support.

## Limitations

- Output quality depends entirely on Apple's on-device Foundation Model; the app does not
  tune, fine-tune, or supplement it.
- Every AI result is advisory, not authoritative. The Fleet Insight card and the report
  narrative both carry an explicit "verify against the [metrics/tiles]" note alongside
  their output — treat the generated text as a summary of the numbers you can already see
  elsewhere on the screen or in the same report, not a new source of truth.
