# Site-limited login detection: design

Status: approved by the owner on 2026-11-11, including the state file. Target: 2.12. It was
reviewed once against the code (plan reviewer, 2026-11-11), and that review's findings are
folded in.

## Problem

A Jamf Pro user account can be limited to one site (Site Access). jamf-cli reaches such an
account only through a bearer-token profile (`--auth-method token`). Through that login, every
list and report the app collects returns only that site's objects, exits 0 and prints no warning.
The app then reports one site as the whole Jamf Pro server: workbook, HTML report, Overview,
Trends, alerts, webhooks and report-group exports all read as a small, complete fleet.

The reports go to people who never see the login, so the error is invisible to them. The fix is
to notice the limit and say so wherever a fleet figure leaves the app. Site breakdowns (a Site
column, a per-site tab) are separate work. They come after this one, and they need an
unrestricted login.

## Evidence (Jamf Pro 11.33.3, jamf-cli 1.36.0, test server, 2026-11-11)

The test server had two sites: Americas held 1 of the 2 Macs, and its 1 iPad was at None. The
same queries ran through an admin API client and through a user account with Site Access to
Americas and the Auditor privilege set.

| Query | Admin client | Site-limited user |
|---|---|---|
| `pro computers list` | 2 | 1 (exit 0) |
| `pro mobile-devices list` | 1 | 0 (exit 0) |
| `pro classic-policies list`, profiles, groups | all | Americas only (exit 0) |
| `pro report security` `total_devices` | 2 | 1 (exit 0) |
| `pro overview` Fleet › Managed Computers | 2 | **2** |
| `pro overview` Fleet › Managed Devices | 1 | **1** |
| `pro overview` Configuration › Policies | all | Americas only |
| `pro sites list`, `pro sites objects` | rows | exit 5, `Read Sites` |
| `classic-policies get` on a full-Jamf-Pro policy | object | exit 5 |

So `pro overview`'s Fleet counts are server-wide while everything else is filtered. That is the
signal. A `sites` 403 alone is not one: an admin API client without Read Sites gets the same 403.

On a production fleet with an API client, overview's Managed Computers equalled the managed rows
in the same run's `computers` snapshot on 4 of 4 runs. Every row carried the managed key, and
the two calls were about 2 minutes apart. Mobile parity is unproven: that fleet has no mobile
devices.

API roles and clients have no site field in the Jamf Pro API spec, so an OAuth2 client cannot be
site-limited. Platform API profiles reach Jamf Pro through a Jamf Account integration, which has
no site setting either.

## Rule

`SiteScope` (`Models/SiteScope.swift`) is pure:

```swift
enum SiteScope: Codable, Equatable, Sendable {
    case notApplicable          // an API client, Platform, School or Security Cloud login
    case unknown                // auth unread, or a count could not be taken
    case whole                  // this login sees every managed device
    case limited(computers: Seen?, mobileDevices: Seen?)  // at least one is non-nil
    struct Seen: Codable, Equatable, Sendable { let seen: Int; let total: Int }
}
```

`SiteScope.evaluate(auth:overview:computers:mobileDevices:)` takes decoded payloads:

1. **Auth.** `.oauth2`, `.platform`, `.apiKey` and `.security` give `notApplicable`. Every
   `.other` value is evaluated, which includes `token` (to confirm with a `config list` capture
   of a token profile, added as a fixture). A nil auth (`config list` unreadable, and always under
   XCTest) gives `unknown`. It is not read as an API client, and it is not evaluated with a
   zero-tolerance rule that an API-client fleet could trip.
2. **Counts.**
   - `total`: Fleet › Managed Computers and Fleet › Managed Devices, matched on the exact
     `section` and `resource` text and parsed as whole numbers. Any other value (`N/A`, blank,
     text) is nil.
   - `seen`: managed rows in the `computers` payload, through
     `DeviceInventoryService.managedFlag(ofComputer:)`, the reader `BinaryMissing` and the
     Devices screen use; and managed rows in the `mobile-devices-list` payload, through
     `MobileSummary.device`. Don't add a third managed reader.
   - A row whose managed state is unknown makes that device type's comparison nil: absent is
     not zero.
3. **Verdict.** For each device type with both numbers, `seen < total` makes it limited, and
   `seen >= total` reads as whole. Any limited type gives `limited`. All compared types whole
   gives `whole`. Nothing compared gives `unknown`. There is no tolerance: both payloads come
   from the same collect (below), minutes apart, and only a `.other` login reaches the rule.

## Where it is evaluated

Once per collect, in `ReportEngine.collect`, after `finalizeCollect`. That's where the run's
`profileAuth` and `savedKinds` already exist.
- An API-client, Platform, School or Security Cloud login is `notApplicable` whatever was saved,
  so the first collect after a switch to an API client clears a stale `limited`. A nil auth
  method touches nothing.
- Any other login is judged only when the run saved `computers`, and `overview` was saved this
  run or its newest snapshot is stamped the same local day. Overview is the 12 h tier and
  computers the 48 h tier, so requiring both in one run would starve for days. Mobile devices
  count only when `mobile-devices-list` was saved this run.
- A run that cannot judge keeps the previous verdict.
- Report-time consumers never re-derive the verdict. A report can be generated long after the
  collect and from a different login (a shared workspace, a re-authenticated profile), and
  neither HtmlReport nor CoreDashboard resolves auth.

## Persisted verdict

The verdict is written to `state/site-scope.json` in the data folder, beside the per-kind state
files:
- the `SiteScope` value;
- the time of the collect that produced it;
- the profile name.

It's written atomically through `AtomicInstall.write` and read through `BoundedFile.readLogged`.
A missing or unreadable file is `unknown`. The owner approved this new file on 2026-11-11, over
a field in the daily summary, which would be a data-model change and its own spec.

## Where it shows

Every consumer reads the persisted verdict. Only `limited` shows anything.

1. **Collect.**
   - One line: `[warn] this login sees 1 of 2 managed computers in Jamf Pro (a site-limited
     user account); reports cover only what it sees`. Mobile devices add a clause.
   - The line goes after `finalizeCollect`. It is never `[partial]`, because a retry cannot fix a
     login, and it stays outside `CollectHonestyWatcher`.
   - `AttentionCode.siteLimitedLogin` (add it to the `destination` switch as `.runHistory`):
     `limited` raises it, and `whole` and `notApplicable` clear it. `unknown` and a run that kept
     the previous verdict leave it as it is.
2. **Config Doctor.**
   - One row in the accuracy family, `accuracy.site_scope`, at `.warn`. Title: "This login sees
     only part of Jamf Pro".
   - Detail: the counts.
   - Hint: "Collect with a Jamf Pro API client, which sees every site, or treat these reports as
     one site's."
   - Silent otherwise.
3. **HTML report.** The first "Needs attention" sentence (`attentionItems`): "This report covers
   1 of 2 managed computers in Jamf Pro: the login is limited to some sites."
   - That list renders even with no daily summary, which is the 0-of-N case.
   - At a glance is not used: it renders nothing with no summary or tiles.
4. **Workbook.** The scope sentence goes in blank row 2 of the tab header, through
   `writeSheetHeader` (row 3 is where each tab's table starts), on every Jamf Pro tab, so no
   template is left without it.
   - The Executive Summary only appears in Full Instance, Executive and Custom, and the Cover in
     four templates, so neither one alone covers every report.
   - A tab that already writes row 2 (Fleet Drift's large-change note) gets the scope sentence
     first, then its own text.
   - No column or table row moves.
   - The Charts tab has no header (it holds images only) and carries no note.
   - Before building, check that no tab's tests pin row 2 as blank.
5. **Webhooks.**
   - The success digest and alert cards add one fact, `Scope: 1 of 2 managed computers`. It's
     a count only, and `minimal` detail drops it.
   - It's read from the persisted verdict, so a `jamf-cli-only` run, which never collects, shows
     it too.
6. **Report-group exports and the period report.**
   - `FleetRollup` sums `totalDevices` across profiles, and the period report carries the
     profile's counts.
   - Each gets one note line naming the profile whose login is site-limited, in the fleet workbook's
     summary sheet and the period report's About sheet. The fleet CSV gets none: it keeps the
     `Metric,Current,Previous,Delta` shape header-driven readers expect, and the workbook beside
     it carries the note.

Flagged, not in this change:
- **Trends:** the daily summary records no scope, so a series that spans a change of login mixes
  scopes.
- **Overview screens:** the Overview and Fleet Overview screens read `overview` directly, so they
  show server-wide counts beside site-filtered tabs.
- **Report narrative:** the AI narrative paragraph is not told the scope.
- **Token expiry:** token profiles expire after about 30 minutes, so a schedule on one fails with
  exit 3 (a Doctor row for token auth is its own change).

## Edges

- **Demo mode:** never evaluated, and nothing shown.
- **Jamf School and Jamf Protect workspaces:** `notApplicable` through the auth rule. A School
  workspace also never reaches the Pro collect.
- **A site-limited login with no devices in its sites:** computers 0 of N is limited. That's
  correct and the most misleading case.
- **Overview's Fleet section missing or renamed by a later jamf-cli:** `unknown`. The fixture
  comes from jamf-cli 1.36.0 output, reduced to counts.
- **A device enrolled or removed between the overview and computers calls:** on a `.other` login
  this can read as limited for one run, and the next full collect clears it. Accepted.

## Tests (case matrix)

| Case | Result | Where |
|---|---|---|
| oauth2, platform, apiKey, security | `notApplicable`; clears the item | `SiteScopeTests` |
| nil auth | `unknown`; item untouched | `SiteScopeTests` |
| token, both kinds saved, seen < total | `limited`; one `[warn]`; raises; state file written | collect stub |
| token, only one kind saved (tier run) | previous verdict kept; nothing logged | collect stub |
| seen ≥ total | `whole`; clears | `SiteScopeTests` |
| a row whose managed state is unknown | that type nil | `SiteScopeTests` |
| total `N/A` or text | that type nil | `SiteScopeTests` |
| computers limited, mobile whole | `limited` (computers only) | `SiteScopeTests` |
| 0 of N with no daily summary | the HTML sentence still renders | HTML test |
| limited | row 2 on every tab; no other cell moves | workbook layout test |
| limited, full vs minimal detail | fact present, then absent | webhook test |
| state file missing, unreadable, a link | `unknown` | state test |

The fixture pair is reduced to counts and the keys read: no names, serials or URLs.

## Docs

- CLAUDE.md and AGENTS.md get a paragraph in the jamf_cli config section: the rule, the
  evidence, the state file and the consumers.
- CHANGELOG gets a line under Unreleased.
- The wiki's Permissions page gets a note that a site-limited user account gives partial reports,
  and that a Jamf Pro API client sees every site.
