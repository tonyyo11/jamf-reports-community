# docs/

Operator-facing documentation for jamf-reports-community lives in the
**[project wiki](https://github.com/tonyyo11/jamf-reports-community/wiki)** —
installation, the app walkthrough, dashboards, scheduling, configuration, the included
command-line interface, and Jamf School. The wiki source is kept in [`wiki/`](wiki/) and published to the
GitHub Wiki manually.

This directory holds documentation that is versioned alongside the code:

- [`architecture/`](architecture/) — design records and the threat model:
  - [`jamf-reports-community-threat-model.md`](architecture/jamf-reports-community-threat-model.md):
    the repository threat model, refreshed for 2.12.0.
  - [`JAMF_CLI_FIRST.md`](architecture/JAMF_CLI_FIRST.md): why `jamf-cli` is the data
    source and how the app, the cache and scheduled runs fit around it.
  - [`clibridge-error-typing-adr.md`](architecture/clibridge-error-typing-adr.md): why
    `CLIBridge` throws typed errors instead of returning `-1`.
  - [`period-report-design.md`](architecture/period-report-design.md): the design behind
    period reports (implemented in 2.7.0).
  - [`archive/tiered-collection-adr.md`](architecture/archive/tiered-collection-adr.md):
    the 2026-05 tiered collection proposal, kept as history; most of it did not ship as
    written.
- [`../app/scripts/README.md`](../app/scripts/README.md) — the release pipeline: build,
  sign, notarize, package.
- [`testing.md`](testing.md) — the Swift test suite.
- [`images/`](images/) — the screenshots and bento tiles the repository README uses.
- [`../app/Localization/glossary.md`](../app/Localization/glossary.md) — the glossary the
  translations follow.
- [`../.claude/skills/`](../.claude/skills/) — the project skills the agent loop uses
  (`review-package`, `class-sweep`, `changelog-union`, `bundle-wave`, `stack-adopt`,
  `tip-test`, `loop-eval`, `wave-review`); [`superpowers/agent-loop.md`](superpowers/agent-loop.md)
  says when each runs.
- [`superpowers/`](superpowers/) — point-in-time design specs and implementation plans from
  the 2.8.0 to 2.12.0 cycles; [`superpowers/README.md`](superpowers/README.md) says which
  shipped, which did not, and where the shipped code diverged.

For a quick overview of the project, see the repository [`README.md`](../README.md).
Contributor and code-level conventions are in [`CLAUDE.md`](../CLAUDE.md).
