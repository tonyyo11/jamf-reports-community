# Accessibility Audit — WCAG 2.1 Contrast (Dark Theme)

Phase 5.4 of `design-review-fixes-2.md`. Audits every (foreground, background) text pair
used in the JamfReports macOS app dark theme against WCAG 2.1 contrast requirements. The
goal is to identify failing pairs and propose minimal token tweaks before any code change
is applied. **No source files were modified.**

## Methodology

For each pair, relative luminance is computed per WCAG 2.1: each sRGB channel is
linearized (`c ≤ 0.03928 → c/12.92`, else `((c+0.055)/1.055)^2.4`); luminance `L =
0.2126·R + 0.7152·G + 0.0722·B`. Contrast ratio is `(L_lighter + 0.05) / (L_darker +
0.05)`. For semi-transparent Pill backgrounds the foreground tone is alpha-composited
over the opaque parent (`winBG2`) in *linear* space (`L_out = α·L_fg + (1-α)·L_bg`)
before computing contrast.

Thresholds applied:

| Threshold | Rule |
|---|---|
| AA Normal | ≥ 4.5 — body text (<18 pt regular, <14 pt bold) |
| AA Large  | ≥ 3.0 — ≥18 pt regular or ≥14 pt bold |
| AAA Normal | ≥ 7.0 |

All app text labelled `mono(10.5)` (Kickers, Pills, table headers) is treated as
**AA Normal** territory — 10.5 pt semibold uppercase mono with tracking is well below
WCAG's "large text" cutoff of 14 pt bold.

## Token reference

Extracted verbatim from `Theme.swift` and `Components.swift`.

### Foregrounds

| Token | Hex | Luminance |
|---|---|---|
| `fg` | `#F2F2F7` | 0.8656 |
| `fg2` | `#D8D8DD` | 0.6890 |
| `fgMuted` | `#8E8E93` | 0.2720 |
| `fgDisabled` | `#5A5A60` | 0.1015 |
| `goldBright` | `#E8B614` | 0.5149 |
| `tealBright` | `#3A8A8A` | 0.2096 |
| Pill `.teal` fg | `#6DC0C0` | 0.4463 |
| Pill `.warn` fg | `#FFB340` | 0.5427 |
| Pill `.danger` fg | `#FF8077` | 0.3803 |
| `warn` (semantic) | `#FF9F0A` | 0.4642 |
| `danger` (semantic) | `#FF453A` | 0.2597 |

### Backgrounds (opaque)

| Token | Hex | Luminance |
|---|---|---|
| `winBG` | `#1D1D1F` | 0.0104 |
| `winBG2` | `#232326` | 0.0154 |
| `winBG3` | `#2A2A2E` | 0.0216 |
| `codeBG` | `#0E0F12` | 0.00476 |

### Pill composite backgrounds (computed over `winBG2`)

| Pill tone | Tint | α | Composite L |
|---|---|---|---|
| muted | white | 0.07 | 0.0843 |
| gold | `#C9970A` | 0.18 | 0.0747 |
| teal | `#2A6B6B` | 0.30 | 0.0476 |
| warn | `#FF9F0A` | 0.20 | 0.1052 |
| danger | `#FF453A` | 0.20 | 0.0643 |

## Contrast matrix — text foregrounds over opaque surfaces

Cells are contrast ratio · status. Statuses: **AAA** ≥7, **AA** ≥4.5, **AA-Lg** ≥3.0,
**FAIL** <3.0.

| fg \ bg | `winBG` | `winBG2` | `winBG3` | `codeBG` |
|---|---|---|---|---|
| `fg` | 14.59 · AAA | 14.04 · AAA | 13.45 · AAA | 15.66 · AAA |
| `fg2` | 11.71 · AAA | 11.27 · AAA | 10.81 · AAA | 12.56 · AAA |
| `fgMuted` | 4.99 · AA | 4.81 · AA | 4.62 · AA | 5.34 · AA |
| `fgDisabled` | 2.50 · **FAIL** | 2.41 · **FAIL** | 2.32 · **FAIL** | 2.66 · **FAIL** |
| `goldBright` | 8.93 · AAA | 8.60 · AAA | 8.25 · AAA | 9.57 · AAA |
| `tealBright` | 3.97 · AA-Lg | 3.83 · AA-Lg | 3.68 · AA-Lg | 4.25 · AA-Lg |

Usage notes:

- `fg` — primary body, serif H1, KPI value, segmented selected (`fg2` on inactive segments)
- `fg2` — section subtitle, field labels, status bar value (StatusBar), selected-row meta
- `fgMuted` — Kicker `.muted` tone, StatTile sub line, table column headers, FieldHelp, EmptyStateView message, Mono inline default, `EditableNumberStepper` prefix/suffix
- `fgDisabled` — `TokenColors.text.disabled` only (semantic token); not currently bound to a rendered text site I can locate. Still failing if ever drawn on any of the three winBG tiers.
- `goldBright` — Kicker `.gold` tone (Pill `.gold` fg uses same token), ghost button label, PageHeader staleness label fallback
- `tealBright` — Kicker `.teal` tone only (PageHeader staleness when teal kicker)

## Contrast matrix — Pills

Pill text is `mono(10.5, semibold)` uppercase with `tracking(0.6)`. Treat as **AA Normal**.

| Pill tone | fg | bg composite | Ratio | Status |
|---|---|---|---|---|
| muted | `fgMuted` `#8E8E93` | white @ 0.07 over winBG2 | 2.40 | **FAIL** |
| gold | `goldBright` `#E8B614` | gold `#C9970A` @ 0.18 | 4.53 | AA |
| teal | `#6DC0C0` | teal `#2A6B6B` @ 0.30 | 5.09 | AA |
| warn | `#FFB340` | warn `#FF9F0A` @ 0.20 | 3.82 | AA-Lg only — **FAIL AA Normal** |
| danger | `#FF8077` | danger `#FF453A` @ 0.20 | 3.77 | AA-Lg only — **FAIL AA Normal** |

Note: `colorSchemeContrast == .increased` raises Pill bg opacity (muted 0.07→0.12, gold
0.18→0.30, teal 0.30→0.46, warn 0.20→0.34, danger 0.20→0.34). For warn / danger this
*lowers* contrast (the lighter chip background eats more of the bright fg's luminance
gap), making the increased-contrast path mildly worse than the base path. Worth a second
look when fixing these tones.

## Failures (with proposed token tweaks)

Each proposal preserves the existing role and palette intent; none introduces a new
semantic token.

### 1. `fgDisabled` on every surface — 2.32–2.66 (FAIL all tiers including AA Large)

Current `#5A5A60` is too dark for any rendered text on the dark surfaces. The role is
"disabled label." Two paths:

- **AA Large only (preserves disabled visual distance from `fgMuted`)**: lighten to
  **`#6F6F75`** → L = 0.157 → ratio **3.17** on winBG2 (passes AA Large). Adequate if
  disabled labels are always paired with ≥14 pt bold or ≥18 pt regular type.
- **AA Normal (recommended, covers any size)**: lighten to **`#8A8A90`** → L = 0.256 →
  ratio **4.68** on winBG2. This brings `fgDisabled` very close to `fgMuted` (#8E8E93);
  if the role still needs to read as "disabled" the differentiation should come from
  *opacity* on the parent view (e.g. `.opacity(0.6)`) rather than a dimmer base token.

Recommend `#8A8A90` plus revisiting whether `fgDisabled` as a separate token is still
justified — it is currently bound only inside `ThemeSemanticTokens.swift` and has no
known rendered call site.

### 2. Pill `.muted` — fgMuted on white-7% — 2.40 (FAIL AA Normal)

Pill text is small. The muted fg should match the chip's elevated surface tone.
Proposal: bind Pill `.muted` fg to **`fg2` `#D8D8DD`** → ratio **5.50** on the composite
bg. This keeps the chip readable while still feeling "muted" against the surrounding
`fgMuted` body context.

### 3. Pill `.warn` — #FFB340 on warn @ 0.20 — 3.82 (FAIL AA Normal)

Lighten fg to **`#FFCE7A`** → L = 0.663 → ratio **4.59** on the composite bg.
Maintains the warm amber identity; brightens just enough to clear AA Normal at 10.5 pt.

### 4. Pill `.danger` — #FF8077 on danger @ 0.20 — 3.77 (FAIL AA Normal)

Lighten fg to **`#FFA39A`** → L = 0.502 → ratio **4.83** on the composite bg.
Preserves the warm coral identity; the lift to ~63% lightness is small visually but
crosses the AA Normal threshold.

### 5. `tealBright` (`#3A8A8A`) on winBG2 — 3.83 (AA Large only)

Used in Kicker `.teal` tone at 10.5 pt — **fails AA Normal**. Lighten to **`#4FAAAA`**
→ L = 0.335 → ratio **5.89** on winBG2. Keeps the teal identity readable as small mono
uppercase. If the Kicker treatment is ever bumped to ≥14 pt bold the current value is
fine.

## Suspects called out explicitly in the plan

- **`fgDisabled` on `winBG`** — confirmed failing at **2.50:1**. See Failure 1.
- **Pill `.gold` fg (`goldBright`) on Pill `.gold` bg composite** — passes at **4.53:1**
  (AA). Marginal — would benefit from a defensive bump (`goldBright` → `#F1C42E` →
  L≈0.575 → ratio ≈ 5.01) but not strictly required by WCAG 2.1.

## Summary

- Pairs audited: **34** (24 fg×bg + 5 Pill + 5 enhanced-contrast Pill variants spot-checked)
- Failures: **8** rendered cells across 5 distinct roles (`fgDisabled` × 4 surfaces, Pill
  muted, Pill warn, Pill danger, `tealBright` AA-Normal).

Most consequential, in order of breadth of use:

1. **Pill `.muted` text (2.40:1)** — Pills are used across nearly every screen (Devices,
   Reports, Schedules, Overview, Posture, Patch, Updates). The muted tone is the default
   chip, so this failure is the single most visible.
2. **`tealBright` Kicker `.teal` (3.83:1, fails AA Normal)** — Kickers head every page
   and section card; teal tone is used wherever a non-gold accent is wanted.
3. **Pill `.warn` and `.danger` (3.82 / 3.77:1)** — these are the badges that carry the
   risk/severity signal; failing AA Normal on the very chips designed to grab attention
   is the worst kind of accessibility regression. They should be fixed together with the
   muted pill.

`fgDisabled` is included as a known dark token but no live render site was found; it is
listed as a failure for completeness and should likely be re-evaluated rather than
patched.
