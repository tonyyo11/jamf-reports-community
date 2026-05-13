# JamfReports — Design Review Fix Plan

Branch: `emdash/lovely-rivers-stay-v0ryv`. This document is a complete plan for
addressing a design + visual-quality review of the v3.5-port dashboards and
shared theme. Work it top to bottom — phases are ordered so foundational fixes
land before the things that depend on them.

**Working assumptions** (confirmed with the author):

- The app is **dark-mode only** by design. Every `Theme.Colors.*` is a literal
  hex with no adaptive form. Do not introduce light-mode adaptive colors
  anywhere except inside the existing PNG export canvas (which forces
  `.colorScheme, .light` locally).
- **Do not pin the scene** to dark with `.preferredColorScheme(.dark)`. The
  intent is to leave the door open for a real light-mode pass in the future
  without unwinding the lock. In the meantime the dark hex literals will
  render dark regardless of system Appearance.
- The author wants **best-effort accessibility coverage** for users with
  visual disabilities, achieved by features that work *within* dark mode
  rather than by building a separate light palette. Phase 5 is dedicated to
  this. Light mode as a feature is explicitly **out of scope** for this pass.

For each item: file targets, what to change, and how to verify. Where I say
"pick", use design judgment within the constraints listed.

---

## Phase 1 — Foundational fixes (do these first)

These two changes touch the most code and the most users. Land them before
moving on so later edits sit on a clean base.

### 1.1 Make `Pill` never wrap

**Problem**: Pills wrap mid-word inside fixed-width frames. Visible on
ProtectView as `CRITICA / L`, `INVESTIGAT / ING`, `ACTI / VE`, `YE / S`,
`INAC / TIVE`. The pill is mono 10.5 + `.tracking(0.6)` + `.uppercased()` +
`padding(.horizontal, 8)`; outer `.frame(width: 72)` etc. force wraps when text
exceeds the frame.

**Where**: `Theme/Components.swift` — the `Pill` struct body.

**Change (part A)** — in `Pill.body`, after the `.background(bg, in: Capsule())`
chain, add `.fixedSize(horizontal: true, vertical: false)` and `.lineLimit(1)`.
Pills should always size to their content and never wrap.

**Change (part B)** — fix every call site that wraps a pill in a fixed-width
frame to size the *column*, not the pill. Replace this pattern:

```swift
Pill(text: x, tone: t).frame(width: 72, alignment: .leading)
```

with this pattern:

```swift
HStack(spacing: 0) {
    Pill(text: x, tone: t)
    Spacer(minLength: 0)
}
.frame(width: 72, alignment: .leading)
```

Call sites to update (grep for `Pill(.*).frame(width:`):

- `ProtectView.swift`: `severityPill` callers (72pt), `statusPill` callers
  (88pt), `booleanPill` callers (64pt + 48pt), `connectionPill` callers (88pt),
  the demo equivalents
- `UpdatesView.swift`: `failedPlansCard` — `Pill(text: plan.state, …).frame(width: 120, …)`
- `PolicyProfileView.swift`: `findingsCard` (90pt severity column) and
  `profileStatusCard` (120pt status column)
- `MobileFleetView.swift`: `devicesTable` Type column (uses
  `Pill(text: deviceType, …)` inside a TableColumn — Table handles width, but
  verify pill stays single-line after the `fixedSize` change)

**Then**: widen any column that still looks cramped. `INVESTIGATING` is 13
chars; at mono 10.5 with tracking that's ~95pt — bump the status column on
ProtectView from 88 to 104pt, and the state column on UpdatesView from 120 to
138pt. Eyeball the rest.

**Verify**: build, switch to demo mode, navigate to Jamf Protect. Confirm
*Recent Alerts* and *Computers* table pills render on one line. Then visit
Updates → trigger demo failed plans, confirm `PlanException` and `PlanCanceled`
don't wrap.

### 1.2 Fix `EmptyStateView` icon visibility

**Problem**: icon renders at 28pt with `Theme.Colors.hairlineStrong` (white @
0.12), which is nearly invisible against `winBG2`.

**Where**: `Theme/EmptyStateView.swift` line ~47.

**Change**: swap `.foregroundStyle(Theme.Colors.hairlineStrong)` for
`.foregroundStyle(Theme.Colors.fgMuted)`. While there, drop the
`NSAccessibility.announcementRequested` block at the bottom of `body` — switching
to an empty tab shouldn't fire a screen-reader announcement; the tab label
already speaks itself, and `NSApp.keyWindow` can be nil for non-focused windows.

**Verify**: any preview in `EmptyStateView.swift` — the icon should be visibly
present, not ghosted to the point of invisibility.

---

## Phase 2 — Token discipline

The dashboards leaked hex literals into status colors and severity ramps.
Centralize them now so later cross-screen work doesn't propagate the drift.

### 2.1 Add a severity ramp to `ThemeSemanticTokens.swift`

**Problem**: three different severity palettes across the codebase. Most
screens use `0xFF453A / 0xFF9F0A / 0xE8B614 / 0x30D158` (the Theme tokens);
`ProtectView.alertsBySeverityCard` invents `0xFF5757 / 0xFFB340 / 0xFFD55F /
0x6DC0C0`; the Protect export uses yet another (`0xDC2626 / 0xD97706 /
0xCA8A04 / 0x0891B2`). On the live Protect screen the Medium bar reads bright
yellow while the Medium pill immediately below reads gold-brown — they look
like different severity tiers.

**Where**: `Theme/ThemeSemanticTokens.swift`.

**Change**: add a `Theme.Severity` enum with a paired ramp for in-app (dark)
and export (light) surfaces. Pick colors that:

- For **in-app**: are distinguishable in dark mode at small chip sizes, and
  match what the existing `Pill` tones already use (`.danger` → critical,
  `.warn` → high, `.gold` → medium, `.teal` → low) so the bars in
  `alertsBySeverityCard` finally agree with the pills underneath
- For **export**: are saturated but not neon on the `#F8FAFC` canvas — the
  existing Protect export palette is a reasonable starting point

Shape:

```swift
extension Theme {
    enum Severity {
        case critical, high, medium, low

        var inApp: Color { … }
        var export: Color { … }
    }
}
```

Then refactor:

- `ProtectView.alertsBySeverityCard` to call `Theme.Severity.{critical,…}.inApp`
  instead of inlining `Color(hex: 0xFF5757)` etc.
- `ProtectView.severityPill(_:)` to map severity string → `Theme.Severity` →
  Pill tone (you'll need a `var pillTone: Pill.Tone` accessor on the enum, or
  switch the Pill API to take a `Theme.Severity` directly)
- `ProtectAlertsSeverityExport` to use `.export` values

**Verify**: in demo mode, the four bars in *Alerts by Severity* and the four
pills in *Recent Alerts* directly below should be the same color per row.
Critical row: same red; Medium row: same gold (not yellow vs brown).

### 2.2 Replace hardcoded status `Color(hex:)` literals with Theme tokens

**Problem**: status colors duplicated as inline hex in chart/state code instead
of referencing `Theme.Colors.ok/.warn/.danger`.

**Where (each file has a `…Color(for:)` helper)**:

- `PatchView.swift` — `complianceColor`, `actionColor`
- `OutreachView.swift` — `daysSinceColor`
- `CompliancePostureView.swift` — `barColor`

**Change**: replace `Color(hex: 0xFF453A)` → `Theme.Colors.danger`,
`Color(hex: 0xFF9F0A)` → `Theme.Colors.warn`, `Color(hex: 0xE8B614)` →
`Theme.Colors.goldBright`, `Color(hex: 0x30D158)` → `Theme.Colors.ok`. If a
threshold needs a "fair" tier between gold and warn, introduce
`Theme.Colors.okSoft` in `Theme.swift` rather than reaching for raw hex.

**Verify**: grep `Color(hex: 0x[A-F0-9]+)` across `Views/`. The only legitimate
remaining call sites are export-only views (`*Export` structs) where light-mode
literals are intentional, and the `band.colorHex` / `tier.colorHex` data-driven
forms.

### 2.3 Unify the OS-version palette across in-app and export

**Problem**: `SecurityPostureView.osChart` uses SwiftUI Chart's auto-assigned
palette; `SecurityPostureOSDonutExport` uses a fixed Tailwind-ish palette
starting at blue. A user exports the donut and the colors don't match what they
were looking at.

**Where**: `Theme/ThemeSemanticTokens.swift` (add palette) →
`SecurityPostureView.osChart` + `SecurityPostureOSDonutExport` (consume).

**Change**: define `Theme.ChartPalette.osVersion: [Color]` (8–12 entries; pick
colors that read at small slice sizes in both surfaces). Pass it to the in-app
chart via `.chartForegroundStyleScale(domain: ordered, range: palette)` and
reference the same array (or its light counterpart, if you decide they need to
diverge for canvas legibility) in the export.

Same fix applies to `MobileFleetView` (in-app gold bars vs export `0xD97706`
orange) — pick one, not both.

**Verify**: export the macOS Version Distribution donut from Security Posture.
Drop the PNG next to the in-app card. Slice colors should match.

---

## Phase 3 — Cross-screen consistency

### 3.1 Migrate every hand-rolled empty state to `EmptyStateView`

**Problem**: only `CompliancePostureView` uses the shared `EmptyStateView`.
Eight other screens duplicate the pattern with subtly different sizing
(ProtectView title is 16pt; everywhere else is 15pt) and structure.

**Where**: `SecurityPostureView.emptyState`, `OutreachView.emptyState`,
`PatchView.emptyState`, `UpdatesView.emptyState`,
`PolicyProfileView.policyEmptyState`, `PolicyProfileView.profileEmptyState`,
`ExtensionAttributesView.emptyState`, `MobileFleetView.emptyState`,
`ProtectView.emptyState`.

**Change (step 1)**: extend `EmptyStateView` to support an optional inline
command block (ProtectView needs four `jamf-cli` lines). Add:

```swift
init(
    systemImage: String? = nil,
    title: String,
    message: String,
    commands: [String] = [],
    primaryAction: EmptyStateAction? = nil
)
```

Render commands as a `VStack` of `Mono` lines, padded above the action button.

**Change (step 2)**: convert every hand-rolled empty state to call
`EmptyStateView(…)`. Pick a single SF Symbol per screen that matches the
domain (e.g. `lock.shield` for Security Posture, `envelope` for Outreach,
`shippingbox` for Patch, `arrow.triangle.2.circlepath` for Updates, etc.).

**Verify**: open each screen with no data loaded. Title size, message size,
icon weight, padding should be identical across all nine empty states.

### 3.2 Align KPI grid `minimum` everywhere

**Problem**: Overview uses `.adaptive(minimum: 220)` per the recent pass; every
v3.5-port screen uses 180; ProtectView uses fixed `count: 3`. At 960pt this
produces visibly different tile widths between Overview and the posture
screens.

**Where**: every `LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, …)])`
call site in `Views/`. ProtectView's `kpiGrid` uses
`Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)`.

**Change**: lift the minimum to 220 across all KPI grids. Replace ProtectView's
fixed-3-columns with `[GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]`
so the empty trailing cell in the demo layout disappears.

**Verify**: open Overview and Security Posture side by side at 960pt width.
KPI tile widths should match.

### 3.3 Standardize "showing N of M" copy

**Problem**: same pattern phrased six ways: `"N of M shown"`, `"Showing N"`,
`"Showing first 30"`, `"Showing 50 of N"`, `"N total"`, `(silent)`.

**Where**: every `SectionHeader(title:, trailing:)` call across the dashboards
that signals a cap. Also `PolicyProfileView.findingsCard` (no signal at all)
and `MobileFleetView.profilesTable` (`"Showing first 30"`).

**Change**: pick one phrasing — recommend `"\(shown) of \(total)"` when capped,
omit trailing when complete. Update every call site. Add the trailing to
`PolicyProfileView.findingsCard` (currently silently caps at 100).

**Verify**: grep `Showing|shown|total` in `Views/*.swift`. The only remaining
SectionHeader trailings should match the one chosen pattern.

### 3.4 Separate the SectionHeader trailing variants

**Problem**: `SectionHeader.trailing` runs through `Kicker`, which uppercases
and applies `.tracking(0.6)`. Fine for tags like "Fleet-wide" or "By priority";
bad for proper names. `ExtensionAttributesView.valueDistributionCard` passes
`eaName` (e.g. "FileVault Status") which renders as "FILEVAULT STATUS" with
unnatural letter spacing.

**Where**: `Theme/Components.swift` `SectionHeader` definition.

**Change**: give `SectionHeader` two trailing slots:

```swift
SectionHeader(title:, trailingTag:)    // current behavior — uppercased kicker
SectionHeader(title:, trailingValue:)  // sentence-case, no tracking, fg2 color
```

Migrate the ExtensionAttributes value-distribution call to `trailingValue`.
Audit other call sites — anything that passes a count or entity name should be
`trailingValue`; anything that passes a label should stay as `trailingTag`.

**Verify**: open Extension Attributes, click an EA. The card header should
read "Value Distribution    FileVault Status" with the EA name in proper case,
not "FILEVAULT STATUS" in all-caps tracked mono.

### 3.5 Migrate hand-rolled tables to SwiftUI `Table`

**Problem**: `PolicyProfileView` (findings + profiles) and `UpdatesView`
(failed plans + error devices) hand-roll tables with HStack rows and
ad-hoc header styling. Other screens use `Table`. Three table dialects in one
product; the hand-rolled ones also break VoiceOver column semantics.

**Where**: `PolicyProfileView.findingsCard`, `PolicyProfileView.profileStatusCard`,
`UpdatesView.failedPlansCard`, `UpdatesView.errorDevicesCard`.

**Change**: convert each to SwiftUI `Table` with `TableColumn`. Use the
`PatchView.patchTitlesCard` table as the reference pattern.

If the multi-line rows in `UpdatesView` (where `error` can be 80+ chars and the
truncation is intentional) can't be expressed cleanly in `Table`, formalize the
hand-rolled form: extract a `DataTableHeader` / `DataTableRow` pair into
`Theme/Components.swift` and have both PolicyProfileView and UpdatesView
consume it. Don't keep three dialects.

**Verify**: tab through both screens with VoiceOver. Column headers should be
announced as table headers, not as static text in between rows.

### 3.6 Stop the export header's redundant `Spacer`

**Where**: `ExtensionAttributesView.valueDistributionCard` line ~313.

**Change**: remove the `Spacer()` between `SectionHeader(...)` and the Export
PNG `PNPButton(...)`. `SectionHeader` has an internal Spacer already; the
extra one pushes the trailing kicker hard left while the button hugs right.
Every other screen does `HStack { SectionHeader(...); PNPButton(...) }`.

### 3.7 Add Export PNG to the patch titles table

**Where**: `PatchView.patchTitlesCard`.

**Change**: add an Export PNG button in the section header trailing slot,
following the pattern from `CompliancePostureView.bandsHeroCard`. Build a
`PatchTitlesTableExport` view (light-mode, fixed 848×448) and route through
`DashboardChartExport.run(...)`. Patch is the headline "Excel sheet
replacement" view per its own doc comment — it should be exportable.

(Outreach and Policy & Profile findings are also export-worthy but lower
priority; do those in a follow-up.)

---

## Phase 4 — Polish

These are individually small. Batch them.

### 4.1 Unify the PNG export canvas templates

**Problem**: `DashboardExportCanvas` (the shared frame in
`DashboardChartExport.swift`) and `BarChartExportView` in ExtensionAttributesView
build different headers (serif 28 + mono kicker subtitle vs serif 30 + mono
date) and different footers (centered footnote vs left stat-callouts + source
line). Two export templates in one app.

**Where**: `DashboardChartExport.swift` + `ExtensionAttributesView.BarChartExportView`.

**Change**: extend `DashboardExportCanvas` to accept optional
`headerTrailing: AnyView` and `footerStats: [Stat]` slots so callers can fill
the stat-callout area without owning the title typography. Migrate
`BarChartExportView` to call through the canvas with those slots. Aim: a
strip of exports from different dashboards reads as one set.

### 4.2 Add timezone to export timestamp

**Where**: `DashboardChartExport.swift` `DashboardExportCanvas.timestamp()`.

**Change**: format as `yyyy-MM-dd HH:mm 'UTC'` and force `formatter.timeZone =
TimeZone(identifier: "UTC")`. A fleet operating across timezones currently
gets unlabeled local timestamps.

### 4.3 Sidebar hover state on nav rows

**Where**: `Sidebar.swift` `navItem`.

**Change**: add `@State var hoveredItem: Tab? = nil` to the sidebar; in
`navItem`, attach `.onHover { hoveredItem = $0 ? item : (hoveredItem == item ? nil : hoveredItem) }`
to the row body and tint the row background `Color.white.opacity(0.04)` when
`hoveredItem == item && !isActive`. The workspace chip already uses this
pattern — match it.

### 4.4 Sidebar avatar hue: spread adjacent letters

**Where**: `Sidebar.swift` `avatarHue(for:)`.

**Change**: `Double((first.value &* 47) % 360) / 360.0` instead of plain
`% 360 / 360`. Adjacent letters in the alphabet should diverge in hue. Avoid
the gold band (~0.10–0.18) by adding an offset that lands clear of brand
accent.

### 4.5 Avatar accessibility label uses two letters

**Where**: `Sidebar.swift` `workspaceAvatar`.

**Change**: the avatar visually shows `prefix(2)` of the profile name; the
`accessibilityLabel` says "Workspace \(initial)" with one letter. Use the
same two-letter monogram in both.

### 4.6 Date formatter handles spans > 90 days

**Where**: `ProtectView.formatCreatedDate(_:)`.

**Change**: switch to `RelativeDateTimeFormatter(unitsStyle: .abbreviated)`
for spans under 60 days and fall back to an absolute date (`yyyy-MM-dd`)
beyond that. "731d ago" on every Computer row in demo mode is unreadable.

### 4.7 ProtectView KPI sub line has no context

**Where**: `ProtectView.kpiGrid` — Web Protection / Full Disk Access /
Connected tiles.

**Change**: replace `sub: "83%"` with `sub: "10 of 12"` (or `"10 of 12 (83%)"`).
The "N of M" pattern matches Security Posture's KPI tiles.

### 4.8 ProtectView subtitle uses count fields, not arrays

**Where**: `ProtectView.subtitle`.

**Change**: when `snapshot.alerts.isEmpty && snapshot.criticalAlerts +
.highAlerts + .mediumAlerts + .lowAlerts > 0`, fall back to the count fields.
Currently the demo seeds counts but not the arrays, so the subtitle reads
"12 computers" while alert and insight cards render below — incoherent.

Bonus: rework the demo snapshot so it populates the same fields real data
populates, so the renderer is exercised consistently.

### 4.9 Remove the dead `actionItems.p2` "Reserved" tile

**Where**: `SecurityPostureView.actionItemsCard`.

**Change**: drop the P2 column from `actionItemsCard` until a real signal
feeds it. A permanently-zero "Reserved" tile reads as broken UI.

### 4.10 Drop the second `.onTapGesture` in EA coverage rows

**Where**: `ExtensionAttributesView.coverageRow`.

**Change**: the row declares `.onTapGesture` twice (lines ~243 and ~256). Keep
the outer one (covers the whole row including the bar). Delete the inner one.

### 4.11 Sparkline default color follows the delta trend

**Where**: `Theme/Components.swift` `StatTile`.

**Change**: when `deltaTrend == .down` and a sparkline is present, pass
`Theme.Colors.danger` to the Sparkline by default; when `.up`, pass
`Theme.Colors.ok`; when `.flat`, keep gold. The current default of always-gold
can put an upward gold spark next to a red downward delta on the same tile —
two contradictory signals.

---

---

## Phase 5 — Accessibility (best-effort inclusivity within dark mode)

The author wants to cover a broad set of visual disabilities without building a
second palette. Five hooks. All five tie into macOS system Accessibility
settings the user has *already* configured — you don't need an in-app toggle
for any of them.

Do not treat this as one omnibus commit. Each item is independently shippable
and independently verifiable.

### 5.1 Respect `Increase Contrast` system setting

**Problem**: Theme tokens are tuned for the median dark-mode case. A user with
low vision who enables *System Settings → Accessibility → Display → Increase
Contrast* expects fg to brighten, borders to strengthen, and subtle fills to
gain weight. Today nothing in JamfReports responds.

**Where**: `Theme/ThemeSemanticTokens.swift` (introduce the hook), and any
component that reads a token that should bump (`Theme/Components.swift`
Pill / Card / SegmentedControl / StatTile, `EmptyStateView`, `Sidebar`).

**Change**: introduce contrast-aware accessor helpers and switch consumers to
them. The cleanest shape is a `ViewModifier` that reads
`@Environment(\.colorSchemeContrast)` and overrides the surrounding tokens.
For a less invasive first pass, add accessor functions:

```swift
extension Theme.Text {
    static func tertiary(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Theme.Colors.fg2 : Theme.Colors.fgMuted
    }
}

extension Theme.Hairline {
    static func standard(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Theme.Colors.hairlineStrong : Theme.Colors.hairline
    }
}
```

Then in each consumer view, read the environment and pass it through:

```swift
@Environment(\.colorSchemeContrast) private var contrast
// …
.foregroundStyle(Theme.Text.tertiary(contrast))
```

Which token pairings to bump under `.increased`:

- `fgMuted` → `fg2` (drops a tier of dimness on captions / sub lines / table
  meta columns)
- `fgDisabled` → `fgMuted` (disabled controls become readable rather than
  ghosted)
- `hairline` → `hairlineStrong` (card and divider borders become visible)
- `Theme.Surface.high` (`Color.white.opacity(0.08)`) → `0.14`
- `Theme.Surface.interactive` (`Color.white.opacity(0.12)`) → `0.20`
- `Theme.Surface.input` (`Color.white.opacity(0.05)`) → `0.10`
- Pill backgrounds: bump tone opacity from `0.18 / 0.20 / 0.30` to
  `0.30 / 0.34 / 0.46` so chips remain legible at smaller sizes
- Sparkline area fill: bump the gradient stop from `0.25` to `0.40` so the
  curve has a stronger anchor

**Do not** invert anything to white-on-light. Stay dark-mode; just gain weight.

**Verify**: System Settings → Accessibility → Display → toggle *Increase
Contrast*. Switch between Security Posture, Updates, and Jamf Protect.
Captions and table meta columns should visibly darken-then-lighten as you
toggle; card borders should appear/disappear. Toggle back — default state
should be unchanged from today.

### 5.2 Respect `Reduce Transparency`

**Problem**: `.regularMaterial` (Sidebar background, workspace chip) and
`.ultraThinMaterial` (StatusBar) blur whatever is behind them. For users who
rely on consistent contrast — and for anyone with vestibular sensitivity who
finds the blur visually noisy — macOS exposes
`@Environment(\.accessibilityReduceTransparency)`. The app ignores it.

**Where**: `Sidebar.swift` (sidebar background + workspace chip), `Components.swift`
`StatusBar`, `Components.swift` `GlassPane`.

**Change**: read the env in each consumer and swap the material for an opaque
fill when reduced:

```swift
@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
// …
.background(reduceTransparency ? AnyShapeStyle(Theme.Colors.winBG2)
                                : AnyShapeStyle(.regularMaterial))
```

`GlassPane` is named for its glass effect but its only current caller is the
Schedules "next-up" callout. Have it fall back to a solid `Theme.Colors.winBG2`
fill with a slightly stronger border under reduced transparency, so the
callout still reads as elevated without the blur.

**Verify**: System Settings → Accessibility → Display → *Reduce Transparency*.
The sidebar should switch from translucent material to a flat dark fill.
Window chrome behind the sidebar should no longer bleed through.

### 5.3 Color-blind-safe severity redundancy

**Problem**: severity (and status) information is conveyed by hue alone. For a
user with deuteranopia (~6% of men), Critical red and High orange flatten to
nearly the same brown. The fix is **redundant encoding** — add a second
channel that doesn't rely on color discrimination.

**Where**: every place severity or status is rendered as a Pill, a horizontal
bar, or a colored numeric. Specifically:

- `Theme/Components.swift` Pill (already supports `icon:` — expand callers to
  use it)
- `ProtectView.severityPill`, `ProtectView.statusPill`, `ProtectView.alertSeverityBar`
- `PolicyProfileView.severityTone` call site (`findingsCard`)
- `OutreachView.tierKPIGrid` (the colored 4pt left-edge accent is already a
  redundant channel via position — leave as-is)
- `PatchView.complianceColor` numeric percentages — prefix or suffix the
  numeric with a tiny SF Symbol
- `UpdatesView.statusBar` slice labels in `Device Status Summary` — prefix
  status name with its icon

**Change**: introduce a `Theme.Severity` accessor that returns paired (color,
icon) values. Build on the severity ramp added in Phase 2.1:

```swift
extension Theme.Severity {
    var systemImage: String {
        switch self {
        case .critical: "exclamationmark.triangle.fill"
        case .high:     "exclamationmark.circle.fill"
        case .medium:   "info.circle.fill"
        case .low:      "circle.fill"
        }
    }
}
```

Then in every Pill call site that conveys severity or pass/fail/error status,
pass both `tone:` and `icon:`. Same for the severity bars in
`alertsBySeverityCard` and `compliancePosture.controlBar` — prefix the label
with the icon.

One shape note: severity bars in `alertsBySeverityCard` are sorted critical-
first, which is its *own* redundant signal via position. Preserve that
ordering invariant.

**Verify**: install Sim Daltonism (free, App Store) or use macOS *Accessibility
→ Display → Color Filters → Deuteranopia*. Walk through Protect, Policy &
Profile, Compliance Posture, Patch, Updates. Each severity / status indicator
should remain identifiable by icon alone with hue removed.

### 5.4 Audit dark-mode contrast against WCAG AA

**Problem**: many text-on-surface pairings in the Theme have never been
contrast-tested. The disabled token in particular is suspect.

**Where**: `Theme/Theme.swift` color definitions, plus every place a
foreground/background pair is composed (Pill foreground on Pill background,
table meta-column text on `winBG2`, etc.).

**Change**: produce a contrast matrix and surface failures. Have Claude Code:

1. Enumerate every (fg, bg) pair actually used in the codebase —
   `fg`, `fg2`, `fgMuted`, `fgDisabled`, `goldBright`, `Pill.fg` for each tone,
   plus their export-canvas counterparts — against `winBG`, `winBG2`, `winBG3`,
   `codeBG`, and the Pill background composites.
2. Compute WCAG 2.1 contrast ratio for each.
3. Flag every pair below **4.5:1** (AA Normal) for body text uses, and below
   **3:1** (AA Large) for headlines / large kicker uses.
4. Output the matrix as a markdown table in a new file
   `accessibility-audit.md` at the project root — not just a code comment, so
   the author can review the trade-offs.
5. For each failure, propose a token tweak that brings it above the threshold
   *without* recoloring (i.e. lighten `fgMuted` from `#8E8E93` toward `#A8A8AD`
   rather than introducing a new role).

Known suspects: `fgDisabled` (`#5A5A60`) on `winBG` is ~2.5:1, below AA Large
even for disabled. Pill `.gold` foreground (`goldBright #E8B614`) on the
composite gold-tinted Pill background is borderline.

**Do not** apply token changes from this audit silently. Open them as a
separate commit referencing the audit document so the visual diff is
inspectable.

**Verify**: re-run the matrix after changes and confirm every flagged pair
passes its threshold. Eyeball the screens that used the changed tokens —
`fgMuted` getting brighter affects almost every screen.

### 5.5 Adopt Dynamic Type for body text

**Problem**: most fonts are pinned (`.system(size: 12.5)`, `.system(size: 13)`).
Users on macOS who enable *System Settings → Displays → Larger Text* — or
who need the per-app font-size affordance — can't scale JamfReports. The
typographic identity (serif H1s + mono kickers + numeric KPIs) should stay
pinned because those carry brand; everything else should scale.

**Where**: every `.font(.system(size: …))` call in `Views/` and
`Theme/Components.swift` for non-display text.

**Change**: replace pinned sizes with semantic font tokens. SwiftUI's
semantic fonts (`.body`, `.callout`, `.footnote`, `.caption`, `.caption2`)
respect the system Dynamic Type setting. Approximate mapping:

- 13pt body / table cell text → `.callout`
- 12.5pt sub-line / caption-ish copy → `.footnote`
- 11.5pt help text / table meta columns → `.caption`
- 10.5pt mono kicker → **leave pinned** (typographic identity)
- Serif H1 (`PageHeader` title 26pt) → **leave pinned**
- Serif metrics (`StatTile.value` 32pt, `ScoreRing` 32pt) → **leave pinned**
- Mono `Theme.Fonts.mono(...)` calls → **leave pinned** for code / data /
  kicker uses; switch to `.callout(.monospaced)` where it's body copy in
  monospace (e.g. EmptyStateView command listings)

`Theme.Fonts` already declares semantic constants (`bodyText`, `label`,
`caption`) but most call sites bypass them. The migration is mechanical: grep
`.system(size:` and route through `Theme.Fonts.*` or the SwiftUI semantic
tokens.

This is the largest item in Phase 5 by line count. It's safe to ship
incrementally — do `StatTile.sub`, `FieldHelp`, `SectionHeader.title`, the
empty-state body text, and table cell text first. Defer per-screen fine
detail to a follow-up.

**Verify**: System Settings → Displays → Larger Text → raise to a noticeable
step. Body text in cards, table cells, and KPI sub lines should grow.
Serif headlines, mono kickers, and numeric metrics should *not* grow —
confirm those stay anchored.

---

## Out of scope for this pass

- TrendsView (54 kB; defer to a separate review).
- A real light-mode palette. Phase 5 covers visual disabilities without
  requiring one.
- Asset migration for sidebar group sticky-header behavior (the brief
  considers it optional).
- An in-app override for system Accessibility settings (Increase Contrast,
  Reduce Transparency, Dynamic Type). Users who need these have already
  enabled them at the OS level; an in-app duplicate adds maintenance burden
  without serving anyone new.

---

## Suggested commit structure

Group commits by phase so the diff is reviewable:

1. `theme: pill never wraps + fix call sites` (1.1)
2. `theme: empty state icon visibility` (1.2)
3. `theme: severity ramp tokens + protect view consumes them` (2.1)
4. `theme: replace hardcoded status color literals` (2.2)
5. `theme: shared os-version chart palette` (2.3)
6. `views: migrate empty states to EmptyStateView` (3.1)
7. `views: align KPI grid minimum across screens` (3.2)
8. `views: standardize "showing N of M" copy` (3.3)
9. `theme: separate SectionHeader trailing variants` (3.4)
10. `views: migrate hand-rolled tables to Table` (3.5)
11. `views: small layout fixes + patch export button` (3.6, 3.7)
12. `polish: export canvas + sidebar + dates + protect KPIs` (4.x as one or two
    commits)
13. `a11y: respect Increase Contrast` (5.1)
14. `a11y: respect Reduce Transparency` (5.2)
15. `a11y: color-blind-safe severity icons` (5.3)
16. `a11y: contrast audit + token tweaks` (5.4, two commits: audit file, then
    tweaks)
17. `a11y: adopt Dynamic Type for body text` (5.5)

After each phase, run the build and exercise demo mode for every screen
listed in that phase's "Verify" steps. Don't move on until verifies pass.
Phase 5 items also need the relevant macOS Accessibility setting toggled —
verify both states (enabled and disabled) for each.
