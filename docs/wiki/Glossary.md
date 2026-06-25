# Glossary

Canonical terms for jamf-reports-community and the wider Apple-fleet
ecosystem it operates in. The Apple and Jamf vocabulary overlaps heavily
between products and product generations; this file pins exact meanings
so docs, code comments, and PR discussions stay consistent.

Entries are alphabetical within each section. Cross-references use
`see also: <term>`.

---

## Apple platform

### ABM / ASM — Apple Business Manager / Apple School Manager
Apple's web consoles where organizations enroll devices, assign managed Apple
IDs, and purchase apps for distribution. Pairs with MDM via the ADE token and
VPP service tokens. ABM is for businesses; ASM is the equivalent for
educational institutions (and what Jamf School integrates with).

### Activation Lock
Anti-theft mechanism tying a device to its Apple ID. On managed devices, MDM
can hold a bypass code so IT can recover from a lock state. Surfaces as a
field on `pro mobile-device-inventory-details` payloads.

### ADE — Automated Device Enrollment
Modern term for what was previously called DEP. Devices purchased through
ABM/ASM auto-enroll into MDM on first setup, with the prestage profile
controlling activation flow. *see also: DEP.*

### APFS
Apple File System. Default macOS volume format since 10.13. Relevant because
FileVault behavior, snapshots, and time-machine semantics differ from HFS+.

### APNs — Apple Push Notification service
The transport Apple uses to wake managed devices for MDM commands. An MDM
push is fire-and-forget; the device next polls the MDM server when it
receives the notification. Pushes can silently fail without surfacing an
error — one reason MDM commands are inherently asynchronous.

### Bootstrap Token
A per-device secret macOS escrows to MDM so the MDM server can authorize
sensitive operations (FileVault, software updates on Apple silicon, MDM
removal). "Bootstrap token missing" is a common compliance finding.

### DDM — Declarative Device Management
Apple's newer device-management protocol where the device autonomously
applies declarations rather than reacting to push commands. Built around
*blueprints* and *declarations*. Coexists with classic MDM commands on the
same device. *see also: Blueprint, MDM command vs declaration.*

### DEP — Device Enrollment Program
Legacy name for ADE. Apple retired the term but it still appears in older
docs, Jamf UI strings, and the `dep-devices` jamf-cli command. *see also:
ADE.*

### FileVault
macOS full-disk encryption. The compliance signal most fleets track first.
Statuses include `Encrypted`, `Not Encrypted`, and `No Partitions Encrypted`
(the canonical "off" value as of the JSS server enum, despite older docs
showing `Not Encrypted`).

### Gatekeeper
macOS subsystem that verifies code signatures before allowing execution.
Enabled by default; reported by Jamf inventory as `On` / `Off` (despite
older docs showing `Enabled` / `Disabled`).

### macOS
Apple's desktop operating system. The app requires macOS 14 (Sonoma) or
later and runs on subsequent macOS releases.

### MDM — Mobile Device Management
The protocol Apple defines for remote device administration. Jamf Pro,
Jamf School, and Jamf Protect are all MDM-adjacent products that speak
this protocol. *see also: DDM, MDM command vs declaration.*

### MDM command vs declaration
Two different Apple device-management primitives. **MDM commands** are
imperative, server-pushed, transient (`InstallProfile`, `EraseDevice`,
`DeviceLock`). **Declarations** are declarative, device-pulled, persistent
(activations, configurations, assets, management). DDM uses declarations;
classic MDM uses commands. Conflating the two leads to wrong API endpoints
and wrong field names.

### PSSO — Platform Single Sign-On
Apple's enterprise SSO mechanism for macOS. An identity provider (Okta,
Entra, Jamf Connect) issues tokens that satisfy Kerberos, password-sync,
and login flows. Replaces older AD-bind for many use cases.

### Rapid Security Response — RSR
Apple's mechanism for shipping small security updates without a full
OS-version bump (e.g. `15.7.3 (a)`). Surfaces as a separate inventory field
distinct from the major/minor OS version.

### Secure Boot
Apple silicon's boot integrity chain. Reported as `Full` / `Medium` / `Off`
in Jamf inventory; a fleet posture metric in mSCP baselines.

### SIP — System Integrity Protection
Kernel-enforced restrictions on what root can modify. Enabled by default;
disabling it requires Recovery Mode access. mSCP and STIG baselines require
SIP enabled.

### Supervised
A management state set during device enrollment that unlocks additional MDM
capabilities (e.g. enforced auto-erase, supervised-only restrictions).
Always true for ADE-enrolled devices; manual-enrolled devices may be
unsupervised.

### VPP — Volume Purchase Program
Apple's app-distribution mechanism for businesses and schools. Apps are
purchased through ABM/ASM and assigned to devices or users. VPP service
tokens have their own renewal cadence separate from MDM-push certificates.

### XProtect
Apple's built-in malware scanner. Definitions update silently in the
background; "XProtect definitions current" is a common compliance signal.

---

## Security frameworks and compliance

### Audit plist
The `org.<your_org>_*.audit.plist` files mSCP writes to
`/Library/Managed Preferences/` containing per-rule pass/fail results.
JamfReports reads these via an Extension Attribute that greps for the
configured prefix. *see also: mSCP, EA.*

### CIS Benchmarks
Center for Internet Security baselines. mSCP can generate CIS-aligned
baselines for macOS. Less common in U.S. government deployments than NIST
or STIG; more common in commercial enterprise.

### Compliance Band
JamfReports' bucketing of per-device failure counts into Pass / Low (1–10)
/ Med-Low (11–30) / Medium (31–50) / High (>50) / No Data tiers. Used in
the Compliance Posture dashboard's donut chart. *see also: Risk Score,
Security Score.*

### mSCP — macOS Security Compliance Project
Apple's open-source project for generating, deploying, and auditing
security compliance baselines (NIST, STIG, CIS, custom). Outputs include
config profiles, audit scripts that drop a results plist, and remediation
scripts. JamfReports' compliance dashboards assume mSCP-style audit plists
as the data source. Repo: github.com/usnistgov/macos_security.

### NIST 800-53
National Institute of Standards and Technology Special Publication 800-53,
a federal security-control framework. Revision 5 ("r5") is the current
version. Tailored baselines (subset of controls applied to a tenant)
are typical. mSCP can generate a baseline tied to a specific 800-53
control set.

### STIG — Security Technical Implementation Guide
DISA's hardening standard for DoD and federal systems. mSCP generates a
DISA-compliant baseline for macOS. STIG audits typically produce a much
larger compliance failure list than NIST baselines.

---

## Jamf products

### Jamf Connect
Identity/account management product. Synchronizes local macOS accounts
with cloud IdPs and provides nFactor-style login experiences. Not used
directly by JamfReports.

### Jamf Pro
Jamf's primary MDM product, on-prem or SaaS. Provides classic MDM commands,
the modern Platform API, policies, smart/static groups, patch management,
Extension Attributes. JamfReports' primary data source.

### Jamf Protect
Jamf's endpoint security product. Has its own GraphQL API (not REST), its
own OAuth2 credentials, and its own concepts (plans, insights, alerts,
analytics). The Protect dashboard in JamfReports reads cached snapshots
from `protect overview / alerts / computers / insights`.

### Jamf School
Jamf's education-focused MDM (a separate product from Jamf Pro, not just a
mode). Uses named-key envelope JSON shapes, API key auth (not OAuth2), and
its own resource model. JamfReports' school reports cover devices, groups,
users, classes, apps, profiles, and locations.

---

## Jamf Pro concepts

### Blueprint
A DDM unit that bundles declarations (configurations, assets, activations)
into a deployable package. Replaces config-profile-style imperative
delivery for tenants on DDM. *see also: Config Profile, DDM, Scope vs
Target.*

### Classic API
Jamf Pro's older XML-based REST API at `/JSSResource/...`. Authenticates
with HTTP Basic Auth (legacy) or a bearer token. Still required for some
endpoints not yet ported to the Pro API. *see also: Pro API, Platform API.*

### Config Profile
A `.mobileconfig` payload describing settings to apply to a device.
Delivered via classic MDM `InstallProfile` commands. Distinct from
*blueprint* (DDM). *see also: Blueprint.*

### EA — Extension Attribute
A custom inventory field defined per-tenant. Can be populated by a script
run on the device during `recon`, by a value the admin sets, or by an LDAP
lookup. JamfReports' Custom EA dashboard sheets are driven entirely by
`config.yaml` mappings. *see also: ea-results, recon.*

### Patch Policy
A Jamf Pro automation that updates a software title across a scope on a
schedule. Distinct from a *patch title* (the software) and a *patch
definition* (the version metadata).

### Patch Title
A software product Jamf knows how to patch (e.g. "Firefox", "Microsoft
Edge"). Each title has versions; the latest version is what compliance
percentages measure against.

### Platform API
Jamf's newer REST/JSON API spanning Pro, Protect, and other surfaces.
Different from the Pro API; uses Platform Gateway authentication
(`auth-method = platform` in jamf-cli profiles) instead of per-tenant
OAuth2. *see also: Pro API, Classic API.*

### Policy
A Jamf Pro automated workflow that runs on devices (install a package, run
a script, lock the screen, etc.) based on trigger + scope. Different from
*patch policy* (a specialized policy for software updates).

### Pro API
Jamf Pro's REST/JSON API at `/api/v2/...` (and earlier `/api/v1/...`).
Authenticates with OAuth2 client credentials. The primary API JamfReports
uses through `jamf-cli pro <subcommand>`. *see also: Classic API,
Platform API.*

### Recon
The `jamf recon` command devices run (manually or on a schedule) to push
their current inventory to Jamf Pro. EA scripts execute during recon. A
device that hasn't reconned in N days is *stale*. *see also: stale device.*

### Scope vs Target
Two related but distinct Jamf concepts. **Scope** (Pro): who a policy or
configuration profile applies to — a smart group, a static group, a site,
or "all computers." **Target** (Platform / DDM): the device set a blueprint
or declaration applies to. The fields have different schemas and different
API endpoints; conflating them is a common bug. *see also: Smart Group,
Static Group, Site.*

### Self Service
Jamf Pro's end-user macOS/iOS app where users opt into policies their
admin has scoped to them. Self Service-scoped policies don't run
automatically — they require user action.

### Site
Jamf Pro's tenant-subdivision mechanism. A multi-team Jamf deployment can
partition policies, scope, and EAs by site so each team only sees its own
resources. Distinct from *building* and *department* (organizational
metadata fields on a device record).

### Smart Group vs Static Group
**Smart groups** are dynamic — membership is computed from a criteria
expression (e.g. "FileVault Status = Encrypted AND OS Version >= 15"). New
devices that match the criteria join automatically. **Static groups** are
manual lists of devices. JamfReports surfaces smart-group membership in
several dashboards. Smart-group apply actions depend on jamf-cli's
`pro sg` namespace and are available only when the installed jamf-cli
provides it.

---

## jamf-cli

### Cached snapshot
JSON output from a jamf-cli command saved to disk under
`~/Jamf-Reports/<profile>/jamf-cli-data/<kind>/` so the GUI can render
without re-hitting the API. Most JamfReports dashboards read these
snapshots, not live data.

### ea-results
The `pro report ea-results --all` command output — a per-(device, EA)
table of values. Expensive to fetch: scales as `O(devices × EAs)`, so
54,000 rows is common on mid-sized fleets. Collected on the Scan tier.

### jamf-cli
The Jamf-Concepts CLI for the Jamf Pro / Platform / Protect / School APIs.
Open source at github.com/Jamf-Concepts/jamf-cli. The native engine that
JamfReports composes for every API call.

### jamf-cli profile
A saved set of tenant credentials (URL, client ID, OAuth2 token) keyed by
slug. Lives in jamf-cli's own keychain entry. JamfReports' "profile" maps
1:1 to a jamf-cli profile. *see also: Profile slug.*

### Namespaces
jamf-cli's subcommand groups: `pro` (Jamf Pro), `protect` (Jamf Protect),
`school` (Jamf School), `classic` (legacy classic-API endpoints).
JamfReports' `CoreDashboard` consumes `pro` and `protect`;
`SchoolDashboard` consumes `school`.

---

## jamf-reports-community

### Collection tier
One of three per-report cadence tiers — **Refresh**, **Inventory**, and
**Scan** — modeled by `CollectionTier`. Each report is assigned a tier,
and the tier sets how often it is re-fetched. On-prem / Cloud / Custom
presets (Settings → Performance) pick the per-tier cadences. *see also:
Refresh tier, Inventory tier, Scan tier.*

### Custom EA
A `custom_eas:` config entry that drives a dedicated sheet in generated
reports. Five EA types: `boolean`, `percentage`, `version`, `text`, `date`.
*see also: EA.*

### Dashboard
A screen in the app sidebar. Screens are grouped into Reports, Posture,
Operations, Fleet, Automation, Configuration, and System. Each non-core
screen is toggleable in Settings → Sidebar Visibility; the core screens
(Overview, Devices, Data Sources, Settings) cannot be hidden.

### Inventory tier
The mid-cost collection tier — device lists, configuration profiles,
apps, and EA coverage. Pageable bulk queries; tens of seconds per run.
*see also: Collection tier.*

### LaunchAgent
A macOS user-scoped scheduled job at
`~/Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.*.plist`.
JamfReports manages these via `LaunchAgentService` / `LaunchAgentWriter`.
Never installs system-wide LaunchDaemons or requests `sudo`.

### Profile (workspace profile)
A logical tenant within JamfReports. Each profile gets its own
`~/Jamf-Reports/<slug>/` directory, its own jamf-cli profile, its own
`config.yaml`, and its own cached snapshots. Switching profiles in the
sidebar re-routes every screen.

### Profile slug
The string identifier for a profile. Validated against
`^[a-z0-9][a-z0-9._-]*$` at every path-construction site (security
invariant — blocks path traversal). Examples: `prod`, `dev`, `cust-1`.

### Refresh tier
The cheapest, most frequent collection tier — the `overview`, `security`,
and `policy-status` summary endpoints, seconds per run. A `snapshot-only`
scheduled run collects this tier only. *see also: Collection tier.*

### ReportEngine
The native Swift engine that generates XLSX, HTML, and PDF reports from
cached jamf-cli JSON.

### Risk Score
A per-device multi-factor weighted score producing a Critical / High /
Medium / Low / Clean band. Factors configurable in Config → Scoring. *see
also: Security Score, Stability Index, Compliance Band.*

### Security Score
A fleet-level 0–100 weighted score across FileVault, SIP, Firewall,
CrowdStrike (or equivalent EDR), mSCP, XProtect, CVE, Secure Boot. Missing
metrics drop from the denominator and the result is renormalized.
Configurable in Config → Scoring. *see also: Risk Score, Stability
Index.*

### Stability Index
A management-level health score derived from compliance, patch posture,
and inverse stale-device pressure. Distinct from Risk and Security scores;
it's a quick "is the fleet trending up or down" pulse. Appears in Trends.

### Stale device
A device that hasn't checked in (reconned) within the configured stale
threshold (`thresholds.stale_device_days` in `config.yaml`, default 30).
Outreach dashboard tiers further bucket into Recent (0–30d) / Offline
(31–90d) / Inactive (91–180d) / Dormant (180d+). *see also: recon.*

### summary.json
A per-day snapshot file under `~/Jamf-Reports/<profile>/snapshots/computers/summaries/`
containing aggregate metrics (date, total devices, compliance %, FV %,
patch %, etc.). `TrendStore` reads these to build historical trend charts.
Each `generate`/`collect` run emits one.

### TrendStore
The `@Observable` Swift service that reads `summary.json` files for the
active profile and exposes the points the Trends and Overview dashboards
chart against. Range defaults to 4 weeks (configurable in Settings).

### Scan tier
The most expensive collection tier — full device inventory and the
per-device failure scans (`ea-results --all`, `patch-status
--scan-failures`, `update-status --scan-failures`, `device-compliance`).
Minutes on large fleets; schedule it overnight on rate-limited tenants.
*see also: Collection tier.*

### Workspace
The on-disk root for a profile at `~/Jamf-Reports/<slug>/`. Contains
`config.yaml`, `jamf-cli-data/`, `snapshots/`, `Generated Reports/`,
`automation/logs/`, `archive/`. Path construction goes through
`WorkspacePaths.dataDir(for:)` — never raw string interpolation.

---

## UI primitives

### Card
The bordered content section used as the building block for every screen.
Defined in `Theme/Components.swift`.

### Kicker
The small uppercased monospaced label above a title (e.g. "INVENTORY",
"POSTURE"). Used in `PageHeader` and `SectionHeader`.

### PageHeader
The top-of-screen component bundling a kicker, optional breadcrumbs,
title, subtitle, last-modified timestamp, and trailing actions. Every
dashboard starts with one.

### Pill
A small rounded label used for status/category (e.g. "Encrypted", "Stale",
"Critical"). Color-coded via `Pill.Tone` (gold / teal / muted / warn /
danger / ok).

### PNPButton
The standard button primitive. Has `style` (neutral / gold / danger) and
`size` (sm / md) variants. Every button needs `.accessibilityLabel` and
`.help`.

### SectionHeader
The "Section title — trailing-text" pattern inside a Card. Supports a
short trailing kicker for counts like "50 of 200 shown".

### Sidebar
The app's navigation rail. Groups: Reports, Posture, Operations, Fleet,
Automation, Configuration, System. Core screens (Overview, Devices, Data
Sources, Settings) are pinned and cannot be hidden.

### StatTile
The KPI tile primitive. Label, value, sub-text, optional trend indicator.
Used in every dashboard's KPI row.

---

## Operational tools (third-party)

### MHC — Mac Health Check
A swiftDialog-based compliance UI for end-user-visible mSCP audit
results. Developed by Dan Snelson (open source). Not part of
JamfReports, but cross-referenced in some operational workflows where
compliance findings drive user-facing prompts.

### swiftDialog
Open-source command-line tool for showing native macOS dialogs from
scripts (Bart Reardon). Common building block for MHC-style end-user
compliance UI.

---

## See also

- [App Onboarding](02-App-Onboarding) — the guided first run.
- [Dashboards](03-App-Dashboards) — every screen in the app.
- `docs/architecture/` in the repository — design decisions and the
  threat model.
