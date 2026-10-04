# Model providers and App Intents — design draft

Status: DRAFT for owner decisions (2026-10-04). Nothing here is built.

Two features:

1. **Model providers.** Insights can come from Apple's on-device model (today), from Anthropic's
   Claude, or from a local model server, chosen and configured in the app.
2. **App Intents.** Shortcuts actions to start a collect, generate a report, run a schedule and read
   fleet status. Siri runs them through shortcuts the user names.

## What is true today (checked 2026-10-04)

Evidence: the Xcode 27.0 SDK on the build Mac, Apple's documentation and Anthropic's documentation.
The research notes are in the session that wrote this draft.

- **The app's AI seams.** `FleetInsightGenerator`, `ReportNarrativeGenerating` and
  `RunFailureExplaining` each have a stub and a gated `FoundationModels…` conformer. The cards get a
  `FleetInsightInput`, which carries aggregates only. `ai:` in config.yaml has `enabled`, plus a
  `tier` whose only value is `on_device`.
- **Private Cloud Compute is not available to this app.** The 27.0 SDK ships
  `PrivateCloudComputeLanguageModel`. It needs the managed entitlement
  `com.apple.developer.private-cloud-compute`, and Apple's published eligibility (App Store Small
  Business Program; App Store, TestFlight and ad hoc only) does not cover a Developer ID build.
- **Custom models plug in in-process.** Foundation Models (macOS 27) has a public `LanguageModel`
  protocol. A conforming type runs inside the app; there is no system registry for providers.
  Anthropic publishes `ClaudeForFoundationModels` (Apache-2.0, no other dependencies, beta) as one
  such conformance.
- **Claude can also be called directly.** The Messages API is plain HTTPS: `POST
  https://api.anthropic.com/v1/messages` with `x-api-key` and `anthropic-version: 2023-06-01`. There
  is no official Anthropic SDK for Swift. `inference_geo: "us"` keeps inference in the US on current
  models.
- **Core AI is not a route to remote models.** It runs exported open-source models on the Mac, and
  bringing one into the app takes `apple/coreai-models` plus three more packages and a model folder
  in the bundle.
- **App Intents work without Xcode.** `swift build` already writes the const-values files that
  `appintentsmetadataprocessor` reads. Running that tool by hand produced `Metadata.appintents`.
  `build-app.sh` would run it and copy the output into `Contents/Resources` before signing.
- **Siri on the Mac.** App Shortcuts phrases are not supported on macOS (HIG). Shortcuts-app actions
  are. A user can still say "Siri, <shortcut name>" for a shortcut they built from the app's
  actions.
- **Still open:** whether `fm` on macOS 27.2 accepts `--model pcc`. It does not on 27.0, and nothing
  in the app depends on the answer.

## Part 1: model providers

### Recommendation: providers at the app's own seams

Each provider is a type that implements the three existing seam protocols. For example,
`AnthropicInsightProvider` implements `FleetInsightGenerator` and `ReportNarrativeGenerating`. It is
not built as a Foundation Models `LanguageModel`.

Why:
- A remote provider then works on every supported macOS (15, 26, 27). Only Apple's model needs 27.
- No new package. Calling the Messages API is one request type and one response type over
  URLSession. CLAUDE.md asks for a strong case before any new dependency.
- The egress rules below live in one place: the seam the cards already call.

The alternative is `ClaudeForFoundationModels` behind Foundation Models' `LanguageModel`. That gives
Foundation Models' sessions and guided generation for free, but it is macOS 27 only, a new
dependency, and marked beta. Revisit it when it leaves beta, if guided generation is wanted.

### Providers

| Provider | Phase | Configuration | Egress |
|---|---|---|---|
| Apple on-device | today | none | none |
| Claude (Anthropic) | 1 | API key, model, US-only processing | api.anthropic.com |
| Local model server (Ollama, LM Studio) | 2 | URL, model name | the URL given (localhost by default) |
| Bundled model via Core AI | not planned | — | none; adds 4 packages and a large model folder |

Claude model choice for insights is a picker:
- `claude-opus-5-5` (default; thinking can't be turned off, and effort defaults to `medium` — run
  `low` for these short summaries)
- `claude-sonnet-5-5`
- `claude-haiku-4-5`

An insight is roughly 2 K input tokens and 300 output tokens. That is well under a cent on Opus 5.5
at $4/$20 per million tokens. Send the server-side refusal fallback (`fallbacks: "default"` with its
beta header) on Opus 5.5 and Sonnet 5.5, and check `stop_reason` before reading the text.

### Two kinds of AI, never blurred

**On-device AI is Apple's model running on this Mac; nothing leaves the Mac. External AI is any
other provider. It sends data to a third party (Anthropic), or to another program or server (a
local model server), under that party's terms.** This difference is the most important thing the
feature communicates.

- Settings › Intelligence has two separate sections, **On this Mac** and **External AI services**.
  They have different icons and wording, and no shared toggle or picker that could switch one to
  the other.
- Every insight card names its source in its provenance line. "On-device · macOS Golden Gate 27"
  for Apple's model; "External · Claude (Anthropic) · sent to api.anthropic.com" for an external
  one. External cards also carry a distinct badge.
- While any external service is connected, Settings and the Overview footer say "External AI is on
  for this Mac", with a Disconnect button.

### Consent before anything is sent

External AI is off by default and is never turned on as a side effect. Connecting a service runs
an explicit disclosure step, and no request is made until it is confirmed.

1. **Disclosure sheet.** When someone chooses Connect on an external service, the sheet states, in
   plain words:
   - who receives the data and the exact endpoint
   - which features will use it (each insight card, the report narrative)
   - what kind of data is sent: fleet aggregates (counts, percentages, version names, check names),
     never device names, serials, users or log text
   - a live preview of the exact text for the current workspace, built by the same
     `FleetInsightInput.promptContext` the request uses
   - that the provider's own terms, retention and location apply, with a link to them, and the
     region option where the provider has one (`inference_geo: "us"` for Claude)
   - that requests cost money on the user's own account
2. **An explicit acknowledgement.** Confirming takes a checkbox reading "I understand this sends my
   organization's fleet data to <provider>", plus the Connect button. Return does not confirm, and
   neither does a default button.
3. **The acknowledgement is recorded.** It is stored per Mac and per service: the provider, the
   endpoint, the data scope and the features, with the date. Run History records "External AI
   connected/disconnected" events, so an administrator can see when it happened.
4. **Asked again when anything widens.** A new feature that would use the service, a new kind of
   data in the input, a changed endpoint or model family, or an app update that changes the scope
   shows the disclosure again before the next request. Until it is confirmed, those cards fall back
   to "Not sent: confirm the new scope in Settings", never to a silent send.
5. **Easy to undo.** Disconnect deletes the key from the Keychain, clears the acknowledgement and
   stops all requests immediately. Cards return to on-device or to their idle state.

### Data and egress rules

1. **External only for aggregate surfaces.** The five insight cards and the report narrative may use
   an external service. The run-failure explainer stays on-device only, because it reads a log
   excerpt; that is the existing rule and it stays.
2. **Secrets stay in the Keychain.** The API key lives in the login Keychain, never in config.yaml,
   which may sit in a synced team folder. It never reaches a log line, a diagnostic bundle or a
   webhook. Add the `sk-ant-` shape to `LogRedactor`.
3. **Organizations decide.**
   - A managed preference in the app's domain, deployable as a configuration profile, can turn
     external AI off entirely, or allow only listed services and endpoints.
   - When it is off, the External section reads "Turned off by your organization" and offers no
     Connect button.
   - A workspace can forbid it for everyone who opens it, through `ai.allow_remote: false` in
     config.yaml.
   - Organizations without such restrictions can opt in through the consent step above.
4. **No silent fallback, in either direction.** If an external service fails, the card says why
   ("Claude: the API key was rejected") and offers Retry. An on-device failure never falls through
   to an external service.
5. **The GUI only.** Scheduled and command-line runs never call an external service. That avoids
   unattended egress and Keychain reads from the background item. The narrative is already
   GUI-only.

### Where settings live

- **Per Mac** (app preferences plus the Keychain): the connected services, keys, models, URLs and
  acknowledgements. Secrets and consent cannot go into a workspace that may be shared.
- **Per workspace** (config.yaml): `ai.enabled`, which stays the gate it is today, and the new
  `ai.allow_remote`.

### GUI: Settings › Intelligence

- **On this Mac:** Apple's model, with its availability (available, needs macOS 27, not ready).
- **External AI services**, each row with Connect, which runs the consent step. Once connected,
  each shows:
  - **Claude (Anthropic):** an API key field (the `SecureSecretField` pattern), the model picker,
    a US-only processing switch, and **Test connection**. The test shows the latency and a one-line
    reply, and stores nothing.
  - **Local model server:** the URL (default `http://localhost:11434`), a model picker filled from
    the server's model list, and **Test connection**. The disclosure names the URL; a non-localhost
    URL is called out as leaving the Mac.
- **"Show what is sent":** opens the exact text for the current workspace, also once connected.
- **Usage this month:** requests and tokens, counted locally from the API's `usage` fields.
- **Disconnect** on each connected service.

### Phase 1 scope

The provider seam conformers, the Claude provider, Settings › Intelligence with the two sections,
the consent step and its record, the egress rules (1–5), the managed preference keys, Keychain
storage, redaction, and tests. Tests use a stubbed URLProtocol
and send no live request.

## Part 2: App Intents

### Actions (v1)

| Action | Parameters | Returns | Notes |
|---|---|---|---|
| Collect now | workspace, tiers (default: freshness) | a run summary | Same rules as the Refresh button: one collect at a time, the tick lock, cadence. |
| Generate report | workspace, template, formats | the files (`IntentFile`) | Shortcuts can mail or save them. |
| Run schedule now | schedule | started / refused | Uses `TickRunner.requestRunNow`. |
| Get fleet status | workspace | device count, P0, P1, security score, last collect, freshness issues | For "if P0 > 0, post to Teams" shortcuts. |
| Open screen | screen, workspace | — | Opens the app. |

Entities:
- `WorkspaceEntity`, queried over `ProfileService.runnableProfiles`.
- `ScheduleEntity`, covering both managed and hand-built schedules.
- `ReportTemplate`, an `AppEnum`.

### Behaviour

- **Collect and Generate run in the app process and report progress.** If one runs past the
  system's time limit, it says it is still running and Run History has the result.
- **Demo mode refuses every action.** A managed preference can turn the actions off: they stay
  listed and refuse with that reason.
- **Siri:** document how to build a shortcut ("Jamf scan" → Collect now) and say its name to Siri.

### Build

- `build-app.sh` runs `xcrun appintentsmetadataprocessor` after `swift build -c release`. It writes
  the source and const-values lists, outputs `Metadata.appintents` into `Contents/Resources`, then
  signs.
- It fails the build if no `.swiftconstvalues` file exists.
- The Xcode 27 CI leg checks that the metadata is produced. The Swift 6.1 floor leg builds without
  the step, since releases build on Xcode 27.
- Before shipping, a Tart VM install test confirms Shortcuts lists the actions from a Developer ID
  install.

## Decisions for the owner

1. **Default for external AI (decided 2026-10-04).** Off by default, and connected only through the
   explicit consent step; organizations can turn it off entirely by managed preference. Settled; no
   longer open.
2. **How remote providers are reached.** Raw HTTPS at the app's seams (recommended), or the
   `ClaudeForFoundationModels` package behind Foundation Models?
3. **Who pays.** A key per user, or an organization key through a proxy? The latter adds a proxy
   URL field and is the safer pattern for a fleet.
4. **Workspace override.** Is `ai.allow_remote: false` in config.yaml wanted?
5. **Intents scope.** Is the v1 action list right? Should Collect and Generate wait for the run to
   finish (recommended) or return as soon as it starts?
6. **Local server.** Is it worth Phase 2, or skip it unless someone asks?
