# jamf-reports-community: jamf-cli v1.5.0 Review Report

**Date:** 2026-04-08  
**Reviewer:** Claude Code (automated analysis)  
**Branch:** `claude/jamf-cli-v1.5-review-vXBnK`  
**Script analyzed:** `jamf-reports-community.py` (4,493 lines)

---

## Executive Summary

**jamf-reports-community is safe to upgrade to jamf-cli v1.5.0 with no code changes required.**
All subprocess calls explicitly pass `--output json`, so the v1.5.0 change of XML as the default output format is a non-issue. The generic name-field detection (PR #89) and cookie-jar/session persistence improvements (PR #88, #93) are fully transparent to consumer code. No blocking compatibility issues were identified.

Code quality is strong overall: exception handling is thorough and well-chained, `_safe_write()` is used consistently for all user-sourced data, and defensive JSON parsing guards every jamf-cli response. The primary quality concerns are a handful of hard-coded thresholds that should be config-driven, a repeated envelope-extraction pattern that should become a helper function, and the absence of multi-CSV column-compatibility validation before `pd.concat()`.

**Finding counts:** 0 blocking compatibility issues · 1 medium production risk · 3 low/medium quality issues · 4 refactoring opportunities · 1 enhancement opportunity (v1.5.0 feature).

---

## Compatibility Assessment

### Current jamf-cli Version Constraint

- **requirements.txt:** Lists Python dependencies only (`xlsxwriter`, `pandas`, `pyyaml`, `matplotlib`). jamf-cli is a separate CLI tool, not a Python package, so it is not tracked in `requirements.txt`.
- **Code-level version requirement:** Implicitly v1.2.0+ (minimum version that supports `pro report` subcommands). The `patch_device_failures()` method (line 1101) documents "Requires jamf-cli v1.4.0+." No hard version check exists in code; instead, `_require_report_command()` tests whether the report subcommand is advertised in `pro report --help`.
- **Recommendation:** No version bump needed in `requirements.txt`. Update `COMMUNITY_README.md` to note that jamf-cli ≥ v1.5.0 is recommended for reliability improvements (cookie jar, token caching) while ≥ v1.4.0 is the functional minimum for Patch Failures sheet.

### New Features in v1.5.0

- **[✅ Transparent] Generic name-field detection (PR #89)**
  All JSON field access in jamf-reports-community uses `.get(key, default)` with safe fallbacks. If jamf-cli changes how it names internal schema fields, the consumer code is insulated. No field-name assumptions in the parsing code are fragile to this change.

- **[✅ Transparent benefit] Cookie jar + disk token cache (PR #88, #93)**
  jamf-reports-community spawns a fresh `subprocess.run()` per command — it does not maintain a long-lived jamf-cli process. Under v1.5.0, each spawned process will reuse the persisted token/cookie automatically, reducing re-authentication round-trips in `collect` runs that invoke 11+ commands sequentially. No code changes needed; this is a free reliability improvement.

- **[⚠️ Opportunity] `classic patch-report` (PR #86)**
  The new `classic patch-report` command targets the Jamf Classic API and produces patch management data in a different shape from the existing `pro report patch-status` (Pro API). The current Patch Compliance sheet consumes `pro report patch-status --output json`, which remains the correct command for Pro API data. The Classic patch-report could provide legacy-patch-title coverage not in the Pro API, but integrating it would require understanding its JSON schema and merging two data sources. **Recommendation:** Leave as a tracked enhancement; do not block on it.

- **[✅ Not applicable] `account-group`, `user`, `flush-commands` (PR #86, #93)**
  These commands operate on Jamf user accounts and MDM command queues — outside the computer-reporting scope of this tool.

- **[✅ Explicit JSON flag — no XML risk]**
  Line 940: `cmd = [self._binary, "--output", "json", "--no-input"]`
  Every jamf-cli invocation prepends `--output json` before any subcommand arguments. The v1.5.0 change to XML-as-default for Classic API commands has zero impact.

---

## Code Quality Findings

### Production Bug Risks (Correctness & Logic)

#### 🔴 Medium Risk: Multi-CSV `pd.concat()` Silently Promotes Column Mismatches

**Location:** Lines 2329–2343 (`CSVDashboard.__init__`)

```python
for extra_path in extra_csv_paths:
    try:
        extra_df = pd.read_csv(extra_path, dtype=str, encoding="utf-8-sig").fillna("")
        extra_df["CSV Source"] = Path(extra_path).name
        frames.append(extra_df)
    except Exception as exc:
        print(f"  [warn] Could not read extra CSV '{extra_path}': {exc} — skipping")
self._df = pd.concat(frames, ignore_index=True).fillna("")
```

**Issue:** When CSVs from different Jamf Pro exports have different column sets (e.g., one export includes `Filevault 2 Status` and another does not), `pd.concat()` silently creates a union of columns and fills gaps with `NaN`, which `fillna("")` then converts to empty strings. Downstream column-mapping code (`ColumnMapper.extract()`) will appear to succeed but return empty values for the mismatched export, producing a partially-correct report with no error.

**Impact:** Silent data loss in multi-CSV merge workflows. User sees a report but with unexpectedly empty columns for devices from one source.

**Fix:** After `pd.concat()`, compare column sets across frames and emit a warning listing columns present in some but not all CSVs:

```python
all_cols = [set(f.columns) for f in frames]
union = set.union(*all_cols)
for i, cols in enumerate(all_cols):
    missing = union - cols
    if missing:
        print(f"  [warn] CSV {i+1} is missing columns present in other CSVs: {missing}")
self._df = pd.concat(frames, ignore_index=True).fillna("")
```

---

#### 🟡 Low Risk: Hard-Coded Severity Thresholds in Profile Health Sheet

**Location:** Lines 2009–2010, 2023 (`CoreDashboard._write_profile_status`)

```python
fmt = self._fmts["red"] if errors >= 50 else (
    self._fmts["yellow"] if errors >= 10 else self._fmts["cell"]
)
# ...
_safe_write(ws, row, 0, "Devices with High Failure Count (>5 errors)", self._fmts["header"])
```

**Issue:** The thresholds 50 (red), 10 (yellow), and 5 (device failure cutoff) are hard-coded. Organizations with fleets of different sizes will have different definitions of "high". The same pattern appears in `_write_app_status()` (lines 2198–2199).

**Impact:** False positives/negatives in the Profile Health and App Status sheets for orgs with large or small fleets. Not data-corrupting but reduces report accuracy.

**Fix:** Add to `thresholds` config block:
```yaml
thresholds:
  profile_error_critical: 50
  profile_error_warning: 10
  profile_device_failure_min: 5
```
And read via `self._config.thresholds.get("profile_error_critical", 50)`.

---

#### 🟡 Low Risk: `computers_list()` Bypasses Cache/Save Infrastructure

**Location:** Line 1135 (`JamfCLIBridge.computers_list`)

```python
def computers_list(self) -> Any:
    """Fetch the lightweight computer inventory index from jamf-cli pro computers list."""
    return self._run(["pro", "computers", "list"])
```

**Issue:** Every other data-fetching method uses `_run_and_save()`, which saves output to disk and supports fallback to cached JSON when live calls fail. `computers_list()` calls `_run()` directly — no caching, no fallback. This method is used by `cmd_inventory_csv()` for the `inventory-csv` command, so if the live call fails, the entire inventory export fails with no graceful degradation.

**Impact:** No fallback for `inventory-csv` command; cannot be run offline.

**Fix:** Route through `_run_and_save()`:
```python
def computers_list(self) -> Any:
    return self._run_and_save(
        "computers-list",
        ["pro", "computers", "list"],
        ["computers-list", "computers_list"],
    )
```

---

### Code Duplication & Refactoring Opportunities

#### Refactor 1: Repeated Envelope Extraction (4 occurrences)

**Locations:** Lines 1909, 1966, 2155, 2236

```python
# Identical pattern repeated in _write_policy, _write_profile_status,
# _write_app_status, _write_update_status:
envelope = (raw[0] if isinstance(raw, list) and raw else raw) or {}
if not isinstance(envelope, dict) or not envelope:
    ...
```

**Fix:** Extract a module-level or `CoreDashboard`-level helper:
```python
def _extract_envelope(raw: Any) -> dict:
    """Unwrap single-element list response and return a dict, or empty dict if invalid."""
    node = raw[0] if isinstance(raw, list) and raw else raw
    return node if isinstance(node, dict) and node else {}
```

Then replace all four occurrences with:
```python
envelope = _extract_envelope(self._bridge.policy_status())
if not envelope:
    ...
```

---

#### Refactor 2: Repeated Device Name Extraction from DataFrame Row (6+ occurrences)

**Locations:** Lines 2645, 2667, 2700, 2735, 2756, and others in `_ea_*` methods

```python
# Repeated 6+ times across _ea_boolean, _ea_percentage, _ea_version, _ea_date:
nm = str(dr[name_col]) if name_col and name_col in dr.index else ""
```

**Fix:** Add a helper method to `CSVDashboard`:
```python
def _device_name(self, row: Any) -> str:
    """Extract computer name from a DataFrame row using configured column."""
    col = self._col("computer_name")
    return str(row[col]) if col and col in row.index else ""
```

---

#### Refactor 3: Repeated Severity Format Selection

**Locations:** Lines 2009–2010 (Profile Status), 2198–2199 (App Status), and similar in `_write_update_status`

```python
fmt = self._fmts["red"] if value >= high else (
    self._fmts["yellow"] if value >= low else self._fmts["cell"]
)
```

**Fix:** Add a helper to `CoreDashboard`:
```python
def _severity_fmt(self, value: int, warn: int, crit: int) -> Any:
    """Return red/yellow/normal format based on integer value vs thresholds."""
    if value >= crit:
        return self._fmts["red"]
    if value >= warn:
        return self._fmts["yellow"]
    return self._fmts["cell"]
```

---

#### Refactor 4: Repeated `_require_column()` Guard

**Locations:** Lines 2394–2395, 2431–2432, 2550–2551, 2596–2597

```python
if not name_col:
    raise RuntimeError("computer_name column not configured")
```

**Fix:** Extract a method:
```python
def _require_col(self, field: str) -> str:
    """Return configured column name for field, or raise RuntimeError if unset."""
    col = self._col(field)
    if not col:
        raise RuntimeError(f"'{field}' column not configured in config.yaml")
    return col
```

---

### Error Handling & Robustness

**Strengths (no action needed):**
- `_run()` (line 940–959): Catches `TimeoutExpired`, `PermissionError`, `CalledProcessError`, and `JSONDecodeError` individually with descriptive messages and proper exception chaining (`from e`/`from exc`).
- `_run_and_save()` (lines 1040–1048): Falls back to cached JSON on `RuntimeError` and chains both error messages for debugging.
- Sheet-level exception isolation (lines 2367–2370): Each sheet's write method is called inside a try/except that catches `KeyError`, `ValueError`, `RuntimeError` individually, then a broad fallback with type name. A single failing sheet does not abort the workbook.
- `pd.read_csv(..., dtype=str, encoding="utf-8-sig").fillna("")` ensures all columns are strings and all nulls become empty strings, making `.str.strip()` safe throughout `CSVDashboard`.

**Minor gap:**
- `_report_commands()` (lines 864–907) catches `subprocess.SubprocessError` and `PermissionError` and degrades to an empty set. This is intentional and documented, but a debug-level log line would help users troubleshoot "why is my report missing columns" without a stack trace.

---

### Type Safety & Maintainability

**Strengths:**
- All public method signatures carry type hints.
- `Config.get(*keys, default=None)` provides safe nested dict traversal — no bare `config["key"]["subkey"]` throughout the codebase.
- `_safe_write()` (lines ~182–205) defends against None, NaN/inf, control characters, formula injection, and oversized strings. Static labels use direct `ws.write()` — this distinction is consistently respected.

**Note:**
- `Config.thresholds` (and similar properties) returns `self._data.get("thresholds", {})`. If a user accidentally sets `thresholds: null` in config.yaml, this returns `None`, and downstream `.get()` calls on it will raise `AttributeError`. A defensive `or {}` guard would prevent this:
  ```python
  @property
  def thresholds(self) -> dict:
      return self._data.get("thresholds") or {}
  ```
  (Same consideration applies to `compliance`, `charts`, `output` properties.)

---

### Testability

The current design is function-and-class-based with injectable config and bridge objects. `JamfCLIBridge` can be replaced with a mock that returns pre-loaded JSON. `CSVDashboard` and `CoreDashboard` accept their data objects at construction time. This architecture is friendly to future unit tests.

**Gap:** `cmd_generate()` (lines 3892–4085) is 200 lines and mixes orchestration logic, file I/O, archive management, and error handling. If a test suite is added, this function should be split into a pure orchestration function (calls dashboard methods, returns a result) and a thin I/O wrapper (file naming, archiving, notification).

---

## Recommendations

### Must-Do (Production Risk)

1. **Warn on multi-CSV column mismatches** (lines 2329–2343): Before `pd.concat()`, compare column sets across frames and print a warning listing columns that differ. This prevents silent data loss when merging exports from environments with different EA configurations.

### Should-Do (Quality)

2. **Route `computers_list()` through `_run_and_save()`** (line 1135): Gives the `inventory-csv` command the same offline fallback and disk-caching behavior as all other jamf-cli calls.

3. **Make Profile/App Status thresholds configurable** (lines 2009–2010, 2023, 2198–2199): Add `profile_error_critical`, `profile_error_warning`, `profile_device_failure_min` to `thresholds` config block; default values preserve current behavior.

4. **Guard `Config` property returns against `null` YAML values**: Add `or {}` to `thresholds`, `compliance`, `charts`, and `output` properties to prevent `AttributeError` when users set these sections to `null` in config.yaml.

### Nice-to-Have (Refactoring & Enhancement)

5. **Extract `_extract_envelope()` helper** (lines 1909, 1966, 2155, 2236): Eliminates 4 identical one-liner patterns and clarifies the unwrapping intent.

6. **Extract `_device_name(row)` method on `CSVDashboard`** (6+ call sites): Eliminates repeated inline logic for optional column access.

7. **Extract `_severity_fmt(value, warn, crit)` method on `CoreDashboard`** (3+ call sites): Centralizes red/yellow/normal format selection.

8. **Extract `_require_col(field)` method on `CSVDashboard`** (4 call sites): Standardizes the "column not configured" error message.

9. **Evaluate `classic patch-report` (v1.5.0)**: If Classic API patch data complements the existing `pro report patch-status` output (e.g., software titles not yet migrated to Pro API), a follow-up issue could integrate it as an optional supplemental sheet.

---

## Code Quality Scorecard

| Dimension | Rating | Notes |
|-----------|--------|-------|
| **Correctness** | ✅ Good | Defensive JSON parsing throughout; `dtype=str` CSV loading; proper `>=`/`<` threshold operators; UTC-consistent date math |
| **Maintainability** | ⚠️ Needs work | 4 refactoring opportunities (envelope extraction, device name, severity fmt, require_col); hard-coded thresholds; 200-line `cmd_generate()` |
| **Testability** | ⚠️ Needs work | Injectable bridge/config is test-friendly; `cmd_generate()` mixes orchestration + I/O; no test suite yet |
| **Standards** | ✅ Good | PEP 8 compliant; type hints on all signatures; Google-style docstrings; no bare `except:`; specific exception types caught first |
| **Security** | ✅ Good | `_safe_write()` used for all user data; subprocess args built as lists (no shell injection); no hardcoded credentials or org-specific values |
| **Overall** | **7.5/10** | Solid production-quality foundation with targeted refactoring needed in maintainability and testability dimensions |

---

## Strengths

- **Graceful degradation:** jamf-cli is never required. `JamfCLIBridge.is_available()` is checked before every call; CSV-only mode works fully without jamf-cli installed.
- **Safe write discipline:** `_safe_write()` is applied consistently to all user-sourced cell values; formula injection, control characters, and oversized strings are all sanitized.
- **Exception chaining:** `raise X from Y` throughout the codebase preserves root cause context in tracebacks.
- **Atomic file writes:** `_run_and_save()` writes to a `.partial` temp file and renames — no half-written JSON snapshots on failure.
- **Dynamic command discovery:** `_require_report_command()` tests availability via `pro report --help` rather than hard-coding a version gate, making the tool forward-compatible with new jamf-cli report additions.
- **Config-driven extensibility:** Custom EA types, security agents, and compliance columns are all driven by `config.yaml` with no org-specific values in code.
- **Explicit output format:** `--output json` is prepended to every subprocess call (line 940), making the tool immune to default-format changes in future jamf-cli versions.

---

## Appendix: Code Sections Reviewed

| Section | Lines | Notes |
|---------|-------|-------|
| `DEFAULT_CONFIG` | 55–130 | Full config schema |
| `JamfCLIBridge._run()` | 924–959 | Primary subprocess invocation |
| `JamfCLIBridge._run_and_save()` | 1023–1061 | Cache/save/fallback logic |
| `JamfCLIBridge._report_commands()` | 864–907 | Dynamic command discovery |
| `JamfCLIBridge.patch_device_failures()` | 1098–1113 | v1.4.0+ feature |
| `JamfCLIBridge.computers_list()` | 1133–1135 | Identified caching gap |
| `CoreDashboard._write_policy/profile/app/update` | 1904–2290 | Envelope extraction pattern × 4 |
| `CoreDashboard._write_profile_status` | 1957–2020 | Hard-coded thresholds |
| `CSVDashboard.__init__` | 2310–2350 | Multi-CSV concat, column compatibility |
| `CSVDashboard._ea_boolean/percentage/version/date` | 2615–2760 | Device-name extraction pattern |
| `cmd_generate()` | 3892–4091 | Orchestration function complexity |
| `Config` properties | 657–759 | Safe access patterns, null-guard gap |
