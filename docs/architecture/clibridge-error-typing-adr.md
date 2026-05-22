# ADR: Typed CLIBridge failure reasons in place of the `-1` sentinel

**Status:** Proposed — not implemented. Tracked as issue #103 item 10
(Epic: Security & silent-failure hardening). Implementation is deferred
to its own PR; this ADR is the disposition recorded for that epic item.
**Authors:** Tony Young + Claude (drafted during the #103 session)
**Date:** 2026-05-22

---

## Context

`CLIBridge` returns `Int32` from its process-running entry points
(`run`, `runAndCapture`, `collect`, `generate`, `audit`, `schoolGenerate`,
`runNow`, and the free function `runDeviceDetailProcess`). For an actual
jamf-cli process the value is the process exit code, and codes 1–6 have
named constants with documented meaning (`exitCodeUsage` = 2,
`exitCodeUnauthorized` = 3, `exitCodeNotFound` = 4,
`exitCodePermissionDenied` = 5, `exitCodeRateLimited` = 6).

`-1` is different. It is the app's own sentinel for "no jamf-cli process
exit code exists" and it is overloaded across at least six distinct
causes:

- codesign-gate rejection (the located `jamf-cli` failed signature
  verification — a potential-tamper signal)
- process launch failure (`Process.run()` threw)
- invalid profile name (`CLIBridge+Run.swift`)
- missing workspace directory
- `config.yaml` load failure
- a required CSV not found in `csv-inbox/` (`.csvAssisted` mode)

A caller that switches on the returned `Int32` — the Runs feed, the
`scheduledRun` path in `main.swift`, `GenerateOutcome` aggregation —
cannot tell a tampered binary from a missing config file. Issue #103
item 5 narrowed the *observability* gap for `runDeviceDetailProcess`
specifically: a codesign rejection and a launch failure now emit
distinct user-facing `LogLine`s through the `onLine` callback. But the
*return value* is still `-1` for both, so any decision made on the code
alone remains ambiguous.

## Decision

Introduce a typed Swift error, `CLIBridgeError`, for the app's
internal pre-spawn and launch failures, and reserve the `Int32` return
strictly for genuine jamf-cli process exit codes.

```swift
enum CLIBridgeError: Error, Equatable, Sendable {
    case codesignRejected(executable: String)
    case launchFailed(reason: String)
    case invalidProfile(String)
    case workspaceMissing(profile: String)
    case configLoadFailed(path: String)
    case csvMissing(inbox: String)
}
```

Entry points return `Result<Int32, CLIBridgeError>` (or `throws` an
`Int32`-or-error). Callers `switch` exhaustively — the compiler then
forces every call site to decide what a codesign rejection means versus
a missing config, which is the property `-1` cannot provide.

The named jamf-cli exit-code constants (1–6) are unaffected; they remain
`Int32` because they *are* real process exit codes.

## Why this is deferred, not done in #103

The change is wide and mechanical: every `return -1` site and every
caller that inspects the `Int32` must change together, or the contract
splits. That is a focused API-contract PR that deserves its own review
pass. Bundling it into the silent-failure-hardening epic would make that
epic's diff sprawling and hard to review — the anti-churn discipline in
`CLAUDE.md` exists to prevent exactly that.

The user-facing silent-failure symptom is already addressed for the
highest-value path (`runDeviceDetailProcess`, #103 item 5). Every other
spawn-site caller still receives an undifferentiated `-1` and infers
nothing from it — that ambiguity is precisely the deferred work. What
remains is an internal type-safety cleanup, which also fits Epic #104
(Code hygiene & refactors).

## Consequences

- **Positive:** exhaustive `switch` at every call site; a codesign
  rejection can never again be silently handled as a generic failure;
  new failure causes become a compile error until every caller handles
  them.
- **Cost:** touches every `CLIBridge` spawn site and caller in one PR;
  exit-code-handling tests must be updated in lockstep.
- **Migration:** mechanical. The named jamf-cli exit-code constants do
  not move. Recommend landing it as a single PR with no behavior change
  other than the type — pure refactor, verified by the existing
  `CLIBridge*Tests` suites.
