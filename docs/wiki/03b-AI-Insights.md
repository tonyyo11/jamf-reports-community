# AI Insights

Opt-in, on-device fleet insights using Apple's Foundation Models framework. Off by
default. Requires macOS 27 or later — on any earlier macOS, every AI surface is hidden
entirely, not shown as unavailable.

## What it is

Three surfaces, all built from data the app has already collected:

- **AI Fleet Insight card** (Overview) — turns the current daily summary digest into a
  plain-language headline and a short list of severity-tagged findings (info, warning,
  critical), with deltas against the prior period where available.
- **"Explain this run"** (Run History) — appears next to a failed scheduled run. Produces
  a one-sentence summary of the failure, a likely cause, and one concrete first
  troubleshooting step.
- **AI-generated executive summary** — an optional paragraph prepended to the Executive
  Summary sheet in generated `.xlsx` workbooks and the equivalent HTML report section, for
  reports generated from the app's GUI.

## Requirements and honesty about what runs where

- Requires macOS 27+ with Apple Intelligence available on the Mac.
- On macOS 26 and earlier, the Overview card and the Settings "AI Insights" panel do not
  appear at all — the app doesn't advertise a feature it can't run there.
- **The app runs the on-device Apple Foundation Model only. No fleet data leaves the
  Mac,** and there is no setting that can change that. Apple Foundation Models is
  on-device only — the `fm` command-line tool lists exactly one model, "system —
  On-device Apple Foundation Model". Private Cloud Compute is not offered, and the app
  carries no code to reach it. Settings shows a plain "Model — On-device" row rather
  than a picker, because there is nothing to choose between.
- An `external` tier (a bring-your-own hosted LLM) is specced in the config schema but not
  implemented. Setting `tier: external` has no effect today.

## Data-handling specifics

- **"Explain this run" is on-device only.** A profile that explicitly selects the
  reserved `external` tier is refused rather than served — the explainer falls back to
  its placeholder, so a log excerpt is never handed to an off-device model. The excerpt is
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

Settings → **AI Insights** (only visible on a macOS 27+ host):

- **Enable AI insights** — the master toggle; off by default.
- **Model — On-device** — a statement, not a control. Apple Foundation Models runs
  entirely on this Mac.
- A status line reports the live availability (for example, "On-device intelligence is
  ready," "Turn on Apple Intelligence in System Settings to use insights," or the model
  still warming up).

Settings writes only the `ai:` block of `config.yaml`; every other key is left alone. The
same block can be hand-edited directly:

```yaml
ai:
  enabled: false            # opt-in; inert on macOS < 27
  tier: "on_device"         # on_device | external (external not yet built)
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
