#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""jamf-reports-community.py — Community Jamf Pro reporting tool.

Generates Excel reports from jamf-cli output and optional CSV exports.
Config-driven: no org-specific values are hardcoded.

Requirements: Python 3.9+, xlsxwriter, pandas, pyyaml, matplotlib (optional)
Usage:
    python3 jamf-reports-community.py generate [--config config.yaml] [--csv path/to/export.csv]
                                               [--historical-csv-dir path/to/snapshots/]
    python3 jamf-reports-community.py collect [--config config.yaml] [--csv path/to/export.csv]
                                              [--historical-csv-dir path/to/snapshots/]
    python3 jamf-reports-community.py inventory-csv [--config config.yaml]
                                                    [--out-file path/to/inventory.csv]
    python3 jamf-reports-community.py scaffold [--csv path/to/export.csv] [--out config.yaml]
    python3 jamf-reports-community.py check [--csv path/to/export.csv]
"""

import argparse
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

import pandas as pd
import xlsxwriter
import yaml

plt: Any = None
mdates: Any = None
HAS_MATPLOTLIB: Optional[bool] = None

pptx_Presentation: Any = None   # pptx.Presentation class, set by _load_pptx()
pptx_Inches: Any = None          # pptx.util.Inches
pptx_Pt: Any = None              # pptx.util.Pt
HAS_PPTX: Optional[bool] = None


# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

DEFAULT_CONFIG: dict[str, Any] = {
    "columns": {
        "computer_name": "",
        "serial_number": "",
        "operating_system": "",
        "last_checkin": "",
        "department": "",
        "manager": "",
        "email": "",
        "filevault": "",
        "sip": "",
        "firewall": "",
        "gatekeeper": "",
        "secure_boot": "",
        "bootstrap_token": "",
        "disk_percent_full": "",
        "architecture": "",
        "model": "",
        "last_enrollment": "",
        "mdm_expiry": "",
    },
    "security_agents": [],
    "jamf_cli": {
        "data_dir": "jamf-cli-data",
        "profile": "",
        "use_cached_data": True,
        "allow_live_overview": True,
    },
    "compliance": {
        "enabled": False,
        "failures_count_column": "",
        "failures_list_column": "",
        "baseline_label": "mSCP Compliance",
    },
    "custom_eas": [],
    "thresholds": {
        "stale_device_days": 30,
        "critical_disk_percent": 90,
        "warning_disk_percent": 80,
        "cert_warning_days": 90,
        "profile_error_critical": 50,
        "profile_error_warning": 10,
    },
    "output": {
        "output_dir": "Generated Reports",
        "timestamp_outputs": True,
        "archive_enabled": True,
        "archive_dir": "",
        "keep_latest_runs": 10,
        "export_pptx": False,
    },
    "charts": {
        "enabled": True,
        "save_png": True,
        "embed_in_xlsx": True,
        "historical_csv_dir": "",
        "archive_current_csv": True,
        "os_adoption": {
            "enabled": True,
            "per_major_charts": True,
        },
        "compliance_trend": {
            "enabled": True,
            "bands": [
                {"label": "Pass", "min_failures": 0, "max_failures": 0, "color": "#4472C4"},
                {"label": "Low (1-10)", "min_failures": 1, "max_failures": 10, "color": "#2E9E7D"},
                {"label": "Med-Low (11-30)", "min_failures": 11, "max_failures": 30,
                 "color": "#FFCA30"},
                {"label": "Medium (31-50)", "min_failures": 31, "max_failures": 50,
                 "color": "#F07C21"},
                {"label": "High (>50)", "min_failures": 51, "max_failures": 9999,
                 "color": "#C0392B"},
            ],
        },
        "device_state_trend": {
            "enabled": True,
        },
    },
}

# Fuzzy-match candidates for scaffold auto-detection
COLUMN_HINTS: dict[str, list[str]] = {
    "computer_name": ["computer name", "device name", "hostname", "name"],
    "serial_number": ["serial number", "serial", "serialnumber"],
    "operating_system": ["operating system version", "operating system", "macos version"],
    "last_checkin": ["last check-in", "last checkin", "last contact", "checkin"],
    "department": ["department", "dept"],
    "manager": ["manager", "managed by", "direct manager"],
    "email": ["email address", "email", "e-mail"],
    "filevault": ["filevault 2 status", "filevault 2 - status", "filevault status", "filevault"],
    "sip": ["system integrity protection", "sip"],
    "firewall": ["firewall", "firewall enabled", "fw"],
    "gatekeeper": ["gatekeeper"],
    "secure_boot": ["secure boot level", "secure boot"],
    "bootstrap_token": ["bootstrap token escrowed", "bootstrap token is escrowed"],
    "disk_percent_full": ["boot drive percentage full", "percentage full", "disk percent full"],
    "architecture": ["architecture", "arch", "cpu type"],
    "model": ["model", "hardware model", "device model"],
    "last_enrollment": ["last enrollment", "enrollment date", "enrolled"],
    "mdm_expiry": ["mdm profile expiration date", "mdm expiry", "profile expiration date"],
}

COLUMN_EXCLUDES: dict[str, list[str]] = {
    "manager": ["managed", "unmanaged"],
    "secure_boot": ["external boot"],
    "bootstrap_token": ["allowed"],
    "disk_percent_full": ["available mb", "capacity mb", "free mb"],
}


# ---------------------------------------------------------------------------
# Module-level helpers
# ---------------------------------------------------------------------------


def _safe_write(
    worksheet: xlsxwriter.workbook.Worksheet,
    row: int,
    col: int,
    value: Any,
    fmt: Optional[xlsxwriter.workbook.Format] = None,
) -> None:
    """Write a value to a worksheet cell with sanitization.

    Args:
        worksheet: Target xlsxwriter worksheet.
        row: Zero-based row index.
        col: Zero-based column index.
        value: Value to write; sanitized before writing.
        fmt: Optional xlsxwriter format object.
    """
    if value is None:
        worksheet.write_blank(row, col, None, fmt)
        return

    if isinstance(value, float):
        if not (value == value) or value in (float("inf"), float("-inf")):  # noqa: PLR0124
            value = 0

    if isinstance(value, str):
        value = "".join(
            ch for ch in value if unicodedata.category(ch)[0] != "C" or ch in ("\n", "\t")
        )
        value = value[:32000]
        if value.lstrip() and value.lstrip()[0] in ("=", "+", "-", "@"):
            if fmt:
                worksheet.write_string(row, col, value, fmt)
            else:
                worksheet.write_string(row, col, value)
            return

    if fmt:
        worksheet.write(row, col, value, fmt)
    else:
        worksheet.write(row, col, value)


def _parse_manager(raw_value: Any) -> str:
    """Extract a human-readable name from an AD DN or plain string.

    Args:
        raw_value: Raw manager field value from CSV.

    Returns:
        Plain display name, or empty string if blank/invalid.
    """
    if raw_value is None:
        return ""
    if isinstance(raw_value, float) and (raw_value != raw_value):
        return ""
    s = str(raw_value).strip()
    if not s:
        return ""
    # AD DN: CN=SMITH\, JOHN,OU=...  (backslash-comma escapes commas inside the CN value)
    match = re.match(r"CN=((?:[^,\\]|\\,)+)", s, re.IGNORECASE)
    if match:
        cn = match.group(1).replace("\\,", ",").strip()
        return cn.title()
    return s


def _now_ts() -> str:
    """Return current UTC timestamp as a compact string."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%S%f")


def _file_stamp() -> str:
    """Return a local timestamp string suitable for output filenames."""
    return datetime.now().strftime("%Y-%m-%d_%H%M%S")


def _path_has_timestamp(path: Path) -> bool:
    """Return True when the path stem already contains a date/time stamp."""
    return bool(re.search(r"\d{4}-\d{2}-\d{2}(?:[_T]\d{4,6})?", path.stem))


def _timestamped_output_path(path: Path, stamp: str, enabled: bool) -> Path:
    """Append a timestamp to a path unless timestamping is disabled or already present."""
    if not enabled or _path_has_timestamp(path):
        return path
    if path.suffix:
        return path.with_name(f"{path.stem}_{stamp}{path.suffix}")
    return path.with_name(f"{path.name}_{stamp}")


def _filename_component(text: str) -> str:
    """Return a filesystem-friendly label component."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", str(text).strip())
    cleaned = re.sub(r"_+", "_", cleaned).strip("._")
    return cleaned or "jamf_report"


def _strip_timestamp_suffix(stem: str) -> str:
    """Remove a trailing date/time stamp from a filename stem when present."""
    return re.sub(r"[_-]\d{4}-\d{2}-\d{2}(?:[_T]\d{4,6})?$", "", stem)


def _run_group_prefix(stem: str, family_base: str) -> str:
    """Return a per-run grouping prefix for a timestamped output stem."""
    escaped = re.escape(family_base)
    pattern = rf"^({escaped}_\d{{4}}-\d{{2}}-\d{{2}}(?:[_T]\d{{4,6}})?)"
    match = re.match(pattern, stem)
    if match:
        return match.group(1)
    return stem


def _archive_old_output_runs(
    directory: Path,
    family_base: str,
    suffixes: set[str],
    keep_latest_runs: int,
    archive_dir: Path,
) -> list[Path]:
    """Archive older output runs for a report family and return moved paths."""
    if keep_latest_runs < 1 or not directory.is_dir():
        return []

    grouped: dict[str, list[Path]] = {}
    for path in directory.iterdir():
        if not path.is_file() or path.suffix.lower() not in suffixes:
            continue
        if not path.stem.startswith(family_base):
            continue
        group_key = _run_group_prefix(path.stem, family_base)
        grouped.setdefault(group_key, []).append(path)

    if len(grouped) <= keep_latest_runs:
        return []

    group_order = sorted(
        grouped.items(),
        key=lambda item: max(candidate.stat().st_mtime for candidate in item[1]),
        reverse=True,
    )
    archive_dir.mkdir(parents=True, exist_ok=True)

    moved: list[Path] = []
    for _, paths in group_order[keep_latest_runs:]:
        for path in paths:
            family_archive_dir = archive_dir / family_base
            family_archive_dir.mkdir(parents=True, exist_ok=True)
            dest = family_archive_dir / path.name
            if dest.exists():
                dest = family_archive_dir / f"{path.stem}_{_file_stamp()}{path.suffix}"
            shutil.move(str(path), str(dest))
            moved.append(dest)

    return moved


def _cli_path(path_value: Optional[str]) -> Optional[Path]:
    """Return an expanded Path for a CLI-supplied path string."""
    if path_value is None:
        return None
    text = str(path_value).strip()
    if not text:
        return None
    return Path(text).expanduser()


def _cli_input_candidates(
    path_value: Optional[str],
    config: Optional["Config"] = None,
) -> list[Path]:
    """Return candidate locations for a CLI-supplied input path."""
    path = _cli_path(path_value)
    if path is None:
        return []

    candidates = [path]
    if config is not None and not path.is_absolute():
        config_relative = config.base_dir / path
        if config_relative not in candidates:
            candidates.append(config_relative)
    return candidates


def _resolve_cli_input_path(
    path_value: Optional[str],
    config: Optional["Config"] = None,
) -> Optional[Path]:
    """Resolve a CLI-supplied input path from existing candidate locations."""
    candidates = _cli_input_candidates(path_value, config)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0] if candidates else None


def _describe_cli_input_candidates(
    path_value: Optional[str],
    config: Optional["Config"] = None,
) -> str:
    """Return a human-readable list of input paths checked for a CLI argument."""
    candidates = _cli_input_candidates(path_value, config)
    if not candidates:
        return ""

    seen: set[str] = set()
    rendered: list[str] = []
    for candidate in candidates:
        text = str(candidate)
        if text not in seen:
            seen.add(text)
            rendered.append(text)
    return " or ".join(rendered)


def _days_since(date_str: str) -> Optional[int]:
    """Parse a date string and return days elapsed since then.

    Args:
        date_str: Date string in common formats.

    Returns:
        Integer days since that date, or None if unparseable.
    """
    text = str(date_str).strip()
    if not text:
        return None

    iso_text = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(iso_text)
        if parsed.tzinfo is not None:
            return (datetime.now(timezone.utc) - parsed.astimezone(timezone.utc)).days
        return (datetime.now() - parsed).days
    except ValueError:
        pass

    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%m/%d/%Y", "%Y-%m-%d"):
        try:
            dt = datetime.strptime(text, fmt)
            return (datetime.now() - dt).days
        except ValueError:
            continue
    return None


def _display_value(value: Any, empty_label: str = "Unknown / Not Reported") -> str:
    """Return a report-friendly label for a value, substituting blanks."""
    text = str(value or "").strip()
    return text if text else empty_label


def _load_matplotlib() -> bool:
    """Import matplotlib lazily so non-chart commands avoid startup overhead."""
    global HAS_MATPLOTLIB, mdates, plt
    if HAS_MATPLOTLIB is not None:
        return HAS_MATPLOTLIB

    mpl_config_dir = os.environ.get("MPLCONFIGDIR", "").strip()
    if not mpl_config_dir:
        mpl_dir = Path(tempfile.gettempdir()) / "jamf-reports-community-mpl"
        mpl_dir.mkdir(parents=True, exist_ok=True)
        os.environ["MPLCONFIGDIR"] = str(mpl_dir)

    if not os.environ.get("XDG_CACHE_HOME", "").strip():
        cache_dir = Path(tempfile.gettempdir()) / "jamf-reports-community-cache"
        cache_dir.mkdir(parents=True, exist_ok=True)
        os.environ["XDG_CACHE_HOME"] = str(cache_dir)

    try:
        import matplotlib

        matplotlib.use("Agg")  # non-interactive backend — must be set before pyplot import
        import matplotlib.dates as matplotlib_dates
        import matplotlib.pyplot as pyplot

        plt = pyplot
        mdates = matplotlib_dates
        HAS_MATPLOTLIB = True
    except ImportError:
        HAS_MATPLOTLIB = False
    return HAS_MATPLOTLIB


def _load_pptx() -> bool:
    """Import python-pptx lazily; sets HAS_PPTX and module-level pptx_* globals.

    Returns:
        True if python-pptx is available, False otherwise.
    """
    global HAS_PPTX, pptx_Presentation, pptx_Inches, pptx_Pt
    if HAS_PPTX is not None:
        return HAS_PPTX
    try:
        from pptx import Presentation as _Presentation  # type: ignore[import-untyped]
        from pptx.util import Inches as _Inches, Pt as _Pt  # type: ignore[import-untyped]

        pptx_Presentation = _Presentation
        pptx_Inches = _Inches
        pptx_Pt = _Pt
        HAS_PPTX = True
    except ImportError:
        HAS_PPTX = False
    return HAS_PPTX


def _normalized_text(value: Any) -> str:
    """Return a lowercase, single-spaced representation of a header or cell value."""
    return re.sub(r"\s+", " ", str(value).strip().lower())


def _header_tokens(value: Any) -> set[str]:
    """Return lowercase alphanumeric tokens from a header or cell value."""
    return set(re.findall(r"[a-z0-9]+", _normalized_text(value)))


def _column_match_score(header: str, logical: str) -> int:
    """Return a heuristic scaffold score for a header/logical field pairing."""
    normalized = _normalized_text(header)
    score = 0
    for candidate in COLUMN_HINTS.get(logical, []):
        candidate_norm = _normalized_text(candidate)
        if normalized == candidate_norm:
            score = max(score, 100 + len(candidate_norm))
        elif normalized.startswith(candidate_norm):
            score = max(score, 80 + len(candidate_norm))
        elif candidate_norm in normalized:
            score = max(score, 60 + len(candidate_norm))
        elif len(normalized) >= 8 and normalized in candidate_norm:
            score = max(score, 40 + len(normalized))

    for blocked in COLUMN_EXCLUDES.get(logical, []):
        if _normalized_text(blocked) in normalized:
            score -= 80

    return score if score >= 60 else 0


def _best_header_match(
    headers: list[str],
    logical: str,
    used_headers: Optional[set[str]] = None,
) -> tuple[Optional[str], int]:
    """Return the best-scoring header for a logical field."""
    best_header: Optional[str] = None
    best_score = 0
    reserved = used_headers or set()
    for header in headers:
        if header in reserved:
            continue
        score = _column_match_score(header, logical)
        if score > best_score:
            best_header = header
            best_score = score
    return best_header, best_score


def _contains_case_insensitive(series: Any, needle: str) -> Any:
    """Return a boolean Series for a case-insensitive substring match."""
    if not needle:
        return series.str.strip() != ""
    return series.str.contains(needle, case=False, regex=False, na=False)


def _split_multi_value_cell(value: Any) -> list[str]:
    """Split a compliance/list cell on common delimiters and return non-empty entries."""
    return [item.strip() for item in re.split(r"[|\n\r]+", str(value)) if item.strip()]


def _to_int(value: Any, default: int = 0) -> int:
    """Coerce a string/number-like value to int, returning default on failure."""
    try:
        return int(float(str(value).strip()))
    except (AttributeError, TypeError, ValueError):
        return default


def _to_bool(value: Any) -> bool:
    """Coerce common boolean-like values to a Python bool."""
    if isinstance(value, bool):
        return value
    return _normalized_text(value) in {"true", "1", "yes", "y"}


def _security_control_is_compliant(logical: str, value: Any) -> bool:
    """Return True when a CSV value represents a compliant security control state."""
    normalized = _normalized_text(value)
    if not normalized:
        return False

    if logical == "filevault":
        ratio = re.fullmatch(r"(\d+)/(\d+)", normalized)
        if ratio:
            encrypted, total = (int(part) for part in ratio.groups())
            return total > 0 and encrypted == total
        return normalized in {
            "encrypted",
            "all partitions encrypted",
            "boot partitions encrypted",
            "yes",
            "true",
            "enabled",
            "on",
        }

    if logical == "secure_boot":
        return normalized in {"full security", "medium security"}

    if logical == "bootstrap_token":
        return normalized in {"escrowed", "yes", "true", "enabled"}

    if logical == "gatekeeper":
        return normalized in {
            "enabled",
            "yes",
            "true",
            "1",
            "on",
            "active",
            "running",
            "connected",
            "app_store",
            "app store",
            "app_store_and_identified_developers",
            "app store and identified developers",
            "mac_app_store",
            "mac app store",
            "mac_app_store_and_identified_developers",
            "mac app store and identified developers",
        }

    return normalized in {"enabled", "yes", "true", "1", "on", "active", "running", "connected"}


def _compliance_label(comp_cfg: dict[str, Any]) -> str:
    """Return the configured compliance label."""
    return str(comp_cfg.get("baseline_label", "Compliance")).strip() or "Compliance"


def _semantic_warnings(config: "Config", df: pd.DataFrame) -> list[str]:
    """Return warnings for columns that exist but are semantically suspicious."""
    warnings: list[str] = []
    columns = config.columns

    manager_col = columns.get("manager", "")
    if manager_col:
        manager_header = _normalized_text(manager_col)
        if "managed" in manager_header and "manager" not in manager_header:
            warnings.append(
                "columns.manager points to a management-state column."
                " Use a real manager EA or leave it blank."
            )
        elif manager_col in df.columns:
            sample = {_normalized_text(v) for v in df[manager_col].dropna().astype(str).head(10)}
            if sample and sample.issubset({"managed", "unmanaged"}):
                warnings.append(
                    "columns.manager sample values look like Jamf management"
                    " status, not a person's manager."
                )

    disk_col = columns.get("disk_percent_full", "")
    if disk_col:
        disk_header = _normalized_text(disk_col)
        if any(token in disk_header for token in ("available mb", "capacity mb", "free mb")):
            warnings.append(
                "columns.disk_percent_full should point to a percentage-used column,"
                " not MB available/capacity."
            )

    secure_boot_col = columns.get("secure_boot", "")
    if secure_boot_col and "external boot" in _normalized_text(secure_boot_col):
        warnings.append(
            "columns.secure_boot points to External Boot Level. Use Secure Boot Level instead."
        )

    bootstrap_col = columns.get("bootstrap_token", "")
    if bootstrap_col and "allowed" in _normalized_text(bootstrap_col):
        warnings.append(
            "columns.bootstrap_token points to Bootstrap Token Allowed."
            " Use Bootstrap Token Escrowed for compliance tracking."
        )

    filevault_col = columns.get("filevault", "")
    if filevault_col and filevault_col in df.columns:
        sample_vals = {_normalized_text(v) for v in df[filevault_col].dropna().astype(str).head(10)}
        if any(re.fullmatch(r"\d+/\d+", val) for val in sample_vals):
            warnings.append(
                "columns.filevault sample values look like counts"
                " (for example 1/1). FileVault 2 Status is usually a better"
                " compliance column."
            )

    # Heuristic: date columns with values more than 20 years in the future
    # indicate clock drift, test data, or a wrong column mapping.
    far_future = datetime.now() + timedelta(days=365 * 20)
    date_logical_fields = ["mdm_expiry", "last_enrollment", "last_checkin"]
    for field in date_logical_fields:
        col_name = columns.get(field, "")
        if not col_name or col_name not in df.columns:
            continue
        sample = df[col_name].dropna().head(30)
        parsed_sample = pd.to_datetime(sample.astype(str), errors="coerce", utc=True)
        far_ts = pd.Timestamp(far_future, tz="UTC")
        future_count = int((parsed_sample > far_ts).sum())
        if future_count > 0:
            warnings.append(
                f"columns.{field} ({col_name!r}) has {future_count} value(s) more than"
                " 20 years in the future — verify the column mapping or check for"
                " data quality issues (clock drift, test devices)."
            )

    return warnings


def _archive_csv_snapshot(csv_path: str, historical_dir: str) -> Optional[Path]:
    """Copy the current CSV into the historical snapshot directory for future trend runs."""
    source = Path(csv_path)
    if not source.is_file():
        return None

    out_dir = Path(historical_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    prefix = re.sub(r"[^a-z0-9]+", "_", source.stem.lower()).strip("_") or "inventory"
    dest = out_dir / f"{prefix}_{_file_stamp()}.csv"
    shutil.copy2(source, dest)
    return dest


def _site_name(site_value: Any) -> str:
    """Return a friendly site name from a site object or plain string."""
    if isinstance(site_value, dict):
        return str(site_value.get("name", "")).strip()
    return str(site_value or "").strip()


def _inventory_export_row(computer: dict[str, Any]) -> dict[str, Any]:
    """Return a wide CSV row built from jamf-cli `computers list` output."""
    location = computer.get("location", {})
    if not isinstance(location, dict):
        location = {}

    name = str(computer.get("name", "")).strip()
    if not name:
        name = f"Computer {computer.get('id', '')}".strip()

    return {
        "Jamf Pro ID": str(computer.get("id", "")).strip(),
        "Computer Name": name,
        "Serial Number": str(computer.get("serialNumber", "") or "").strip(),
        "Managed": "Managed" if _to_bool(computer.get("isManaged")) else "Unmanaged",
        "Operating System": str(computer.get("operatingSystemVersion", "") or "").strip(),
        "OS Build": str(computer.get("operatingSystemBuild", "") or "").strip(),
        "OS Rapid Security Response": str(
            computer.get("operatingSystemRapidSecurityResponse", "") or ""
        ).strip(),
        "Model": str(computer.get("modelIdentifier", "") or "").strip(),
        "Asset Tag": str(computer.get("assetTag", "") or "").strip(),
        "IP Address": str(computer.get("ipAddress", "") or "").strip(),
        "Last Check-in": str(computer.get("lastContactDate", "") or "").strip(),
        "Last Report": str(computer.get("lastReportDate", "") or "").strip(),
        "Last Enrollment": str(computer.get("lastEnrolledDate", "") or "").strip(),
        "Username": str(location.get("username", "") or "").strip(),
        "Real Name": str(location.get("realName", "") or "").strip(),
        "Email Address": str(location.get("emailAddress", "") or "").strip(),
        "Position": str(location.get("position", "") or "").strip(),
        "Department": str(location.get("department", "") or "").strip(),
        "Building": str(location.get("building", "") or "").strip(),
        "Room": str(location.get("room", "") or "").strip(),
        "Site": _site_name(computer.get("site")),
        "UDID": str(computer.get("udid", "") or "").strip(),
        "Management ID": str(computer.get("managementId", "") or "").strip(),
    }


def _inventory_detail_identifier(computer: dict[str, Any]) -> str:
    """Return the best jamf-cli identifier for per-device detail lookups."""
    for key in ("id", "serialNumber", "name"):
        value = str(computer.get(key, "") or "").strip()
        if value:
            return value
    return ""


def _inventory_security_detail_fields(detail_rows: Any) -> dict[str, str]:
    """Extract generic security posture fields from `jamf-cli pro device` output."""
    extracted = {column: "" for column in INVENTORY_SECURITY_DETAIL_COLUMNS}
    rows = detail_rows if isinstance(detail_rows, list) else []
    for item in rows:
        if not isinstance(item, dict):
            continue
        if str(item.get("section", "") or "").strip() != "Security":
            continue
        resource = str(item.get("resource", "") or "").strip()
        column = INVENTORY_SECURITY_RESOURCE_MAP.get(resource)
        if not column:
            continue
        extracted[column] = str(item.get("value", "") or "").strip()
    return extracted


def _enrich_inventory_rows_with_security_details(
    bridge: "JamfCLIBridge",
    computers: list[dict[str, Any]],
    rows_by_name: dict[str, dict[str, Any]],
) -> tuple[int, int]:
    """Merge per-device security posture values into inventory export rows."""
    targets: list[tuple[str, str]] = []
    for computer in computers:
        if not isinstance(computer, dict):
            continue
        name = str(computer.get("name", "") or "").strip()
        identifier = _inventory_detail_identifier(computer)
        if name and identifier and name in rows_by_name:
            targets.append((name, identifier))

    if not targets:
        return 0, 0

    enriched = 0
    failures = 0
    max_workers = min(8, len(targets))
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_map = {
            executor.submit(bridge.device_detail, identifier): name
            for name, identifier in targets
        }
        for future in as_completed(future_map):
            name = future_map[future]
            try:
                detail_fields = _inventory_security_detail_fields(future.result())
            except RuntimeError:
                failures += 1
                continue
            rows_by_name[name].update(detail_fields)
            if any(detail_fields.values()):
                enriched += 1
    return enriched, failures


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


class Config:
    """Loads and validates the YAML configuration file.

    Args:
        path: Path to config.yaml. Defaults to ./config.yaml.
    """

    def __init__(self, path: str = "config.yaml") -> None:
        self._path = Path(path).expanduser()
        self._data: dict[str, Any] = {}
        self._load()

    def _load(self) -> None:
        if self._path.exists():
            with open(self._path) as fh:
                try:
                    loaded = yaml.safe_load(fh) or {}
                except yaml.YAMLError as exc:
                    raise SystemExit(
                        f"Error: config file '{self._path}' has invalid YAML syntax:\n{exc}"
                    ) from None
            self._data = self._merge(DEFAULT_CONFIG, loaded)
        else:
            self._data = copy.deepcopy(DEFAULT_CONFIG)

    def _merge(self, base: dict, override: dict) -> dict:
        result = copy.deepcopy(base)
        for k, v in override.items():
            if isinstance(v, dict) and isinstance(result.get(k), dict):
                result[k] = self._merge(result[k], v)
            else:
                result[k] = v
        return result

    def get(self, *keys: str, default: Any = None) -> Any:
        """Retrieve a nested config value by key path."""
        node = self._data
        for k in keys:
            if not isinstance(node, dict):
                return default
            node = node.get(k, default)
        return node

    @property
    def base_dir(self) -> Path:
        """Return the directory relative config-managed paths should use."""
        config_path = self._path
        if not config_path.is_absolute():
            config_path = (Path.cwd() / config_path).resolve()
        else:
            config_path = config_path.resolve()
        return config_path.parent

    def resolve_path_value(self, value: Any) -> Optional[Path]:
        """Resolve a config-managed path value relative to the config location."""
        if value is None:
            return None
        text = str(value).strip()
        if not text:
            return None
        path = Path(text).expanduser()
        if path.is_absolute():
            return path
        return self.base_dir / path

    def resolve_path(self, *keys: str, default: Any = None) -> Optional[Path]:
        """Resolve a nested config path value relative to the config location."""
        return self.resolve_path_value(self.get(*keys, default=default))

    @property
    def columns(self) -> dict[str, str]:
        return self._data.get("columns", {})

    @property
    def security_agents(self) -> list[dict]:
        return self._data.get("security_agents", [])

    @property
    def custom_eas(self) -> list[dict]:
        return self._data.get("custom_eas", [])

    @property
    def compliance(self) -> dict:
        return self._data.get("compliance") or {}

    @property
    def jamf_cli(self) -> dict:
        return self._data.get("jamf_cli") or {}

    @property
    def thresholds(self) -> dict:
        return self._data.get("thresholds") or {}

    @property
    def output(self) -> dict:
        return self._data.get("output") or {}


# ---------------------------------------------------------------------------
# ColumnMapper
# ---------------------------------------------------------------------------


class ColumnMapper:
    """Resolves logical field names to actual CSV column names from config.

    Args:
        config: Loaded Config instance.
    """

    def __init__(self, config: Config) -> None:
        self._config = config

    def get(self, logical: str) -> Optional[str]:
        """Return the configured column name for a logical field, or None."""
        col = self._config.columns.get(logical, "")
        return col if col else None

    def extract(self, row: Any, logical: str) -> str:
        """Extract a cell value from a DataFrame row by logical field name.

        Args:
            row: A pandas Series (DataFrame row).
            logical: Logical field name as defined in config columns.

        Returns:
            String value of the cell, or empty string if column not found.
        """
        col = self.get(logical)
        if col is None or col not in row.index:
            return ""
        val = row[col]
        if val is None:
            return ""
        if isinstance(val, float) and val != val:
            return ""
        return str(val).strip()


# ---------------------------------------------------------------------------
# JamfCLIBridge
# ---------------------------------------------------------------------------


class JamfCLIBridge:
    """Thin subprocess wrapper around jamf-cli.

    Args:
        save_output: If True, persist JSON output to jamf-cli-data/.
        data_dir: Directory used to save or read cached jamf-cli JSON snapshots.
        profile: Optional jamf-cli profile name passed as -p to every command.
        use_cached_data: If True, fall back to saved snapshots when live commands fail.
    """

    def __init__(
        self,
        save_output: bool = True,
        data_dir: str = "jamf-cli-data",
        profile: str = "",
        use_cached_data: bool = True,
    ) -> None:
        self._binary = self._find_binary()
        self._save = save_output
        self._data_dir = Path(data_dir).expanduser()
        self._profile = str(profile).strip()
        self._use_cached_data = use_cached_data
        self._report_commands_cache: Optional[set[str]] = None

    def _find_binary(self) -> Optional[str]:
        candidates = [
            os.environ.get("JAMFCLI_PATH", ""),
            shutil.which("jamf-cli") or "",
            "/opt/homebrew/bin/jamf-cli",
            "/usr/local/bin/jamf-cli",
        ]
        for path in candidates:
            if path and Path(path).is_file() and os.access(path, os.X_OK):
                return path
        return None

    def is_available(self) -> bool:
        """Return True if jamf-cli binary is found and executable."""
        return self._binary is not None

    def has_cached_data(self) -> bool:
        """Return True when the configured data directory contains cached JSON snapshots."""
        return self._latest_cached_json(
            [
                "overview",
                "security",
                "patch-status",
                "patch_status",
                "policy-status",
                "policy_status",
                "inventory-summary",
                "inventory_summary",
                "device-compliance",
                "device_compliance",
                "ea-results",
                "ea_results",
                "software-installs",
                "software_installs",
                "computer-extension-attributes",
                "computer_extension_attributes",
            ]
        ) is not None

    def _report_commands(self) -> set[str]:
        """Return the installed jamf-cli report subcommands, if discoverable."""
        if self._report_commands_cache is not None:
            return self._report_commands_cache
        if not self._binary:
            self._report_commands_cache = set()
            return self._report_commands_cache

        try:
            cmd = [self._binary]
            if self._profile:
                cmd.extend(["-p", self._profile])
            cmd.extend(["pro", "report", "--help"])
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
                stdin=subprocess.DEVNULL,
            )
        except (subprocess.SubprocessError, PermissionError):
            self._report_commands_cache = set()
            return self._report_commands_cache

        commands: set[str] = set()
        in_available_section = False
        for line in result.stdout.splitlines():
            stripped = line.strip()
            if stripped == "Available Commands:":
                in_available_section = True
                continue
            if not in_available_section:
                continue
            if (
                not stripped
                or stripped.startswith("Flags:")
                or stripped.startswith("Global Flags:")
            ):
                break
            commands.add(stripped.split()[0])

        self._report_commands_cache = commands
        return commands

    def _require_report_command(
        self,
        command_name: str,
        cache_names: Optional[list[str]] = None,
    ) -> None:
        """Raise when the installed jamf-cli does not support a report subcommand."""
        commands = self._report_commands()
        if commands and command_name not in commands:
            if self._use_cached_data and cache_names and self._latest_cached_json(cache_names):
                return
            raise RuntimeError(
                f"jamf-cli report '{command_name}' is not available in the"
                " installed jamf-cli build."
            )

    def _run(self, args: list[str]) -> Any:
        """Run jamf-cli with args and return parsed JSON.

        Args:
            args: List of command arguments (excluding the binary itself).

        Returns:
            Parsed JSON object.

        Raises:
            RuntimeError: If binary not found or command fails.
        """
        if not self._binary:
            raise RuntimeError(
                "jamf-cli binary not found. Set JAMFCLI_PATH or install via Homebrew."
            )
        cmd = [self._binary, "--output", "json", "--no-input"]
        if self._profile:
            cmd.extend(["-p", self._profile])
        cmd.extend(args)
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, check=True,
                timeout=120, stdin=subprocess.DEVNULL,
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(f"jamf-cli timed out after 120s: {e}") from e
        except PermissionError:
            raise RuntimeError("jamf-cli is not executable. Check file permissions.")
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or exc.stdout).strip()
            raise RuntimeError(f"jamf-cli failed ({exc.returncode}): {detail}") from exc
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            detail = "\n".join(
                part for part in [result.stdout.strip(), result.stderr.strip()] if part
            )
            raise RuntimeError(
                f"jamf-cli returned non-JSON output: {detail[:1000]}"
            ) from exc

    def _latest_cached_json(self, report_names: list[str]) -> Optional[Path]:
        """Return the newest cached JSON snapshot for any of the supplied report names."""
        candidates: list[Path] = []
        for report_name in report_names:
            report_dir = self._data_dir / report_name
            if report_dir.is_dir():
                candidates.extend(
                    path for path in report_dir.rglob("*.json") if ".partial" not in path.name
                )
            elif self._data_dir.is_dir():
                pattern = f"{report_name}_*.json"
                candidates.extend(
                    path for path in self._data_dir.rglob(pattern) if ".partial" not in path.name
                )

        if not candidates:
            return None
        return max(candidates, key=lambda path: path.stat().st_mtime)

    def _load_cached_json(self, report_names: list[str]) -> Any:
        """Load and return the newest cached JSON snapshot for the supplied report names."""
        cached_path = self._latest_cached_json(report_names)
        if cached_path is None:
            raise RuntimeError("no cached jamf-cli snapshot is available")
        try:
            with open(cached_path, encoding="utf-8") as fh:
                data = json.load(fh)
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                f"Cached snapshot is malformed and cannot be parsed: {cached_path}\n"
                f"  Delete it and re-run 'collect' to refresh. Detail: {exc}"
            ) from exc
        except OSError as exc:
            raise RuntimeError(f"Could not read cached snapshot {cached_path}: {exc}") from exc
        print(f"  [cache] {cached_path}")
        return data

    def snapshot_age_label(self, report_names: list[str]) -> str:
        """Return a human-readable age string for the newest cached snapshot.

        Args:
            report_names: Cache directory/file name candidates to search.

        Returns:
            A string like "snapshot 2026-04-04 14:32 (18h ago)", or "" if none found.
        """
        path = self._latest_cached_json(report_names)
        if path is None:
            return ""
        mtime = datetime.fromtimestamp(path.stat().st_mtime)
        delta = datetime.now() - mtime
        total_seconds = int(delta.total_seconds())
        if total_seconds < 120:
            age = "just now"
        elif total_seconds < 3600:
            age = f"{total_seconds // 60}m ago"
        elif total_seconds < 86400:
            age = f"{total_seconds // 3600}h ago"
        else:
            age = f"{total_seconds // 86400}d ago"
        return f"snapshot {mtime.strftime('%Y-%m-%d %H:%M')} ({age})"

    def _run_and_save(
        self,
        report_type: str,
        args: list[str],
        cache_names: Optional[list[str]] = None,
    ) -> Any:
        """Run a command and optionally save output to jamf-cli-data/.

        Args:
            report_type: Subdirectory name under jamf-cli-data/.
            args: Arguments passed to _run.
            cache_names: Cache directory/file name candidates for fallback lookup.

        Returns:
            Parsed JSON result.
        """
        cache_candidates = cache_names or [report_type]
        try:
            data = self._run(args)
        except RuntimeError as exc:
            if not self._use_cached_data:
                raise
            try:
                return self._load_cached_json(cache_candidates)
            except RuntimeError as cache_exc:
                raise RuntimeError(f"{exc} | cache fallback: {cache_exc}") from exc

        if self._save:
            out_dir = self._data_dir / report_type
            try:
                out_dir.mkdir(parents=True, exist_ok=True)
                final_path = out_dir / f"{report_type}_{_now_ts()}.json"
                tmp_path = final_path.with_suffix(".partial")
                with open(tmp_path, "w", encoding="utf-8") as fh:
                    json.dump(data, fh, indent=2)
                tmp_path.rename(final_path)
            except OSError as exc:
                print(f"  [warn] Could not save snapshot for '{report_type}': {exc}")
        return data

    def overview(self, cached_only: bool = False) -> Any:
        """Fetch fleet overview from jamf-cli pro overview."""
        if cached_only:
            return self._load_cached_json(["overview"])
        return self._run_and_save("overview", ["pro", "overview"], ["overview"])

    def security_report(self) -> Any:
        """Fetch security posture report from jamf-cli pro report security."""
        return self._run_and_save("security", ["pro", "report", "security"], ["security"])

    def policy_status(self, scan_failures: bool = False) -> Any:
        """Fetch policy health report from jamf-cli pro report policy-status."""
        self._require_report_command("policy-status", ["policy-status", "policy_status"])
        args = ["pro", "report", "policy-status"]
        if scan_failures:
            args.append("--scan-failures")
        return self._run_and_save("policy-status", args, ["policy-status", "policy_status"])

    def profile_status(self) -> Any:
        """Fetch profile status report from jamf-cli pro report profile-status."""
        self._require_report_command("profile-status", ["profile-status", "profile_status"])
        return self._run_and_save(
            "profile-status",
            ["pro", "report", "profile-status"],
            ["profile-status", "profile_status"],
        )

    def patch_status(self) -> Any:
        """Fetch patch compliance report from jamf-cli pro report patch-status."""
        return self._run_and_save(
            "patch-status",
            ["pro", "report", "patch-status"],
            ["patch-status", "patch_status"],
        )

    def patch_device_failures(self) -> Any:
        """Fetch per-device patch failures via pro report patch-status --scan-failures.

        Requires jamf-cli v1.4.0+. Returns one row per failing device per patch policy,
        enriched with inventory data and the last action taken from the patch log.
        JSON shape:
          [{"policy":"Firefox 130.0","policy_id":"42","device":"MacBook-001",
            "device_id":"123","status_date":"2026-04-01","attempt":3,
            "last_action":"Retrying","serial":"ABC123",
            "os_version":"15.7.3","username":"jdoe"}, ...]
        """
        return self._run_and_save(
            "patch-device-failures",
            ["pro", "report", "patch-status", "--scan-failures"],
            ["patch-device-failures", "patch_device_failures"],
        )

    def app_status(self) -> Any:
        """Fetch managed app deployment report from jamf-cli pro report app-status."""
        self._require_report_command("app-status", ["app-status", "app_status"])
        return self._run_and_save(
            "app-status",
            ["pro", "report", "app-status"],
            ["app-status", "app_status"],
        )

    def update_status(self) -> Any:
        """Fetch managed software update report from jamf-cli pro report update-status."""
        self._require_report_command("update-status", ["update-status", "update_status"])
        try:
            return self._run_and_save(
                "update-status",
                ["pro", "report", "update-status"],
                ["update-status", "update_status"],
            )
        except RuntimeError as exc:
            detail = str(exc)
            if (
                "No managed software update data found." in detail
                or "Managed Software Update Plans toggle is off." in detail
            ):
                return {
                    "message": "No managed software update data found.",
                    "summary": {},
                    "ErrorDevices": [],
                }
            raise

    def device_detail(self, identifier: str) -> Any:
        """Fetch the aggregated device detail view for one computer."""
        ident = str(identifier).strip()
        if not ident:
            raise RuntimeError("device detail lookup requires a non-empty identifier")
        return self._run(["pro", "device", ident])

    def computers_list(self) -> Any:
        """Fetch the lightweight computer inventory index from jamf-cli pro computers list."""
        return self._run_and_save(
            "computers-list",
            ["pro", "computers", "list"],
            ["computers-list", "computers_list"],
        )

    def ea_results(self, name_filter: str = "", include_all: bool = True) -> Any:
        """Fetch computer extension attribute values from jamf-cli pro report ea-results."""
        self._require_report_command("ea-results")
        args = ["pro", "report", "ea-results"]
        if name_filter:
            args.extend(["--name", name_filter])
        if include_all:
            args.append("--all")
        return self._run(args)

    def ea_results_report(self, name_filter: str = "", include_all: bool = True) -> Any:
        """Fetch and cache computer extension attribute values from jamf-cli."""
        self._require_report_command("ea-results", ["ea-results", "ea_results"])
        args = ["pro", "report", "ea-results"]
        if name_filter:
            args.extend(["--name", name_filter])
        if include_all:
            args.append("--all")
        return self._run_and_save("ea-results", args, ["ea-results", "ea_results"])

    def inventory_summary(self) -> Any:
        """Fetch hardware model and OS breakdown from jamf-cli pro report inventory-summary."""
        self._require_report_command(
            "inventory-summary",
            ["inventory-summary", "inventory_summary"],
        )
        return self._run_and_save(
            "inventory-summary",
            ["pro", "report", "inventory-summary"],
            ["inventory-summary", "inventory_summary"],
        )

    def device_compliance(self, days_since_checkin: Optional[int] = None) -> Any:
        """Fetch device compliance rows from jamf-cli pro report device-compliance."""
        self._require_report_command(
            "device-compliance",
            ["device-compliance", "device_compliance"],
        )
        args = ["pro", "report", "device-compliance"]
        if days_since_checkin is not None:
            args.extend(["--days-since-checkin", str(days_since_checkin)])
        return self._run_and_save(
            "device-compliance",
            args,
            ["device-compliance", "device_compliance"],
        )

    def computer_extension_attributes(self) -> Any:
        """Fetch computer extension attribute definitions from jamf-cli."""
        return self._run_and_save(
            "computer-extension-attributes",
            ["pro", "computer-extension-attributes", "list"],
            ["computer-extension-attributes", "computer_extension_attributes"],
        )

    def software_installs(
        self,
        title_filter: str = "",
        include_system: bool = False,
    ) -> Any:
        """Fetch installed software distribution from jamf-cli pro report software-installs."""
        self._require_report_command(
            "software-installs",
            ["software-installs", "software_installs"],
        )
        args = ["pro", "report", "software-installs"]
        if include_system:
            args.append("--include-system")
        if title_filter:
            args.extend(["--title", title_filter])
        return self._run_and_save(
            "software-installs",
            args,
            ["software-installs", "software_installs"],
        )

    def device_lookup(self, device_id: str) -> Any:
        """Fetch a per-device detail view from jamf-cli pro device.

        Args:
            device_id: Jamf Pro computer ID or serial number to look up.

        Returns:
            Parsed JSON response from jamf-cli.

        Raises:
            RuntimeError: If jamf-cli is unavailable or the request fails.
        """
        return self._run(["pro", "device", device_id])


# ---------------------------------------------------------------------------
# Workbook format helpers
# ---------------------------------------------------------------------------


def _build_formats(wb: xlsxwriter.Workbook) -> dict[str, Any]:
    """Create and return a dict of named xlsxwriter formats.

    Args:
        wb: Active xlsxwriter Workbook.

    Returns:
        Dict mapping name -> Format object.
    """
    return {
        "title": wb.add_format({"bold": True, "font_size": 14}),
        "subtitle": wb.add_format({"italic": True, "font_color": "#595959", "font_size": 10}),
        "header": wb.add_format(
            {"bold": True, "bg_color": "#2D5EA2", "font_color": "white", "border": 1}
        ),
        "cell": wb.add_format({"border": 1}),
        "green": wb.add_format({"bg_color": "#C6EFCE", "border": 1}),
        "yellow": wb.add_format({"bg_color": "#FFEB9C", "border": 1}),
        "red": wb.add_format({"bg_color": "#FFC7CE", "border": 1}),
        "pct": wb.add_format({"num_format": "0.0%", "border": 1}),
        "pct_green": wb.add_format({"num_format": "0.0%", "bg_color": "#C6EFCE", "border": 1}),
        "pct_yellow": wb.add_format({"num_format": "0.0%", "bg_color": "#FFEB9C", "border": 1}),
        "pct_red": wb.add_format({"num_format": "0.0%", "bg_color": "#FFC7CE", "border": 1}),
        "date": wb.add_format({"num_format": "yyyy-mm-dd", "border": 1}),
        "int": wb.add_format({"num_format": "0", "border": 1}),
    }


def _write_sheet_header(
    ws: xlsxwriter.workbook.Worksheet,
    title: str,
    subtitle: str,
    fmts: dict,
    ncols: int = 8,
) -> int:
    """Write title/subtitle rows and return the next data row index.

    Args:
        ws: Target worksheet.
        title: Bold title text for row 0.
        subtitle: Italic subtitle text for row 1.
        fmts: Format dict from _build_formats.
        ncols: Number of columns to merge for title.

    Returns:
        Row index where data should begin (typically 3).
    """
    ws.merge_range(0, 0, 0, ncols - 1, title, fmts["title"])
    ws.merge_range(1, 0, 1, ncols - 1, subtitle, fmts["subtitle"])
    return 3


def _pct_format(fmts: dict, pct: float) -> Any:
    """Return a color-coded percentage format based on value.

    Args:
        fmts: Format dict from _build_formats.
        pct: Compliance percentage (0.0 to 1.0).

    Returns:
        xlsxwriter Format object.
    """
    if pct >= 0.95:
        return fmts["pct_green"]
    if pct >= 0.80:
        return fmts["pct_yellow"]
    return fmts["pct_red"]


def _write_report_sources_sheet(
    wb: xlsxwriter.Workbook,
    fmts: dict[str, Any],
    generated_at: str,
    config: Config,
    csv_path: Optional[str],
    hist_dir: Optional[str],
    jamf_cli_dir: Optional[str],
    jamf_cli_profile: str,
    live_overview_allowed: bool,
    jamf_cli_sheets: list[str],
    csv_sheets: list[str],
    chart_source: str,
) -> None:
    """Write a workbook sheet describing the data sources used for the report."""
    ws = wb.add_worksheet("Report Sources")
    row = _write_sheet_header(
        ws,
        "Report Sources",
        f"Generated: {generated_at}",
        fmts,
        ncols=4,
    )
    ws.set_column(0, 0, 24)
    ws.set_column(1, 1, 80)
    ws.set_column(2, 3, 18)

    if jamf_cli_sheets and csv_sheets:
        report_mode = "Mixed (jamf-cli + CSV)"
    elif jamf_cli_sheets:
        report_mode = "jamf-cli only"
    else:
        report_mode = "CSV only"

    summary_rows = [
        ("Report Mode", report_mode),
        ("Config Base Dir", str(config.base_dir)),
        ("CSV Input", csv_path or ""),
        ("Historical CSV Dir", hist_dir or ""),
        ("jamf-cli Data Dir", jamf_cli_dir or ""),
        ("jamf-cli Profile", jamf_cli_profile),
        ("Live Overview", "Enabled" if live_overview_allowed else "Cached only"),
    ]
    for label, value in summary_rows:
        _safe_write(ws, row, 0, label, fmts["cell"])
        _safe_write(ws, row, 1, value, fmts["cell"])
        row += 1

    row += 1
    headers = ["Sheet", "Source", "Included"]
    for col_i, header in enumerate(headers):
        _safe_write(ws, row, col_i, header, fmts["header"])
    row += 1

    sheet_rows: list[tuple[str, str, str]] = []
    sheet_rows.extend((sheet, "jamf-cli", "Yes") for sheet in jamf_cli_sheets)
    sheet_rows.extend((sheet, "CSV", "Yes") for sheet in csv_sheets)
    if chart_source:
        sheet_rows.append(("Charts", chart_source, "Yes"))

    for sheet, source, included in sheet_rows:
        _safe_write(ws, row, 0, sheet, fmts["cell"])
        _safe_write(ws, row, 1, source, fmts["cell"])
        _safe_write(ws, row, 2, included, fmts["cell"])
        row += 1


# ---------------------------------------------------------------------------
# CoreDashboard helpers
# ---------------------------------------------------------------------------


def _extract_envelope(raw: Any) -> dict:
    """Unwrap a single-element list response and return a dict, or empty dict.

    Several jamf-cli report commands wrap their result in a one-element list.
    This helper handles both the list and bare-dict shapes consistently.

    Args:
        raw: The parsed JSON value returned by a jamf-cli command.

    Returns:
        The inner dict, or an empty dict if the response is absent/invalid.
    """
    node = raw[0] if isinstance(raw, list) and raw else raw
    return node if isinstance(node, dict) and node else {}


# ---------------------------------------------------------------------------
# CoreDashboard
# ---------------------------------------------------------------------------


class CoreDashboard:
    """Generates Excel sheets from jamf-cli data only (no CSV required).

    Args:
        config: Loaded Config instance.
        bridge: JamfCLIBridge instance.
        workbook: Active xlsxwriter Workbook.
        fmts: Format dict from _build_formats.
    """

    def __init__(
        self,
        config: Config,
        bridge: JamfCLIBridge,
        workbook: xlsxwriter.Workbook,
        fmts: dict,
    ) -> None:
        self._config = config
        self._bridge = bridge
        self._wb = workbook
        self._fmts = fmts

    def _severity_fmt(self, value: int, warn: int, crit: int) -> Any:
        """Return red/yellow/normal cell format based on value vs thresholds.

        Args:
            value: The integer value to test.
            warn: Threshold at or above which the yellow format is returned.
            crit: Threshold at or above which the red format is returned.

        Returns:
            An xlsxwriter format object from self._fmts.
        """
        if value >= crit:
            return self._fmts["red"]
        if value >= warn:
            return self._fmts["yellow"]
        return self._fmts["cell"]

    def write_all(self) -> list[str]:
        """Write all core sheets. Returns list of sheet names written."""
        written = []
        sheets = [
            ("Fleet Overview", self._write_overview),
            ("Inventory Summary", self._write_inventory_summary),
            ("Security Posture", self._write_security),
            ("Device Compliance", self._write_device_compliance),
            ("EA Coverage", self._write_ea_coverage),
            ("EA Definitions", self._write_ea_definitions),
            ("Software Installs", self._write_software_installs),
            ("Policy Health", self._write_policy),
            ("Profile Status", self._write_profile_status),
            ("App Status", self._write_app_status),
            ("Patch Compliance", self._write_patch),
            ("Patch Failures", self._write_patch_failures),
            ("Update Status", self._write_update_status),
        ]
        for name, fn in sheets:
            try:
                fn()
                written.append(name)
                print(f"  [ok] {name}")
            except RuntimeError as exc:
                print(f"  [skip] {name}: {exc}")
            except Exception as exc:  # unexpected shape or type from jamf-cli JSON
                print(f"  [skip] {name}: unexpected error — {type(exc).__name__}: {exc}")
        return written

    def _write_overview(self) -> None:
        live_overview_allowed = self._config.jamf_cli.get("allow_live_overview", True) is True
        data = self._bridge.overview(cached_only=not live_overview_allowed)
        ws = self._wb.add_worksheet("Fleet Overview")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        rows = self._overview_rows(data)
        has_status = any(row["status"] for row in rows)
        age_label = self._bridge.snapshot_age_label(["overview"])
        if live_overview_allowed:
            source_name = "jamf-cli pro overview"
        else:
            if age_label:
                source_name = f"cached jamf-cli pro overview ({age_label})"
            else:
                source_name = "cached jamf-cli pro overview"
        row = _write_sheet_header(
            ws,
            "Fleet Overview",
            f"Source: {source_name} | Generated: {ts}",
            self._fmts,
            ncols=4 if has_status else 3,
        )
        ws.set_column(0, 0, 24)
        ws.set_column(1, 1, 42)
        ws.set_column(2, 2, 24)
        headers = ["Section", "Resource", "Value"] + (["Status"] if has_status else [])
        for col_i, header in enumerate(headers):
            _safe_write(ws, row, col_i, header, self._fmts["header"])
        row += 1
        for item in rows:
            _safe_write(ws, row, 0, item["section"], self._fmts["cell"])
            _safe_write(ws, row, 1, item["resource"], self._fmts["cell"])
            _safe_write(ws, row, 2, item["value"], self._fmts["cell"])
            if has_status:
                status_fmt = self._fmts["red"] if item["status"] == "red" else self._fmts["cell"]
                if item["status"] == "yellow":
                    status_fmt = self._fmts["yellow"]
                _safe_write(ws, row, 3, item["status"], status_fmt)
            row += 1

    def _flatten_dict(self, d: Any, prefix: str = "") -> dict[str, Any]:
        """Recursively flatten a nested dict into dot-separated keys."""
        out: dict[str, Any] = {}
        if not isinstance(d, dict):
            return {prefix: d} if prefix else {}
        for k, v in d.items():
            full_key = f"{prefix}.{k}" if prefix else k
            if isinstance(v, dict):
                out.update(self._flatten_dict(v, full_key))
            elif isinstance(v, list):
                out[full_key] = f"[{len(v)} items]"
            else:
                out[full_key] = v
        return out

    def _overview_rows(self, data: Any) -> list[dict[str, Any]]:
        """Normalize jamf-cli overview data across older and newer JSON shapes."""
        if isinstance(data, dict):
            return [
                {"section": "", "resource": key, "value": value, "status": ""}
                for key, value in self._flatten_dict(data).items()
            ]

        rows: list[dict[str, Any]] = []
        for item in data if isinstance(data, list) else []:
            if not isinstance(item, dict):
                continue
            rows.append(
                {
                    "section": str(item.get("section", "")),
                    "resource": str(item.get("resource", "")),
                    "value": item.get("value", ""),
                    "status": str(item.get("status", "")),
                }
            )
        return rows

    def _write_security(self) -> None:
        # jamf-cli pro report security --output json returns a flat mixed list:
        #   [{"section":"summary","data":{total_devices,filevault_encrypted,...}},
        #    {"section":"device",...},
        #    {"section":"os_version","os_version":"15.7.3","count":N,"pct":"N%"}]
        raw = self._bridge.security_report()
        items = raw if isinstance(raw, list) else []
        summary = next(
            (i.get("data", i) for i in items if i.get("section") == "summary"), {}
        )
        total = int(summary.get("total_devices", 0))
        os_rows = [i for i in items if i.get("section") == "os_version"]

        ws = self._wb.add_worksheet("Security Posture")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "Security Posture",
            f"Source: jamf-cli pro report security | Generated: {ts}",
            self._fmts,
            ncols=5,
        )
        ws.set_column(0, 0, 35)
        ws.set_column(1, 4, 18)
        headers = ["Control", "Compliant", "Non-Compliant", "Total", "Compliance %"]
        for c, h in enumerate(headers):
            _safe_write(ws, row, c, h, self._fmts["header"])
        row += 1

        controls = [
            ("FileVault", "filevault_encrypted"),
            ("Gatekeeper", "gatekeeper_enabled"),
            ("SIP", "sip_enabled"),
            ("Firewall", "firewall_enabled"),
        ]
        for label, key in controls:
            compliant = int(summary.get(key, 0))
            non_compliant = total - compliant
            pct = compliant / total if total > 0 else 0.0
            _safe_write(ws, row, 0, label, self._fmts["cell"])
            _safe_write(ws, row, 1, compliant, self._fmts["cell"])
            _safe_write(ws, row, 2, non_compliant, self._fmts["cell"])
            _safe_write(ws, row, 3, total, self._fmts["cell"])
            _safe_write(ws, row, 4, pct, _pct_format(self._fmts, pct))
            row += 1

        if os_rows:
            row += 1
            _safe_write(ws, row, 0, "OS Version Distribution", self._fmts["header"])
            _safe_write(ws, row, 1, "Device Count", self._fmts["header"])
            _safe_write(ws, row, 2, "% of Fleet", self._fmts["header"])
            row += 1
            for item in os_rows:
                _safe_write(ws, row, 0, item.get("os_version", ""), self._fmts["cell"])
                _safe_write(ws, row, 1, item.get("count", 0), self._fmts["cell"])
                _safe_write(ws, row, 2, item.get("pct", ""), self._fmts["cell"])
                row += 1

    def _write_inventory_summary(self) -> None:
        """Write a flat inventory breakdown by model and OS version."""
        raw = self._bridge.inventory_summary()
        rows = raw if isinstance(raw, list) else []
        if not rows:
            raise RuntimeError("jamf-cli inventory-summary returned no rows")

        ws = self._wb.add_worksheet("Inventory Summary")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "Inventory Summary",
            f"Source: jamf-cli pro report inventory-summary | Generated: {ts}",
            self._fmts,
            ncols=3,
        )
        ws.set_column(0, 0, 36)
        ws.set_column(1, 1, 18)
        ws.set_column(2, 2, 14)
        headers = ["Model", "OS Version", "Device Count"]
        for col_i, header in enumerate(headers):
            _safe_write(ws, row, col_i, header, self._fmts["header"])
        row += 1

        for item in sorted(
            rows,
            key=lambda current: (
                -_to_int(current.get("count", 0)),
                str(current.get("model", "")),
                str(current.get("os_version", "")),
            ),
        ):
            _safe_write(ws, row, 0, item.get("model", "Unknown"), self._fmts["cell"])
            _safe_write(ws, row, 1, item.get("os_version", "Unknown"), self._fmts["cell"])
            _safe_write(ws, row, 2, _to_int(item.get("count", 0)), self._fmts["cell"])
            row += 1

    def _write_device_compliance(self) -> None:
        """Write a stale check-in summary and device detail table from jamf-cli."""
        stale_days = int(self._config.thresholds.get("stale_device_days", 30))
        raw = self._bridge.device_compliance(stale_days)
        rows = raw if isinstance(raw, list) else []
        if not rows:
            raise RuntimeError("jamf-cli device-compliance returned no rows")

        total = len(rows)
        stale_count = sum(1 for item in rows if _to_bool(item.get("stale")))
        managed_count = sum(1 for item in rows if _to_bool(item.get("managed")))

        ws = self._wb.add_worksheet("Device Compliance")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "Device Compliance",
            (
                "Source: jamf-cli pro report device-compliance"
                f" (--days-since-checkin {stale_days}) | Generated: {ts}"
            ),
            self._fmts,
            ncols=7,
        )
        summary_rows = [
            ("Total Devices", total),
            ("Managed Devices", managed_count),
            ("Unmanaged Devices", total - managed_count),
            (f"Stale Devices (>{stale_days} days)", stale_count),
            ("Current Devices", total - stale_count),
        ]
        for label, value in summary_rows:
            _safe_write(ws, row, 0, label, self._fmts["cell"])
            _safe_write(ws, row, 1, value, self._fmts["cell"])
            row += 1

        row += 1
        headers = [
            "Computer Name",
            "Serial Number",
            "Managed",
            "OS Version",
            "Last Contact",
            "Days Since Contact",
            "Stale",
        ]
        for col_i, header in enumerate(headers):
            _safe_write(ws, row, col_i, header, self._fmts["header"])
        row += 1
        ws.set_column(0, 0, 30)
        ws.set_column(1, 1, 18)
        ws.set_column(2, 2, 12)
        ws.set_column(3, 6, 18)

        for item in sorted(
            rows,
            key=lambda current: (
                not _to_bool(current.get("stale")),
                -_to_int(current.get("days_since_contact", -1), -1),
                str(current.get("name", "")),
            ),
        ):
            stale = _to_bool(item.get("stale"))
            managed = _to_bool(item.get("managed"))
            row_fmt = self._fmts["red"] if stale else self._fmts["cell"]
            _safe_write(ws, row, 0, item.get("name", ""), row_fmt)
            _safe_write(ws, row, 1, item.get("serial", ""), row_fmt)
            _safe_write(ws, row, 2, "Yes" if managed else "No", row_fmt)
            _safe_write(ws, row, 3, item.get("os_version", ""), row_fmt)
            _safe_write(ws, row, 4, item.get("last_contact", ""), row_fmt)
            _safe_write(ws, row, 5, item.get("days_since_contact", ""), row_fmt)
            _safe_write(ws, row, 6, "Yes" if stale else "No", row_fmt)
            row += 1

    def _write_ea_coverage(self) -> None:
        """Write a fleet-wide extension attribute coverage summary from jamf-cli."""
        raw = self._bridge.ea_results_report(include_all=True)
        rows = raw if isinstance(raw, list) else []
        if not rows:
            raise RuntimeError("jamf-cli ea-results returned no rows")

        definitions_by_id: dict[str, dict[str, Any]] = {}
        definitions_by_name: dict[str, dict[str, Any]] = {}
        try:
            definitions_raw = self._bridge.computer_extension_attributes()
            definitions = definitions_raw if isinstance(definitions_raw, list) else []
        except RuntimeError as exc:
            print(f"  [warn] EA definitions unavailable; EA Coverage will lack type/input"
                  f" metadata: {exc}")
            definitions = []

        for item in definitions:
            if not isinstance(item, dict):
                continue
            item_id = str(item.get("id", "") or "").strip()
            item_name = str(item.get("name", "") or "").strip()
            if item_id:
                definitions_by_id[item_id] = item
            if item_name:
                definitions_by_name[item_name] = item

        coverage: dict[str, dict[str, Any]] = {}
        for item in rows:
            if not isinstance(item, dict):
                continue
            ea_name = str(item.get("ea_name", "") or "").strip()
            definition_id = str(item.get("definition_id", "") or "").strip()
            if not ea_name and not definition_id:
                continue
            key = ea_name or definition_id
            info = coverage.setdefault(
                key,
                {
                    "ea_name": ea_name,
                    "definition_id": definition_id,
                    "total_devices": 0,
                    "populated_devices": 0,
                    "value_counts": Counter(),
                },
            )
            value = str(item.get("value", "") or "").strip()
            info["total_devices"] += 1
            if value:
                info["populated_devices"] += 1
                info["value_counts"][value] += 1

        if not coverage:
            raise RuntimeError("jamf-cli ea-results returned no usable rows")

        fleet_size = max((item["total_devices"] for item in coverage.values()), default=0)
        eas_with_data = sum(1 for item in coverage.values() if item["populated_devices"] > 0)

        ws = self._wb.add_worksheet("EA Coverage")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        subtitle = "Source: jamf-cli pro report ea-results --all"
        if definitions:
            subtitle += " + computer-extension-attributes list"
        row = _write_sheet_header(
            ws,
            "Extension Attribute Coverage",
            f"{subtitle} | Generated: {ts}",
            self._fmts,
            ncols=11,
        )
        summary_rows = [
            ("Total Extension Attributes", len(coverage)),
            ("EAs With Populated Values", eas_with_data),
            ("EAs With No Populated Values", len(coverage) - eas_with_data),
            ("Inferred Fleet Size", fleet_size),
        ]
        for label, value in summary_rows:
            _safe_write(ws, row, 0, label, self._fmts["cell"])
            _safe_write(ws, row, 1, value, self._fmts["cell"])
            row += 1

        row += 1
        headers = [
            "EA Name",
            "Definition ID",
            "Data Type",
            "Input Type",
            "Enabled",
            "Populated Devices",
            "Empty Devices",
            "Total Devices",
            "Coverage %",
            "Unique Non-Empty Values",
            "Top Values",
        ]
        for col_i, header in enumerate(headers):
            _safe_write(ws, row, col_i, header, self._fmts["header"])
        row += 1
        ws.set_column(0, 0, 34)
        ws.set_column(1, 4, 16)
        ws.set_column(5, 8, 16)
        ws.set_column(9, 9, 20)
        ws.set_column(10, 10, 56)

        for item in sorted(coverage.values(), key=lambda current: str(current["ea_name"]).lower()):
            definition = (
                definitions_by_id.get(item["definition_id"])
                or definitions_by_name.get(item["ea_name"])
                or {}
            )
            total_devices = item["total_devices"]
            populated_devices = item["populated_devices"]
            empty_devices = max(total_devices - populated_devices, 0)
            coverage_pct = populated_devices / total_devices if total_devices > 0 else 0.0
            top_values = ", ".join(
                f"{value} ({count})"
                for value, count in item["value_counts"].most_common(3)
            )
            _safe_write(ws, row, 0, item["ea_name"], self._fmts["cell"])
            _safe_write(ws, row, 1, item["definition_id"], self._fmts["cell"])
            _safe_write(ws, row, 2, definition.get("dataType", ""), self._fmts["cell"])
            _safe_write(ws, row, 3, definition.get("inputType", ""), self._fmts["cell"])
            enabled_raw = definition.get("enabled")
            enabled_value = ""
            if enabled_raw is True:
                enabled_value = "Yes"
            elif enabled_raw is False:
                enabled_value = "No"
            _safe_write(ws, row, 4, enabled_value, self._fmts["cell"])
            _safe_write(ws, row, 5, populated_devices, self._fmts["cell"])
            _safe_write(ws, row, 6, empty_devices, self._fmts["cell"])
            _safe_write(ws, row, 7, total_devices, self._fmts["cell"])
            _safe_write(ws, row, 8, coverage_pct, _pct_format(self._fmts, coverage_pct))
            _safe_write(ws, row, 9, len(item["value_counts"]), self._fmts["cell"])
            _safe_write(ws, row, 10, top_values, self._fmts["cell"])
            row += 1

    def _write_ea_definitions(self) -> None:
        """Write computer extension attribute definitions from jamf-cli."""
        raw = self._bridge.computer_extension_attributes()
        rows = raw if isinstance(raw, list) else []
        if not rows:
            raise RuntimeError("jamf-cli computer-extension-attributes returned no rows")

        ws = self._wb.add_worksheet("EA Definitions")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "Extension Attribute Definitions",
            "Source: jamf-cli pro computer-extension-attributes list"
            f" | Generated: {ts}",
            self._fmts,
            ncols=7,
        )
        headers = [
            "EA Name",
            "Definition ID",
            "Data Type",
            "Input Type",
            "Enabled",
            "Inventory Display",
            "Description",
        ]
        for col_i, header in enumerate(headers):
            _safe_write(ws, row, col_i, header, self._fmts["header"])
        row += 1
        ws.set_column(0, 0, 34)
        ws.set_column(1, 4, 16)
        ws.set_column(5, 5, 22)
        ws.set_column(6, 6, 60)

        for item in sorted(rows, key=lambda current: str(current.get("name", "")).lower()):
            enabled_raw = item.get("enabled")
            enabled_value = ""
            if enabled_raw is True:
                enabled_value = "Yes"
            elif enabled_raw is False:
                enabled_value = "No"
            _safe_write(ws, row, 0, item.get("name", ""), self._fmts["cell"])
            _safe_write(ws, row, 1, item.get("id", ""), self._fmts["cell"])
            _safe_write(ws, row, 2, item.get("dataType", ""), self._fmts["cell"])
            _safe_write(ws, row, 3, item.get("inputType", ""), self._fmts["cell"])
            _safe_write(ws, row, 4, enabled_value, self._fmts["cell"])
            _safe_write(ws, row, 5, item.get("inventoryDisplayType", ""), self._fmts["cell"])
            _safe_write(ws, row, 6, item.get("description", ""), self._fmts["cell"])
            row += 1

    def _write_software_installs(self) -> None:
        """Write installed software version distribution from jamf-cli."""
        raw = self._bridge.software_installs()
        rows = raw if isinstance(raw, list) else []
        if not rows:
            raise RuntimeError("jamf-cli software-installs returned no rows")

        ws = self._wb.add_worksheet("Software Installs")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "Software Installs",
            "Source: jamf-cli pro report software-installs"
            f" | Generated: {ts}",
            self._fmts,
            ncols=3,
        )
        title_count = len({str(item.get('title', '') or '').strip() for item in rows})
        _safe_write(ws, row, 0, "Distinct Titles", self._fmts["cell"])
        _safe_write(ws, row, 1, title_count, self._fmts["cell"])
        row += 1
        _safe_write(ws, row, 0, "Title-Version Rows", self._fmts["cell"])
        _safe_write(ws, row, 1, len(rows), self._fmts["cell"])
        row += 2

        headers = ["Application Title", "Version", "Device Count"]
        for col_i, header in enumerate(headers):
            _safe_write(ws, row, col_i, header, self._fmts["header"])
        row += 1
        ws.set_column(0, 0, 38)
        ws.set_column(1, 1, 20)
        ws.set_column(2, 2, 16)

        for item in sorted(
            rows,
            key=lambda current: (
                -_to_int(current.get("device_count", 0)),
                str(current.get("title", "")),
                str(current.get("version", "")),
            ),
        ):
            _safe_write(ws, row, 0, item.get("title", ""), self._fmts["cell"])
            _safe_write(ws, row, 1, item.get("version", ""), self._fmts["cell"])
            _safe_write(ws, row, 2, _to_int(item.get("device_count", 0)), self._fmts["cell"])
            row += 1

    def _write_policy(self) -> None:
        # jamf-cli pro report policy-status --output json returns:
        #   [{"summary":{total_policies,enabled,disabled,config_findings,warnings,info},
        #     "config_findings":[{severity,policy,policy_id,check,detail},...]}]
        raw = self._bridge.policy_status()
        envelope = _extract_envelope(raw)
        if not envelope:
            raise RuntimeError("policy-status returned no data")
        summary = envelope.get("summary", {}) if isinstance(envelope, dict) else {}
        findings = envelope.get("config_findings", []) if isinstance(envelope, dict) else []

        ws = self._wb.add_worksheet("Policy Health")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "Policy Health",
            f"Source: jamf-cli pro report policy-status | Generated: {ts}",
            self._fmts,
            ncols=4,
        )
        ws.set_column(0, 0, 40)
        ws.set_column(1, 3, 20)

        summary_fields = [
            ("total_policies", "Total Policies"),
            ("enabled", "Enabled"),
            ("disabled", "Disabled"),
            ("config_findings", "Config Findings"),
            ("warnings", "Warnings"),
            ("info", "Info"),
        ]
        for key, label in summary_fields:
            val = summary.get(key)
            if val is not None:
                _safe_write(ws, row, 0, label, self._fmts["cell"])
                _safe_write(ws, row, 1, val, self._fmts["cell"])
                row += 1

        if findings:
            row += 1
            headers = ["Severity", "Policy", "Check", "Detail"]
            for c, h in enumerate(headers):
                _safe_write(ws, row, c, h, self._fmts["header"])
            row += 1
            for finding in findings[:100]:
                sev = finding.get("severity", "")
                fmt = self._fmts["yellow"] if sev == "warning" else self._fmts["cell"]
                _safe_write(ws, row, 0, sev, fmt)
                _safe_write(ws, row, 1, finding.get("policy", ""), self._fmts["cell"])
                _safe_write(ws, row, 2, finding.get("check", ""), self._fmts["cell"])
                _safe_write(ws, row, 3, finding.get("detail", ""), self._fmts["cell"])
                row += 1

    def _write_profile_status(self) -> None:
        # jamf-cli pro report profile-status --output json returns:
        #   [{"summary": {"total_errors": N, "unique_profiles": N, "unique_devices": N, "days": N,
        #                 "devices_high_failure": N, "devices_high_pending": N},
        #     "failures": [{"device_type":"...","name":"...","id":"...","errors":N,
        #                   "devices":N,"last_error":"...","top_error":"..."},...],
        #     "device_failures": [...],
        #     "device_pending": [...]}]
        raw = self._bridge.profile_status()
        envelope = _extract_envelope(raw)
        if not envelope:
            raise RuntimeError("profile-status returned no data")
        summary = envelope.get("summary", {})
        failures = envelope.get("failures", [])
        device_failures = envelope.get("device_failures", [])

        ws = self._wb.add_worksheet("Profile Status")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "Profile Status",
            f"Source: jamf-cli pro report profile-status | Generated: {ts}",
            self._fmts,
            ncols=7,
        )
        ws.set_column(0, 0, 40)
        ws.set_column(1, 6, 18)

        summary_fields = [
            ("total_errors", "Total Errors"),
            ("unique_profiles", "Unique Profiles"),
            ("unique_devices", "Unique Devices"),
            ("days", "Days Lookback"),
            ("devices_high_failure", "Devices w/ High Failure"),
            ("devices_high_pending", "Devices w/ High Pending"),
        ]
        for key, label in summary_fields:
            val = summary.get(key)
            if val is not None:
                _safe_write(ws, row, 0, label, self._fmts["cell"])
                _safe_write(ws, row, 1, val, self._fmts["cell"])
                row += 1

        if failures:
            err_crit = int(self._config.thresholds.get("profile_error_critical", 50))
            err_warn = int(self._config.thresholds.get("profile_error_warning", 10))
            row += 1
            headers = ["Device Type", "Profile Name", "Profile ID", "Errors", "Devices",
                       "Last Error", "Top Error"]
            for c, h in enumerate(headers):
                _safe_write(ws, row, c, h, self._fmts["header"])
            row += 1
            for item in failures[:200]:
                errors = _to_int(item.get("errors", 0))
                fmt = self._severity_fmt(errors, err_warn, err_crit)
                _safe_write(ws, row, 0, item.get("device_type", ""), fmt)
                _safe_write(ws, row, 1, item.get("name", ""), fmt)
                _safe_write(ws, row, 2, item.get("id", ""), self._fmts["cell"])
                _safe_write(ws, row, 3, errors, fmt)
                _safe_write(ws, row, 4, _to_int(item.get("devices", 0)), fmt)
                _safe_write(ws, row, 5, item.get("last_error", ""), self._fmts["cell"])
                _safe_write(ws, row, 6, item.get("top_error", ""), self._fmts["cell"])
                row += 1

        if device_failures:
            row += 1
            _safe_write(ws, row, 0, "Devices with High Failure Count (>5 errors)",
                        self._fmts["header"])
            row += 1
            dev_headers = ["Name", "Serial", "Device Type", "OS Version", "Username", "Count"]
            for c, h in enumerate(dev_headers):
                _safe_write(ws, row, c, h, self._fmts["header"])
            row += 1
            for item in device_failures[:50]:
                _safe_write(ws, row, 0, item.get("name", ""), self._fmts["cell"])
                _safe_write(ws, row, 1, item.get("serial", ""), self._fmts["cell"])
                _safe_write(ws, row, 2, item.get("device_type", ""), self._fmts["cell"])
                _safe_write(ws, row, 3, item.get("os_version", ""), self._fmts["cell"])
                _safe_write(ws, row, 4, item.get("username", ""), self._fmts["cell"])
                _safe_write(ws, row, 5, _to_int(item.get("count", 0)), self._fmts["cell"])
                row += 1

    def _write_patch(self) -> None:
        # jamf-cli pro report patch-status --output json returns a flat list:
        #   [{"title":"Firefox","id":"123","on_latest":100,"on_other":20,
        #     "total":120,"latest":"130.0","compliance_pct":"83%"}, ...]
        # Newer builds may instead return:
        #   [{"title":"Firefox","id":"123","installed":100,
        #     "total":120,"latest":"130.0","compliance_pct":"83%"}, ...]
        raw = self._bridge.patch_status()
        titles = raw if isinstance(raw, list) else []
        uses_installed_shape = any("installed" in item for item in titles if isinstance(item, dict))

        ws = self._wb.add_worksheet("Patch Compliance")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "Patch Compliance",
            f"Source: jamf-cli pro report patch-status | Generated: {ts}",
            self._fmts,
            ncols=6,
        )
        ws.set_column(0, 0, 40)
        ws.set_column(1, 5, 18)
        headers = (
            ["Software Title", "Installed", "Not Installed", "Total", "Latest Version",
             "Compliance %"]
            if uses_installed_shape
            else ["Software Title", "On Latest", "On Other", "Total", "Latest Version",
                  "Compliance %"]
        )
        for c, h in enumerate(headers):
            _safe_write(ws, row, c, h, self._fmts["header"])
        row += 1
        for item in titles:
            total = _to_int(item.get("total", 0))
            if uses_installed_shape:
                primary = _to_int(item.get("installed", 0))
                secondary = max(total - primary, 0)
            else:
                primary = _to_int(item.get("on_latest", 0))
                secondary = _to_int(item.get("on_other", 0))
                if total == 0:
                    total = primary + secondary

            pct_raw = str(item.get("compliance_pct", "")).strip()
            pct_match = re.fullmatch(r"(\d+(?:\.\d+)?)%", pct_raw)
            pct_value = float(pct_match.group(1)) / 100 if pct_match else None
            _safe_write(ws, row, 0, item.get("title", ""), self._fmts["cell"])
            _safe_write(ws, row, 1, primary, self._fmts["cell"])
            _safe_write(ws, row, 2, secondary, self._fmts["cell"])
            _safe_write(ws, row, 3, total, self._fmts["cell"])
            _safe_write(ws, row, 4, item.get("latest", ""), self._fmts["cell"])
            if pct_value is not None:
                _safe_write(ws, row, 5, pct_value, _pct_format(self._fmts, pct_value))
            else:
                _safe_write(ws, row, 5, pct_raw or "N/A", self._fmts["cell"])
            row += 1

    def _write_patch_failures(self) -> None:
        # jamf-cli pro report patch-status --scan-failures --output json (v1.4.0+) returns:
        #   [{"policy":"Firefox 130.0","policy_id":"42","device":"MacBook-001",
        #     "device_id":"123","status_date":"2026-04-01","attempt":3,
        #     "last_action":"Retrying","serial":"ABC123",
        #     "os_version":"15.7.3","username":"jdoe"}, ...]
        # Each row is one failing device × one patch policy.
        raw = self._bridge.patch_device_failures()
        rows = raw if isinstance(raw, list) else []

        ws = self._wb.add_worksheet("Patch Failures")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "Patch Failures",
            f"Source: jamf-cli pro report patch-status --scan-failures | Generated: {ts}",
            self._fmts,
            ncols=8,
        )
        ws.set_column(0, 0, 30)  # Device
        ws.set_column(1, 1, 16)  # Serial
        ws.set_column(2, 2, 14)  # OS Version
        ws.set_column(3, 3, 22)  # Username
        ws.set_column(4, 4, 42)  # Policy
        ws.set_column(5, 5, 18)  # Status Date
        ws.set_column(6, 6, 10)  # Attempts
        ws.set_column(7, 7, 42)  # Last Action

        headers = [
            "Device", "Serial", "OS Version", "Username",
            "Policy", "Status Date", "Attempts", "Last Action",
        ]
        for c, h in enumerate(headers):
            _safe_write(ws, row, c, h, self._fmts["header"])
        row += 1

        if not rows:
            _safe_write(ws, row, 0, "No patch device failures found.", self._fmts["cell"])
            return

        for item in rows:
            _safe_write(ws, row, 0, item.get("device", ""), self._fmts["cell"])
            _safe_write(ws, row, 1, item.get("serial", ""), self._fmts["cell"])
            _safe_write(ws, row, 2, item.get("os_version", ""), self._fmts["cell"])
            _safe_write(ws, row, 3, item.get("username", ""), self._fmts["cell"])
            _safe_write(ws, row, 4, item.get("policy", ""), self._fmts["cell"])
            _safe_write(ws, row, 5, item.get("status_date", ""), self._fmts["cell"])
            _safe_write(ws, row, 6, _to_int(item.get("attempt", 0)), self._fmts["cell"])
            _safe_write(ws, row, 7, item.get("last_action", ""), self._fmts["cell"])
            row += 1

    def _write_app_status(self) -> None:
        # jamf-cli pro report app-status --output json shares the profile-status envelope:
        #   [{"summary": {"total_errors": N, "unique_profiles": N, "unique_devices": N,
        #                 "days": N, "devices_high_failure": N, "devices_high_pending": N},
        #     "failures": [{"device_type":"...","name":"...","id":"...","errors":N,
        #                   "devices":N,"last_error":"...","top_error":"..."},...],
        #     "device_failures": [...]}]
        raw = self._bridge.app_status()
        envelope = _extract_envelope(raw)
        if not envelope:
            raise RuntimeError("app-status returned no data")
        summary = envelope.get("summary", {})
        failures = envelope.get("failures", [])
        device_failures = envelope.get("device_failures", [])

        ws = self._wb.add_worksheet("App Status")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "App Status",
            f"Source: jamf-cli pro report app-status | Generated: {ts}",
            self._fmts,
            ncols=7,
        )
        ws.set_column(0, 0, 40)
        ws.set_column(1, 6, 18)

        summary_fields = [
            ("total_errors", "Total Errors"),
            ("unique_profiles", "Unique Apps"),
            ("unique_devices", "Unique Devices"),
            ("days", "Days Lookback"),
            ("devices_high_failure", "Devices w/ High Failure"),
            ("devices_high_pending", "Devices w/ High Pending"),
        ]
        for key, label in summary_fields:
            val = summary.get(key)
            if val is not None:
                _safe_write(ws, row, 0, label, self._fmts["cell"])
                _safe_write(ws, row, 1, val, self._fmts["cell"])
                row += 1

        if failures:
            err_crit = int(self._config.thresholds.get("profile_error_critical", 50))
            err_warn = int(self._config.thresholds.get("profile_error_warning", 10))
            row += 1
            headers = ["Device Type", "App Name", "App ID", "Errors", "Devices",
                       "Last Error", "Top Error"]
            for c, h in enumerate(headers):
                _safe_write(ws, row, c, h, self._fmts["header"])
            row += 1
            for item in failures[:200]:
                errors = _to_int(item.get("errors", 0))
                fmt = self._severity_fmt(errors, err_warn, err_crit)
                _safe_write(ws, row, 0, item.get("device_type", ""), fmt)
                _safe_write(ws, row, 1, item.get("name", ""), fmt)
                _safe_write(ws, row, 2, item.get("id", ""), self._fmts["cell"])
                _safe_write(ws, row, 3, errors, fmt)
                _safe_write(ws, row, 4, _to_int(item.get("devices", 0)), fmt)
                _safe_write(ws, row, 5, item.get("last_error", ""), self._fmts["cell"])
                _safe_write(ws, row, 6, item.get("top_error", ""), self._fmts["cell"])
                row += 1

        if device_failures:
            row += 1
            _safe_write(ws, row, 0, "Devices with High Failure Count (>5 errors)",
                        self._fmts["header"])
            row += 1
            dev_headers = ["Name", "Serial", "Device Type", "OS Version", "Username", "Count"]
            for c, h in enumerate(dev_headers):
                _safe_write(ws, row, c, h, self._fmts["header"])
            row += 1
            for item in device_failures[:50]:
                _safe_write(ws, row, 0, item.get("name", ""), self._fmts["cell"])
                _safe_write(ws, row, 1, item.get("serial", ""), self._fmts["cell"])
                _safe_write(ws, row, 2, item.get("device_type", ""), self._fmts["cell"])
                _safe_write(ws, row, 3, item.get("os_version", ""), self._fmts["cell"])
                _safe_write(ws, row, 4, item.get("username", ""), self._fmts["cell"])
                _safe_write(ws, row, 5, _to_int(item.get("count", 0)), self._fmts["cell"])
                row += 1

    def _write_update_status(self) -> None:
        # jamf-cli pro report update-status --output json returns:
        #   {"summary": {"total_updates": N, "pending": N, "downloading": N,
        #                "installing": N, "installed": N, "errors": N},
        #    "ErrorDevices": [{"device_name":"...","serial":"...","os_version":"...",
        #                      "status":"...","product_key":"...","updated":"..."},...]}
        # The outer response may be wrapped in a list.
        raw = self._bridge.update_status()
        envelope = _extract_envelope(raw)
        if not envelope:
            raise RuntimeError("update-status returned no data")
        summary = envelope.get("summary", {})
        error_devices = envelope.get("ErrorDevices", [])
        no_data_message = str(envelope.get("message", "") or "").strip()

        ws = self._wb.add_worksheet("Update Status")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row = _write_sheet_header(
            ws,
            "Update Status",
            f"Source: jamf-cli pro report update-status | Generated: {ts}",
            self._fmts,
            ncols=6,
        )
        ws.set_column(0, 0, 32)
        ws.set_column(1, 5, 20)

        summary_fields = [
            ("total_updates", "Total Updates"),
            ("pending", "Pending"),
            ("downloading", "Downloading"),
            ("installing", "Installing"),
            ("installed", "Installed"),
            ("errors", "Errors"),
        ]
        for key, label in summary_fields:
            val = summary.get(key)
            if val is not None:
                _safe_write(ws, row, 0, label, self._fmts["cell"])
                _safe_write(ws, row, 1, val, self._fmts["cell"])
                row += 1

        if not summary and not error_devices and no_data_message:
            _safe_write(ws, row, 0, "Status", self._fmts["header"])
            _safe_write(ws, row, 1, "Details", self._fmts["header"])
            row += 1
            _safe_write(ws, row, 0, "No Data", self._fmts["yellow"])
            _safe_write(ws, row, 1, no_data_message, self._fmts["yellow"])
            row += 1

        if error_devices:
            row += 1
            _safe_write(ws, row, 0, "Devices with Update Errors", self._fmts["header"])
            row += 1
            dev_headers = ["Device Name", "Serial", "OS Version", "Status",
                           "Product Key", "Updated"]
            for c, h in enumerate(dev_headers):
                _safe_write(ws, row, c, h, self._fmts["header"])
            row += 1
            for item in error_devices[:200]:
                _safe_write(ws, row, 0, item.get("device_name", ""), self._fmts["cell"])
                _safe_write(ws, row, 1, item.get("serial", ""), self._fmts["cell"])
                _safe_write(ws, row, 2, item.get("os_version", ""), self._fmts["cell"])
                _safe_write(ws, row, 3, item.get("status", ""), self._fmts["cell"])
                _safe_write(ws, row, 4, item.get("product_key", ""), self._fmts["cell"])
                _safe_write(ws, row, 5, item.get("updated", ""), self._fmts["cell"])
                row += 1


# ---------------------------------------------------------------------------
# CSVDashboard
# ---------------------------------------------------------------------------


class CSVDashboard:
    """Generates Excel sheets from a Jamf Pro CSV inventory export.

    Args:
        config: Loaded Config instance.
        csv_path: Path to the primary CSV file.
        workbook: Active xlsxwriter Workbook.
        fmts: Format dict from _build_formats.
        extra_csv_paths: Optional list of additional CSV paths to merge into the
            primary DataFrame.  Each extra CSV is loaded and concatenated; a
            "CSV Source" column is added to every row so downstream sheets can
            distinguish which export each record came from.  Missing columns are
            filled with empty strings.  Column names must match across files for
            the config mapping to work correctly — the primary CSV's schema is
            authoritative.
    """

    def __init__(
        self,
        config: Config,
        csv_path: str,
        workbook: xlsxwriter.Workbook,
        fmts: dict,
        extra_csv_paths: Optional[list[str]] = None,
    ) -> None:
        self._config = config
        self._mapper = ColumnMapper(config)
        self._wb = workbook
        self._fmts = fmts
        try:
            primary = pd.read_csv(csv_path, dtype=str, encoding="utf-8-sig").fillna("")
        except Exception as exc:
            raise SystemExit(
                f"Error: could not read CSV '{csv_path}': {exc}"
            ) from exc

        if extra_csv_paths:
            frames: list[Any] = []
            primary["CSV Source"] = Path(csv_path).name
            frames.append(primary)
            for extra_path in extra_csv_paths:
                try:
                    extra_df = pd.read_csv(
                        extra_path, dtype=str, encoding="utf-8-sig"
                    ).fillna("")
                    extra_df["CSV Source"] = Path(extra_path).name
                    frames.append(extra_df)
                    print(f"  Merged extra CSV: {Path(extra_path).name} ({len(extra_df)} rows)")
                except Exception as exc:
                    print(f"  [warn] Could not read extra CSV '{extra_path}': {exc} — skipping")
            all_col_sets = [set(f.columns) for f in frames]
            union_cols = set.union(*all_col_sets)
            for i, cols in enumerate(all_col_sets):
                missing = union_cols - cols
                if missing:
                    names = ", ".join(sorted(missing)[:5])
                    suffix = " ..." if len(missing) > 5 else ""
                    print(
                        f"  [warn] CSV {i + 1} is missing {len(missing)} column(s) present in"
                        f" other CSVs — those cells will be empty: {names}{suffix}"
                    )
            self._df = pd.concat(frames, ignore_index=True).fillna("")
            print(
                f"  Loaded {len(frames)} CSV(s): {len(self._df)} rows total,"
                f" {len(self._df.columns)} columns"
            )
        else:
            self._df = primary
            print(f"  Loaded CSV: {len(self._df)} rows, {len(self._df.columns)} columns")

    def write_all(self) -> list[str]:
        """Write all CSV-derived sheets. Returns list of sheet names written."""
        written = []
        sheets = [
            ("Device Inventory", self._write_inventory),
            ("Stale Devices", self._write_stale),
            ("Security Controls", self._write_security_controls),
            ("Security Agents", self._write_security_agents),
            ("Compliance", self._write_compliance),
        ]
        for name, fn in sheets:
            try:
                fn()
                written.append(name)
                print(f"  [ok] {name}")
            except (KeyError, ValueError, RuntimeError) as exc:
                print(f"  [skip] {name}: {exc}")
            except Exception as exc:
                print(f"  [skip] {name}: unexpected error — {type(exc).__name__}: {exc}")

        for ea in self._config.custom_eas:
            ea_name = ea.get("name", "Custom EA")
            try:
                self._write_custom_ea(ea)
                written.append(ea_name)
                print(f"  [ok] {ea_name}")
            except (KeyError, ValueError, RuntimeError) as exc:
                print(f"  [skip] {ea_name}: {exc}")
            except Exception as exc:
                print(f"  [skip] {ea_name}: unexpected error — {type(exc).__name__}: {exc}")
        return written

    def _col(self, logical: str) -> Optional[str]:
        return self._mapper.get(logical)

    def _get(self, row: Any, logical: str) -> str:
        return self._mapper.extract(row, logical)

    def _device_name(self, row: Any) -> str:
        """Extract computer name from a DataFrame row using the configured column.

        Args:
            row: A pandas Series (DataFrame row) from self._df.iterrows().

        Returns:
            The device name string, or empty string if the column is not configured
            or not present in this row.
        """
        col = self._col("computer_name")
        return str(row[col]) if col and col in row.index else ""

    def _write_inventory(self) -> None:
        stale_days = int(self._config.thresholds.get("stale_device_days", 30))
        name_col = self._col("computer_name")
        checkin_col = self._col("last_checkin")
        if not name_col:
            raise RuntimeError("computer_name column not configured")
        active_rows = []
        for _, row in self._df.iterrows():
            checkin = str(row.get(checkin_col, "")) if checkin_col else ""
            days = _days_since(checkin) if checkin else None
            if days is not None and 0 <= days <= stale_days:
                active_rows.append(row)

        ws = self._wb.add_worksheet("Device Inventory")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row_i = _write_sheet_header(
            ws,
            "Device Inventory",
            f"Active devices (checked in within {stale_days} days) | Generated: {ts}",
            self._fmts,
            ncols=6,
        )
        logical_cols = ["computer_name", "serial_number", "operating_system",
                        "last_checkin", "department", "model"]
        headers = [lc.replace("_", " ").title() for lc in logical_cols]
        col_names = [self._col(lc) for lc in logical_cols]
        for c, h in enumerate(headers):
            _safe_write(ws, row_i, c, h, self._fmts["header"])
        row_i += 1
        for row in active_rows:
            for c, cn in enumerate(col_names):
                val = str(row[cn]) if cn and cn in row.index else ""
                _safe_write(ws, row_i, c, val, self._fmts["cell"])
            row_i += 1
        ws.set_column(0, 0, 30)
        ws.set_column(1, 5, 22)

    def _write_stale(self) -> None:
        stale_days = int(self._config.thresholds.get("stale_device_days", 30))
        name_col = self._col("computer_name")
        checkin_col = self._col("last_checkin")
        if not name_col or not checkin_col:
            raise RuntimeError("computer_name or last_checkin column not configured")
        ws = self._wb.add_worksheet("Stale Devices")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row_i = _write_sheet_header(
            ws,
            "Stale Devices",
            f"Devices not checked in within {stale_days} days | Generated: {ts}",
            self._fmts,
            ncols=6,
        )
        headers = ["Computer Name", "Serial Number", "Days Stale", "OS", "Department", "Manager"]
        for c, h in enumerate(headers):
            _safe_write(ws, row_i, c, h, self._fmts["header"])
        row_i += 1
        for _, row in self._df.iterrows():
            checkin = str(row.get(checkin_col, ""))
            days = _days_since(checkin)
            if days is not None and days > stale_days:
                manager_raw = self._get(row, "manager")
                _safe_write(ws, row_i, 0, self._get(row, "computer_name"), self._fmts["cell"])
                _safe_write(ws, row_i, 1, self._get(row, "serial_number"), self._fmts["cell"])
                _safe_write(ws, row_i, 2, days, self._fmts["int"])
                _safe_write(ws, row_i, 3, self._get(row, "operating_system"), self._fmts["cell"])
                _safe_write(ws, row_i, 4, self._get(row, "department"), self._fmts["cell"])
                _safe_write(ws, row_i, 5, _parse_manager(manager_raw), self._fmts["cell"])
                row_i += 1
        ws.set_column(0, 0, 30)
        ws.set_column(1, 5, 22)

    def _write_security_controls(self) -> None:
        control_fields = [
            "filevault",
            "sip",
            "firewall",
            "gatekeeper",
            "secure_boot",
            "bootstrap_token",
        ]
        configured = [(f, self._col(f)) for f in control_fields if self._col(f)]
        if not configured:
            raise RuntimeError("no security control columns configured")
        ws = self._wb.add_worksheet("Security Controls")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row_i = _write_sheet_header(
            ws, "Security Controls", f"Generated: {ts}", self._fmts, ncols=4
        )
        headers = ["Control", "Enabled/Compliant", "Not Compliant", "Compliance %"]
        for c, h in enumerate(headers):
            _safe_write(ws, row_i, c, h, self._fmts["header"])
        row_i += 1
        for logical, col in configured:
            total = len(self._df)
            compliant = self._df[col].apply(
                lambda value: _security_control_is_compliant(logical, value)
            ).sum()
            non_compliant = total - compliant
            pct = compliant / total if total > 0 else 0.0
            label = logical.replace("_", " ").title()
            _safe_write(ws, row_i, 0, label, self._fmts["cell"])
            _safe_write(ws, row_i, 1, int(compliant), self._fmts["cell"])
            _safe_write(ws, row_i, 2, int(non_compliant), self._fmts["cell"])
            _safe_write(ws, row_i, 3, pct, _pct_format(self._fmts, pct))
            row_i += 1
        ws.set_column(0, 0, 30)
        ws.set_column(1, 3, 22)

    def _write_security_agents(self) -> None:
        agents = self._config.security_agents
        if not agents:
            raise RuntimeError("no security agents configured")
        ws = self._wb.add_worksheet("Security Agents")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row_i = _write_sheet_header(
            ws, "Security Agent Status", f"Generated: {ts}", self._fmts, ncols=5
        )
        for agent in agents:
            col = agent.get("column", "")
            connected_val = _normalized_text(agent.get("connected_value", "connected"))
            if col not in self._df.columns:
                continue
            if not connected_val:
                print(
                    f"  [warn] Security agent {agent.get('name', col)!r}:"
                    " connected_value is empty — all non-empty cells will be counted as"
                    " connected. Set a specific value such as 'Installed' or 'Running'."
                )
                continue
            statuses = self._df[col].fillna("").astype(str)
            connected_mask = _contains_case_insensitive(statuses, connected_val)
            total = len(self._df)
            connected = int(connected_mask.sum())
            disconnected = total - connected
            pct = connected / total if total > 0 else 0.0
            _safe_write(ws, row_i, 0, agent.get("name", col), self._fmts["header"])
            row_i += 1
            for lbl, val in [("Connected", connected), ("Not Connected", disconnected),
                             ("Total", total)]:
                _safe_write(ws, row_i, 0, lbl, self._fmts["cell"])
                _safe_write(ws, row_i, 1, int(val), self._fmts["cell"])
                row_i += 1
            _safe_write(ws, row_i, 0, "Compliance %", self._fmts["cell"])
            _safe_write(ws, row_i, 1, pct, _pct_format(self._fmts, pct))
            row_i += 2
            non_connected_df = self._df[~connected_mask]
            if not non_connected_df.empty:
                _safe_write(ws, row_i, 0, "Non-Connected Devices", self._fmts["header"])
                row_i += 1
                for _, dr in non_connected_df.iterrows():
                    name = self._device_name(dr)
                    status = str(dr[col])
                    _safe_write(ws, row_i, 0, name, self._fmts["cell"])
                    _safe_write(ws, row_i, 1, status, self._fmts["cell"])
                    row_i += 1
            row_i += 1
        ws.set_column(0, 0, 35)
        ws.set_column(1, 1, 25)

    def _write_compliance(self) -> None:
        comp = self._config.compliance
        if not comp.get("enabled"):
            raise RuntimeError("compliance not enabled in config")
        count_col = comp.get("failures_count_column", "")
        list_col = comp.get("failures_list_column", "")
        label = _compliance_label(comp)
        if count_col and count_col not in self._df.columns:
            raise RuntimeError(f"failures_count_column '{count_col}' not in CSV")
        ws = self._wb.add_worksheet("Compliance")
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row_i = _write_sheet_header(
            ws, label, f"Generated: {ts}", self._fmts, ncols=4
        )
        if count_col:
            counts = pd.to_numeric(self._df[count_col], errors="coerce").fillna(0)
            compliant = int((counts == 0).sum())
            non_compliant = int((counts > 0).sum())
            total = len(self._df)
            pct = compliant / total if total > 0 else 0.0
            for lbl, val in [("Fully Compliant", compliant), ("Has Failures", non_compliant),
                             ("Total Devices", total)]:
                _safe_write(ws, row_i, 0, lbl, self._fmts["cell"])
                _safe_write(ws, row_i, 1, val, self._fmts["cell"])
                row_i += 1
            _safe_write(ws, row_i, 0, "Compliance %", self._fmts["cell"])
            _safe_write(ws, row_i, 1, pct, _pct_format(self._fmts, pct))
            row_i += 2

        if list_col and list_col in self._df.columns:
            rule_counts: dict[str, int] = {}
            for val in self._df[list_col]:
                for rule in _split_multi_value_cell(val):
                    rule_counts[rule] = rule_counts.get(rule, 0) + 1
            _safe_write(ws, row_i, 0, "Top Failing Rules", self._fmts["header"])
            _safe_write(ws, row_i, 1, "Device Count", self._fmts["header"])
            row_i += 1
            for rule, cnt in sorted(rule_counts.items(), key=lambda x: -x[1])[:30]:
                _safe_write(ws, row_i, 0, rule, self._fmts["cell"])
                _safe_write(ws, row_i, 1, cnt, self._fmts["cell"])
                row_i += 1
        ws.set_column(0, 0, 50)
        ws.set_column(1, 1, 20)

    def _write_custom_ea(self, ea: dict) -> None:
        """Write a single custom EA sheet based on its type configuration.

        Args:
            ea: Dict with keys: name, column, type, and type-specific options.
        """
        col = ea.get("column", "")
        ea_type = ea.get("type", "text")
        name = ea.get("name", col)
        if col not in self._df.columns:
            raise RuntimeError(f"column '{col}' not found in CSV")

        ws = self._wb.add_worksheet(name[:31])
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        row_i = _write_sheet_header(
            ws, name, f"Type: {ea_type} | Generated: {ts}", self._fmts, ncols=4
        )

        dispatch = {
            "boolean": self._ea_boolean,
            "percentage": self._ea_percentage,
            "version": self._ea_version,
            "text": self._ea_text,
            "date": self._ea_date,
        }
        handler = dispatch.get(ea_type, self._ea_text)
        handler(ws, row_i, col, ea)

    def _ea_boolean(self, ws: Any, row_i: int, col: str, ea: dict) -> None:
        true_val = ea.get("true_value", "Yes").lower()
        series = self._df[col].str.strip().str.lower()
        non_blank = series[series != ""]
        passed = int((non_blank == true_val).sum())
        unknown = int((series == "").sum())
        failed = len(non_blank) - passed
        reported = passed + failed
        pct = passed / reported if reported > 0 else 0.0
        for lbl, val in [("Pass", passed), ("Fail", failed), ("Total (reported)", reported)]:
            _safe_write(ws, row_i, 0, lbl, self._fmts["cell"])
            _safe_write(ws, row_i, 1, val, self._fmts["cell"])
            row_i += 1
        if unknown > 0:
            _safe_write(ws, row_i, 0, "Unknown / Not Reported", self._fmts["yellow"])
            _safe_write(ws, row_i, 1, unknown, self._fmts["yellow"])
            row_i += 1
        _safe_write(ws, row_i, 0, "Compliance %", self._fmts["cell"])
        _safe_write(ws, row_i, 1, pct, _pct_format(self._fmts, pct))
        row_i += 2
        failed_df = self._df[
            (self._df[col].str.strip().str.lower() != true_val)
            & (self._df[col].str.strip() != "")
        ]
        if not failed_df.empty:
            _safe_write(ws, row_i, 0, "Failing Devices", self._fmts["header"])
            _safe_write(ws, row_i, 1, "Value", self._fmts["header"])
            row_i += 1
            for _, dr in failed_df.iterrows():
                _safe_write(ws, row_i, 0, self._device_name(dr), self._fmts["cell"])
                _safe_write(ws, row_i, 1, str(dr[col]), self._fmts["cell"])
                row_i += 1

    def _ea_percentage(self, ws: Any, row_i: int, col: str, ea: dict) -> None:
        warn = float(
            ea.get("warning_threshold", self._config.thresholds.get("warning_disk_percent", 80))
        )
        crit = float(
            ea.get("critical_threshold", self._config.thresholds.get("critical_disk_percent", 90))
        )
        nums = pd.to_numeric(self._df[col].str.replace("%", "", regex=False), errors="coerce")
        critical_df = self._df[nums >= crit]
        warning_df = self._df[(nums >= warn) & (nums < crit)]
        for label, sub_df in [("Critical (>= {:.0f}%)".format(crit), critical_df),
                               ("Warning ({:.0f}% - {:.0f}%)".format(warn, crit), warning_df)]:
            _safe_write(ws, row_i, 0, label, self._fmts["header"])
            _safe_write(ws, row_i, 1, "Value", self._fmts["header"])
            row_i += 1
            for _, dr in sub_df.iterrows():
                _safe_write(ws, row_i, 0, self._device_name(dr), self._fmts["cell"])
                _safe_write(ws, row_i, 1, str(dr[col]), self._fmts["cell"])
                row_i += 1
            row_i += 1

    def _ea_version(self, ws: Any, row_i: int, col: str, ea: dict) -> None:
        current = [str(v).lower() for v in ea.get("current_versions", [])]
        dist = self._df[col].value_counts().to_dict()
        _safe_write(ws, row_i, 0, "Version", self._fmts["header"])
        _safe_write(ws, row_i, 1, "Count", self._fmts["header"])
        _safe_write(ws, row_i, 2, "Current?", self._fmts["header"])
        row_i += 1
        has_current_list = bool(current)
        for ver, cnt in sorted(dist.items(), key=lambda x: -x[1]):
            display_ver = _display_value(ver)
            is_current = (
                any(str(ver).lower().startswith(cv.lower()) for cv in current)
                if has_current_list else None
            )
            if not str(ver).strip():
                fmt = self._fmts["yellow"]
            elif is_current is True:
                fmt = self._fmts["green"]
            elif is_current is False:
                fmt = self._fmts["red"]
            else:
                fmt = self._fmts["cell"]
            _safe_write(ws, row_i, 0, display_ver, fmt)
            _safe_write(ws, row_i, 1, cnt, fmt)
            if is_current is True:
                current_label = "Yes"
            elif is_current is False:
                current_label = "No"
            else:
                current_label = ""
            _safe_write(ws, row_i, 2, current_label, fmt)
            row_i += 1

    def _ea_text(self, ws: Any, row_i: int, col: str, ea: dict) -> None:
        dist = self._df[col].value_counts().to_dict()
        _safe_write(ws, row_i, 0, "Value", self._fmts["header"])
        _safe_write(ws, row_i, 1, "Count", self._fmts["header"])
        row_i += 1
        for val, cnt in sorted(dist.items(), key=lambda x: -x[1]):
            fmt = self._fmts["yellow"] if not str(val).strip() else self._fmts["cell"]
            _safe_write(ws, row_i, 0, _display_value(val), fmt)
            _safe_write(ws, row_i, 1, cnt, fmt)
            row_i += 1

    def _ea_date(self, ws: Any, row_i: int, col: str, ea: dict) -> None:
        ea_name = ea.get("name", col)
        warn_days = int(ea.get("warning_days",
                                self._config.thresholds.get("cert_warning_days", 90)))
        _safe_write(ws, row_i, 0, "Device", self._fmts["header"])
        _safe_write(ws, row_i, 1, "Date Value", self._fmts["header"])
        _safe_write(ws, row_i, 2, "Days Until Expiry", self._fmts["header"])
        row_i += 1
        now = datetime.now(timezone.utc)
        rows_parsed = 0
        for _, dr in self._df.iterrows():
            raw = str(dr[col])
            parsed = pd.to_datetime(raw, errors="coerce", utc=True)
            if pd.isnull(parsed):
                continue
            rows_parsed += 1
            delta = parsed - now
            days_until = int(delta.total_seconds() / 86400)
            fmt = (self._fmts["red"] if days_until < 0 else
                   self._fmts["yellow"] if days_until < warn_days else
                   self._fmts["green"])
            _safe_write(ws, row_i, 0, self._device_name(dr), fmt)
            _safe_write(ws, row_i, 1, raw, fmt)
            _safe_write(ws, row_i, 2, days_until, fmt)
            row_i += 1
        if rows_parsed == 0:
            print(
                f"[WARN] EA '{ea_name}': no dates could be parsed from column '{col}'."
                " Check the date format in your CSV."
            )


# ---------------------------------------------------------------------------
# Chart generation
# ---------------------------------------------------------------------------

# Human-readable names for macOS major versions used in chart labels.
MACOS_NAMES: dict[str, str] = {
    "10": "Mac OS X 10",
    "11": "macOS Big Sur 11",
    "12": "macOS Monterey 12",
    "13": "macOS Ventura 13",
    "14": "macOS Sonoma 14",
    "15": "macOS Sequoia 15",
    "26": "macOS Tahoe 26",
}

# Colors per major version for the combined adoption timeline.
MAJOR_VERSION_COLORS: dict[str, str] = {
    "12": "#1f77b4",
    "13": "#2ca02c",
    "14": "#ff7f0e",
    "15": "#e377c2",
    "26": "#bcbd22",
}

INVENTORY_EXPORT_COLUMNS: list[str] = [
    "Jamf Pro ID",
    "Computer Name",
    "Serial Number",
    "Managed",
    "Operating System",
    "OS Build",
    "OS Rapid Security Response",
    "FileVault Status",
    "System Integrity Protection",
    "Firewall Enabled",
    "Bootstrap Token Escrowed",
    "Bootstrap Token Allowed",
    "Gatekeeper",
    "Model",
    "Asset Tag",
    "IP Address",
    "Last Check-in",
    "Last Report",
    "Last Enrollment",
    "Username",
    "Real Name",
    "Email Address",
    "Position",
    "Department",
    "Building",
    "Room",
    "Site",
    "UDID",
    "Management ID",
]

INVENTORY_SECURITY_DETAIL_COLUMNS: list[str] = [
    "FileVault Status",
    "System Integrity Protection",
    "Firewall Enabled",
    "Bootstrap Token Escrowed",
    "Bootstrap Token Allowed",
    "Gatekeeper",
]

INVENTORY_SECURITY_RESOURCE_MAP: dict[str, str] = {
    "FileVault": "FileVault Status",
    "SIP": "System Integrity Protection",
    "Firewall": "Firewall Enabled",
    "Bootstrap Token Escrowed": "Bootstrap Token Escrowed",
    "Bootstrap Token Allowed": "Bootstrap Token Allowed",
    "Gatekeeper": "Gatekeeper",
}


class ChartGenerator:
    """Generates charts from CSV snapshots and jamf-cli JSON snapshot history.

    Supported chart families:
    - macOS adoption timeline from historical CSV exports or jamf-cli
      inventory-summary snapshots.
    - Compliance trend from CSV snapshots containing a failures-count column.
    - Device state trend from jamf-cli device-compliance snapshots.

    Args:
        config: Loaded Config instance.
        csv_path: Path to the current CSV snapshot (optional).
        historical_dir: Directory of dated CSV snapshots for trend analysis.
        output_dir: Directory where generated PNG files are saved.
        workbook: Active xlsxwriter Workbook for embedding charts.
        jamf_cli_dir: Directory containing cached jamf-cli JSON snapshots.
        output_stem: Stem used as the prefix for PNG filenames.
    """

    def __init__(
        self,
        config: "Config",
        csv_path: Optional[str],
        historical_dir: Optional[str],
        output_dir: Path,
        workbook: xlsxwriter.Workbook,
        jamf_cli_dir: Optional[Path],
        output_stem: str,
    ) -> None:
        self._config = config
        self._csv_path = csv_path
        self._hist_dir = historical_dir
        self._out_dir = output_dir
        self._chart_dir = output_dir
        self._wb = workbook
        self._jamf_cli_dir = jamf_cli_dir.expanduser() if jamf_cli_dir else None
        self._chart_prefix = _filename_component(output_stem)

    def generate_all(self) -> tuple[list[str], list[str]]:
        """Generate enabled charts and return (png_paths, source_labels)."""
        if not _load_matplotlib():
            print("  [skip] Charts: matplotlib not installed (pip install matplotlib)")
            return [], []
        charts_cfg = self._config.get("charts") or {}
        if not charts_cfg.get("enabled", True):
            return [], []

        save_png = charts_cfg.get("save_png", True) is not False
        temp_chart_dir: Optional[Path] = None
        if save_png:
            self._chart_dir = self._out_dir
        else:
            temp_chart_dir = Path(tempfile.mkdtemp(prefix="jamf-reports-community-charts-"))
            self._chart_dir = temp_chart_dir

        try:
            png_paths: list[str] = []
            chart_sources: set[str] = set()
            csv_snapshots = self._load_snapshots(charts_cfg)

            if charts_cfg.get("os_adoption", {}).get("enabled", True):
                paths, source_label = self._generate_os_adoption(csv_snapshots, charts_cfg)
                png_paths.extend(paths)
                if source_label:
                    chart_sources.add(source_label)

            comp_cfg = charts_cfg.get("compliance_trend", {})
            if comp_cfg.get("enabled", True):
                fail_col = self._config.compliance.get("failures_count_column", "")
                if csv_snapshots and fail_col:
                    path = self._generate_compliance_trend(csv_snapshots, fail_col, comp_cfg)
                    if path:
                        png_paths.append(path)
                        chart_sources.add("CSV snapshots")
                else:
                    print("  [skip] Compliance trend: failures_count_column not configured")

            device_state_cfg = charts_cfg.get("device_state_trend", {})
            if device_state_cfg.get("enabled", True):
                path = self._generate_device_state_trend()
                if path:
                    png_paths.append(path)
                    chart_sources.add("jamf-cli snapshots")

            if not png_paths:
                print("  [skip] Charts: no CSV or jamf-cli snapshot history found")
                return [], []

            if png_paths and charts_cfg.get("embed_in_xlsx", True):
                self._embed_charts(png_paths)

            return png_paths, sorted(chart_sources)
        finally:
            if temp_chart_dir:
                shutil.rmtree(temp_chart_dir, ignore_errors=True)

    def _load_snapshots(self, charts_cfg: dict[str, Any]) -> list[tuple[datetime, Any]]:
        """Load all CSV snapshots sorted by date. Returns list of (date, DataFrame)."""
        snapshots: list[tuple[datetime, Any]] = []
        relevant_columns: set[str] = set()
        os_col = self._config.columns.get("operating_system", "")
        if charts_cfg.get("os_adoption", {}).get("enabled", True) and os_col:
            relevant_columns.add(os_col)
        fail_col = self._config.compliance.get("failures_count_column", "")
        if charts_cfg.get("compliance_trend", {}).get("enabled", True) and fail_col:
            relevant_columns.add(fail_col)

        if self._hist_dir and Path(self._hist_dir).is_dir():
            for f in sorted(Path(self._hist_dir).rglob("*.csv")):
                try:
                    header_df = pd.read_csv(f, nrows=0, encoding="utf-8-sig")
                except Exception as exc:
                    print(f"  [warn] Skipping unreadable CSV snapshot {f.name}: {exc}")
                    continue
                if relevant_columns and not relevant_columns.intersection(set(header_df.columns)):
                    continue
                dt = self._parse_date_from_path(f)
                try:
                    df = pd.read_csv(f, dtype=str, encoding="utf-8-sig").fillna("")
                except Exception as exc:
                    print(f"  [warn] Skipping CSV snapshot {f.name}: {exc}")
                    continue
                snapshots.append((dt, df))

        if self._csv_path and Path(self._csv_path).is_file():
            current_dt = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
            if not any(s[0].date() == current_dt.date() for s in snapshots):
                try:
                    df = pd.read_csv(
                        self._csv_path, dtype=str, encoding="utf-8-sig"
                    ).fillna("")
                    snapshots.append((current_dt, df))
                except Exception as exc:
                    print(f"  [warn] Could not read current CSV: {exc}")

        snapshots.sort(key=lambda x: x[0])
        return snapshots

    def _parse_date_from_path(self, path: Path) -> datetime:
        """Extract a timestamp from a filename, falling back to file mtime."""
        name = path.stem
        for pattern, fmt in (
            (r"(\d{4}-\d{2}-\d{2}[T_]\d{6})", "%Y-%m-%dT%H%M%S"),
            (r"(\d{4}-\d{2}-\d{2}[T_]\d{6})", "%Y-%m-%d_%H%M%S"),
            (r"(\d{8}[T_]\d{6})", "%Y%m%dT%H%M%S"),
            (r"(\d{8}[T_]\d{6})", "%Y%m%d_%H%M%S"),
        ):
            match = re.search(pattern, name)
            if not match:
                continue
            value = match.group(1)
            for candidate_fmt in {fmt, fmt.replace("T", "_"), fmt.replace("_", "T")}:
                try:
                    return datetime.strptime(value, candidate_fmt)
                except ValueError:
                    continue
        m = re.search(r"(\d{4}-\d{2}-\d{2})", name)
        if m:
            try:
                return datetime.strptime(m.group(1), "%Y-%m-%d")
            except ValueError:
                pass
        m = re.search(r"(\d{8})", name)
        if m:
            try:
                return datetime.strptime(m.group(1), "%Y%m%d")
            except ValueError:
                pass
        return datetime.fromtimestamp(path.stat().st_mtime).replace(
            hour=0, minute=0, second=0, microsecond=0
        )

    def _load_json_snapshots(self, report_names: list[str]) -> list[tuple[datetime, Any]]:
        """Load jamf-cli JSON snapshots sorted by timestamp."""
        if not self._jamf_cli_dir or not self._jamf_cli_dir.is_dir():
            return []

        candidates: dict[str, Path] = {}
        for report_name in report_names:
            report_dir = self._jamf_cli_dir / report_name
            if report_dir.is_dir():
                for path in report_dir.rglob("*.json"):
                    if ".partial" not in path.name:
                        candidates[str(path)] = path
                continue
            pattern = f"{report_name}_*.json"
            for path in self._jamf_cli_dir.rglob(pattern):
                if ".partial" not in path.name:
                    candidates[str(path)] = path

        snapshots: list[tuple[datetime, Any]] = []
        for path in sorted(candidates.values()):
            try:
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
            except (json.JSONDecodeError, OSError) as exc:
                print(f"  [warn] Skipping unreadable JSON snapshot {path.name}: {exc}")
                continue
            snapshots.append((self._parse_date_from_path(path), data))

        snapshots.sort(key=lambda item: item[0])
        return snapshots

    def _build_os_timeseries(
        self, snapshots: list[tuple[datetime, Any]], os_col: str
    ) -> Any:
        """Build a DataFrame of device counts per OS version over time.

        Returns a DataFrame with dates as index and OS version strings as columns.
        """
        records = []
        for dt, df in snapshots:
            if os_col not in df.columns:
                continue
            counts = df[os_col].str.strip().value_counts()
            row: dict[str, Any] = {"date": dt}
            row.update(counts.to_dict())
            records.append(row)
        if not records:
            return pd.DataFrame()
        ts = pd.DataFrame(records).set_index("date").fillna(0).sort_index()
        return ts.astype(int)

    def _major_version(self, ver: str) -> str:
        """Extract the numeric major version from an OS version string.

        Handles both bare versions ("26.1.0" → "26") and full name strings
        from Jamf CSV exports ("macOS 26.1.0" → "26", "Mac OS X 10.15.7" → "10").
        """
        m = re.search(r"\b(\d+)\.\d", str(ver))
        return m.group(1) if m else str(ver).strip()

    def _build_inventory_summary_timeseries(self, snapshots: list[tuple[datetime, Any]]) -> Any:
        """Build a DataFrame of OS version counts from jamf-cli inventory-summary snapshots."""
        records = []
        for dt, data in snapshots:
            rows = data if isinstance(data, list) else []
            row: dict[str, Any] = {"date": dt}
            for item in rows:
                if not isinstance(item, dict):
                    continue
                version = str(item.get("os_version", "") or "").strip()
                if not version:
                    continue
                row[version] = row.get(version, 0) + _to_int(item.get("count", 0))
            if len(row) > 1:
                records.append(row)

        if not records:
            return pd.DataFrame()
        ts = pd.DataFrame(records).groupby("date", as_index=True).sum().sort_index().fillna(0)
        return ts.astype(int)

    def _generate_os_adoption(
        self,
        csv_snapshots: list[tuple[datetime, Any]],
        charts_cfg: dict,
    ) -> tuple[list[str], str]:
        """Generate OS adoption charts. Returns (PNG paths, source label)."""
        ts = pd.DataFrame()
        source_label = ""
        os_col = self._config.columns.get("operating_system", "")
        if csv_snapshots and os_col:
            ts = self._build_os_timeseries(csv_snapshots, os_col)
            if not ts.empty:
                source_label = "CSV snapshots"

        if ts.empty:
            inventory_snapshots = self._load_json_snapshots(
                ["inventory-summary", "inventory_summary"]
            )
            ts = self._build_inventory_summary_timeseries(inventory_snapshots)
            if not ts.empty:
                source_label = "jamf-cli snapshots"

        if ts.empty:
            print(
                "  [skip] OS adoption: no CSV operating_system history or"
                " jamf-cli inventory-summary snapshots found"
            )
            return [], ""

        png_paths = []
        combined_path = self._plot_adoption_combined(ts)
        if combined_path:
            png_paths.append(combined_path)
            print(f"  [chart] {Path(combined_path).name}")

        if charts_cfg.get("os_adoption", {}).get("per_major_charts", True):
            majors = sorted({self._major_version(v) for v in ts.columns})
            for major in majors:
                major_cols = [c for c in ts.columns if self._major_version(c) == major]
                if not major_cols:
                    continue
                path = self._plot_per_major(ts[major_cols], major)
                if path:
                    png_paths.append(path)
                    print(f"  [chart] {Path(path).name}")

        return png_paths, source_label

    def _chart_path(self, chart_name: str) -> str:
        """Return a chart PNG path using the current output stem as a prefix."""
        return str(self._chart_dir / f"{self._chart_prefix}_{chart_name}.png")

    def _plot_adoption_combined(self, ts: Any) -> Optional[str]:
        """Plot combined macOS adoption timeline grouped by major version."""
        major_ts: dict[str, Any] = {}
        for col in ts.columns:
            major = self._major_version(col)
            major_ts[major] = major_ts.get(major, 0) + ts[col]

        fig, ax = plt.subplots(figsize=(12, 6))
        for major, series in sorted(major_ts.items()):
            label = MACOS_NAMES.get(major, f"macOS {major}")
            color = MAJOR_VERSION_COLORS.get(major)
            kwargs: dict[str, Any] = {"label": label, "marker": "o", "markersize": 4}
            if color:
                kwargs["color"] = color
            ax.plot(series.index, series.values, **kwargs)

        ax.set_title("macOS Version Adoption Over Time", fontweight="bold")
        ax.set_xlabel("Date")
        ax.set_ylabel("Number of Devices")
        ax.legend(loc="best", fontsize=9)
        ax.grid(True, alpha=0.3)
        self._format_date_axis(ax, ts.index)
        fig.tight_layout()

        path = self._chart_path("adoption_timeline")
        fig.savefig(path, dpi=150, bbox_inches="tight")
        plt.close(fig)
        return path

    def _plot_per_major(self, ts: Any, major: str) -> Optional[str]:
        """Plot adoption over time for minor/patch versions within a single major."""
        fig, ax = plt.subplots(figsize=(12, 6))
        for col in ts.columns:
            ax.plot(ts.index, ts[col].values, label=col, marker="o", markersize=4)

        name = MACOS_NAMES.get(major, f"macOS {major}")
        ax.set_title(f"{name} — Version Adoption Over Time", fontweight="bold")
        ax.set_xlabel("Date")
        ax.set_ylabel("Number of Devices")
        ncol = max(1, len(ts.columns) // 5)
        ax.legend(loc="best", fontsize=8, ncol=ncol)
        ax.grid(True, alpha=0.3)
        self._format_date_axis(ax, ts.index)
        fig.tight_layout()

        path = self._chart_path(f"adoption_major_{major}")
        fig.savefig(path, dpi=150, bbox_inches="tight")
        plt.close(fig)
        return path

    def _generate_compliance_trend(
        self,
        snapshots: list[tuple[datetime, Any]],
        fail_col: str,
        comp_cfg: dict,
    ) -> Optional[str]:
        """Generate a stacked area compliance trend chart. Returns PNG path or None."""
        bands = comp_cfg.get("bands") or DEFAULT_CONFIG["charts"]["compliance_trend"]["bands"]

        records = []
        for dt, df in snapshots:
            if fail_col not in df.columns:
                continue
            counts_by_band: dict[str, int] = {b["label"]: 0 for b in bands}
            for val in df[fail_col]:
                try:
                    n = int(str(val).strip())
                except (ValueError, TypeError):
                    continue
                for band in bands:
                    if band["min_failures"] <= n <= band["max_failures"]:
                        counts_by_band[band["label"]] += 1
                        break
            row: dict[str, Any] = {"date": dt}
            row.update(counts_by_band)
            records.append(row)

        if not records:
            print(f"  [skip] Compliance trend: column '{fail_col}' not found in snapshots")
            return None

        ts = pd.DataFrame(records).set_index("date").sort_index()
        band_labels = [b["label"] for b in bands]
        colors = [b["color"] for b in bands]

        fig, ax = plt.subplots(figsize=(12, 6))
        ax.stackplot(
            ts.index,
            [ts[lbl].values for lbl in band_labels],
            labels=band_labels,
            colors=colors,
            alpha=0.85,
        )
        baseline_label = _compliance_label(self._config.compliance)
        ax.set_title(f"{baseline_label} Trend Over Time", fontweight="bold")
        ax.set_xlabel("Date")
        ax.set_ylabel("Number of Devices")
        ax.legend(loc="upper left", fontsize=9)
        ax.grid(True, alpha=0.2)
        self._format_date_axis(ax, ts.index)
        fig.tight_layout()

        path = self._chart_path("compliance_trend")
        fig.savefig(path, dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"  [chart] {Path(path).name}")
        return path

    def _generate_device_state_trend(self) -> Optional[str]:
        """Generate a jamf-cli device state trend chart from device-compliance history."""
        snapshots = self._load_json_snapshots(["device-compliance", "device_compliance"])
        if not snapshots:
            print("  [skip] Device state trend: no jamf-cli device-compliance snapshots found")
            return None

        records = []
        for dt, data in snapshots:
            rows = data if isinstance(data, list) else []
            counts = {
                "Managed Current": 0,
                "Managed Stale": 0,
                "Unmanaged Current": 0,
                "Unmanaged Stale": 0,
            }
            for item in rows:
                if not isinstance(item, dict):
                    continue
                managed = _to_bool(item.get("managed"))
                stale = _to_bool(item.get("stale"))
                if managed and stale:
                    counts["Managed Stale"] += 1
                elif managed:
                    counts["Managed Current"] += 1
                elif stale:
                    counts["Unmanaged Stale"] += 1
                else:
                    counts["Unmanaged Current"] += 1
            if sum(counts.values()) > 0:
                row: dict[str, Any] = {"date": dt}
                row.update(counts)
                records.append(row)

        if not records:
            print("  [skip] Device state trend: device-compliance snapshots contained no rows")
            return None

        ts = pd.DataFrame(records).groupby("date", as_index=True).sum().sort_index()
        labels = ["Managed Current", "Managed Stale", "Unmanaged Current", "Unmanaged Stale"]
        colors = ["#2E86AB", "#F39C12", "#7FB069", "#C0392B"]

        fig, ax = plt.subplots(figsize=(12, 6))
        if len(ts.index) == 1:
            values = [int(ts.iloc[0][label]) for label in labels]
            ax.bar(labels, values, color=colors)
            plt.setp(ax.get_xticklabels(), rotation=20, ha="right")
            ax.set_xlabel("Device State")
        else:
            ax.stackplot(
                ts.index,
                [ts[label].values for label in labels],
                labels=labels,
                colors=colors,
                alpha=0.85,
            )
            ax.set_xlabel("Date")
            self._format_date_axis(ax, ts.index)

        ax.set_title("Device State Trend Over Time", fontweight="bold")
        ax.set_ylabel("Number of Devices")
        ax.legend(loc="upper left", fontsize=9)
        ax.grid(True, alpha=0.2)
        fig.tight_layout()

        path = self._chart_path("device_state_trend")
        fig.savefig(path, dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"  [chart] {Path(path).name}")
        return path

    def _format_date_axis(self, ax: Any, dates: Any) -> None:
        """Apply readable date formatting to a matplotlib x-axis."""
        span = (dates.max() - dates.min()).days if len(dates) > 1 else 0
        if span <= 14:
            ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m-%d"))
            ax.xaxis.set_major_locator(mdates.DayLocator(interval=1))
        elif span <= 90:
            ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m-%d"))
            ax.xaxis.set_major_locator(mdates.WeekdayLocator())
        else:
            ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))
            ax.xaxis.set_major_locator(mdates.MonthLocator())
        plt.setp(ax.xaxis.get_majorticklabels(), rotation=45, ha="right")

    def _embed_charts(self, png_paths: list[str]) -> None:
        """Create a Charts sheet in the workbook with all PNGs embedded."""
        ws = self._wb.add_worksheet("Charts")
        row = 0
        for path in png_paths:
            if not Path(path).is_file():
                continue
            ws.insert_image(row, 0, path, {"x_scale": 0.85, "y_scale": 0.85})
            row += 33  # roughly 495px at ~15px/row — enough vertical space per chart


# ---------------------------------------------------------------------------
# Device deep-dive command
# ---------------------------------------------------------------------------


def _print_device_detail(data: Any, indent: int = 0) -> None:
    """Recursively format and print a jamf-cli device JSON response.

    Args:
        data: Parsed JSON (dict, list, or scalar) from jamf-cli pro device.
        indent: Current indentation level (spaces multiplied by 2).
    """
    pad = "  " * indent
    if isinstance(data, list):
        for item in data:
            _print_device_detail(item, indent)
            if isinstance(item, dict):
                print()
    elif isinstance(data, dict):
        for key, value in data.items():
            label = str(key).replace("_", " ").title()
            if isinstance(value, dict):
                print(f"{pad}{label}:")
                _print_device_detail(value, indent + 1)
            elif isinstance(value, list):
                print(f"{pad}{label} ({len(value)}):")
                _print_device_detail(value, indent + 1)
            else:
                display = "" if value is None else str(value)
                print(f"{pad}  {label:<28} {display}")
    else:
        print(f"{pad}{data}")


def cmd_device(config: Config, device_id: str) -> None:
    """Print a formatted device detail view using jamf-cli pro device.

    Args:
        config: Loaded Config instance.
        device_id: Device identifier (Jamf Pro computer ID or serial number).
    """
    jamf_cli_cfg = config.jamf_cli
    jamf_cli_dir = config.resolve_path("jamf_cli", "data_dir", default="jamf-cli-data")
    jamf_cli_profile = str(jamf_cli_cfg.get("profile", "") or "").strip()
    bridge = JamfCLIBridge(
        save_output=False,
        data_dir=str(jamf_cli_dir or Path("jamf-cli-data")),
        profile=jamf_cli_profile,
        use_cached_data=False,
    )
    if not bridge.is_available():
        raise SystemExit(
            "Error: jamf-cli is not installed or not found.\n"
            "  Install via Homebrew: brew install jamf-cli\n"
            "  Or set JAMFCLI_PATH to the binary location."
        )
    print(f"Device: {device_id}")
    print("=" * (len(device_id) + 8))
    try:
        data = bridge.device_lookup(device_id)
    except RuntimeError as exc:
        raise SystemExit(f"Error: {exc}") from exc
    _print_device_detail(data)


# ---------------------------------------------------------------------------
# Scaffold command
# ---------------------------------------------------------------------------


_EA_SKIP_PATTERNS: frozenset[str] = frozenset({
    "udid", "managed", "supervised", "asset tag", "ip address", "mac address",
    "username", "real name", "email", "phone", "position", "department", "building",
    "room", "site", "notes", "comments", "po", "lease", "purchase", "vendor",
    "warranty", "model identifier", "processor", "ram", "storage", "battery",
    "serial", "jamf pro id", "management id",
})

_EA_TYPE_KEYWORDS: dict[str, list[str]] = {
    "version": ["version", "ver "],
    "date": ["date", "expir", "expires", "renewal"],
    "boolean": [
        "status", "enabled", "installed", "bound", "enrolled", "activation",
        "compliant", "connected", "running", "active", "detected",
    ],
}


def _suggest_ea_type(header: str) -> str:
    """Return a suggested custom_ea type based on column name heuristics."""
    lower = header.lower()
    for ea_type, keywords in _EA_TYPE_KEYWORDS.items():
        if any(kw in lower for kw in keywords):
            return ea_type
    return "text"


def _looks_like_ea(header: str) -> bool:
    """Return True when a column is likely a custom Extension Attribute, not core inventory."""
    lower = header.lower()
    # Skip generic Jamf inventory column patterns
    if any(pat in lower for pat in _EA_SKIP_PATTERNS):
        return False
    # Columns with org-specific separators (" - ", ": ") are almost always EAs
    if " - " in header or ": " in header:
        return True
    # Multi-word columns ending in EA-type keywords are strong candidates
    if " " in header.strip() and any(
        lower.endswith(kw.strip()) for keywords in _EA_TYPE_KEYWORDS.values()
        for kw in keywords
    ):
        return True
    return False


def _suggest_custom_ea_candidates(unmatched_headers: list[str]) -> None:
    """Print custom_eas config suggestions for unmatched columns that look like EAs.

    Args:
        unmatched_headers: CSV column names that were not mapped to logical fields.
    """
    candidates = [(h, _suggest_ea_type(h)) for h in unmatched_headers if _looks_like_ea(h)]
    if not candidates:
        return

    print(f"\nCustom EA suggestions ({len(candidates)} columns):")
    print("  Add these to the custom_eas list in your config.yaml:")
    for header, ea_type in candidates:
        snippet = (
            f"  - name: {header!r}\n"
            f"    column: {header!r}\n"
            f"    type: {ea_type}"
        )
        if ea_type == "boolean":
            snippet += "\n    true_value: \"<compliant value>\"  # e.g. Installed, Enabled, Yes"
        elif ea_type == "version":
            snippet += "\n    current_versions: []  # e.g. [\"130.0\", \"131.0\"]"
        elif ea_type == "date":
            snippet += "\n    warning_days: 90"
        print(snippet)
    print()


def _interactive_column_mapping(
    headers: list[str],
    matched: dict[str, str],
) -> dict[str, str]:
    """Walk the user through reviewing and correcting auto-matched column assignments.

    For each logical field, shows the auto-match (if any) alongside a numbered
    list of all available CSV columns so the user can accept, override, or skip.
    Falls back to returning the original matched dict when stdin is not a TTY.

    Args:
        headers: All column names from the CSV.
        matched: Auto-matched dict of logical_field -> csv_column (may be empty string).

    Returns:
        Updated mapping dict (logical -> csv_column or "").
    """
    if not sys.stdin.isatty():
        print("[interactive] stdin is not a terminal; using auto-matched results.")
        return matched

    logical_fields = list(DEFAULT_CONFIG["columns"].keys())
    result = dict(matched)

    print("\nInteractive column mapping")
    print("  Enter  — accept the auto-match (or skip if none)")
    print("  number — choose that column from the list")
    print("  s / 0  — leave this field blank\n")

    for idx, logical in enumerate(logical_fields, 1):
        auto = result.get(logical, "")
        # Available = all headers not already claimed by another field
        others_used = {v for k, v in result.items() if k != logical and v}
        available = [h for h in headers if h not in others_used]

        hints = ", ".join(COLUMN_HINTS.get(logical, []))
        print(f"[{idx}/{len(logical_fields)}] {logical}  (hints: {hints})")

        if auto:
            print(f"  Auto-match: {auto!r}  (press Enter to accept)")
        else:
            print("  No auto-match found")

        print("  0: <skip — leave blank>")
        for i, h in enumerate(available, 1):
            marker = "  <- auto-match" if h == auto else ""
            print(f"  {i}: {h}{marker}")

        prompt = f"  Choice [Enter={auto!r}]: " if auto else "  Choice [Enter=skip]: "
        while True:
            try:
                raw = input(prompt).strip()
            except (EOFError, KeyboardInterrupt):
                print("\nInteractive mapping aborted. Using current results.")
                return result

            if raw == "":
                break  # accept auto or skip
            if raw.lower() == "s" or raw == "0":
                result[logical] = ""
                break
            try:
                choice = int(raw)
                if 1 <= choice <= len(available):
                    result[logical] = available[choice - 1]
                    break
                print(f"  Please enter a number between 0 and {len(available)}.")
            except ValueError:
                print("  Invalid input — enter a number, 's' to skip, or Enter to accept.")

        print()

    return result


def cmd_scaffold(csv_path: str, out_path: str, interactive: bool = False) -> None:
    """Auto-generate a starter config.yaml from CSV headers.

    Args:
        csv_path: Path to the CSV file to inspect.
        out_path: Output path for generated config.yaml.
        interactive: If True, prompt the user to review each column mapping before writing.
    """
    csv_path_obj = _cli_path(csv_path)
    out_path_obj = _cli_path(out_path)
    if csv_path_obj is None or out_path_obj is None:
        raise SystemExit("Error: scaffold requires valid --csv and --out paths")

    try:
        df = pd.read_csv(csv_path_obj, nrows=0, encoding="utf-8-sig")
    except Exception as exc:
        raise SystemExit(f"Error: could not read CSV '{csv_path_obj}': {exc}") from exc
    headers = list(df.columns)
    print(f"Found {len(headers)} columns in CSV.")

    matched: dict[str, str] = {}
    used_headers: set[str] = set()
    for logical in DEFAULT_CONFIG["columns"]:
        best_header, best_score = _best_header_match(headers, logical, used_headers)
        if best_header and best_score > 0:
            matched[logical] = best_header
            used_headers.add(best_header)

    unmatched = [header for header in headers if header not in used_headers]

    print(f"Auto-matched {len(matched)} logical fields:")
    for k, v in matched.items():
        print(f"  {k}: {v!r}")
    if unmatched:
        print(f"Unmatched columns ({len(unmatched)}) — add manually to config if needed:")
        for h in unmatched:
            print(f"  - {h!r}")

    _suggest_custom_ea_candidates(unmatched)

    if interactive:
        matched = _interactive_column_mapping(headers, matched)

    config_data = copy.deepcopy(DEFAULT_CONFIG)
    for logical in config_data["columns"]:
        config_data["columns"][logical] = matched.get(logical, "")

    config_str = yaml.dump(config_data, default_flow_style=False, sort_keys=False)
    with open(out_path_obj, "w") as fh:
        fh.write("# Generated by jamf-reports-community.py scaffold\n")
        fh.write("# Review and adjust column mappings before running generate.\n\n")
        fh.write(config_str)
    print(f"\nConfig written to: {out_path_obj}")


# ---------------------------------------------------------------------------
# Check command
# ---------------------------------------------------------------------------

_VALID_EA_TYPES: frozenset[str] = frozenset({"boolean", "percentage", "version", "text", "date"})


def _validate_config_structure(config: Config) -> None:
    """Validate config keys for type correctness and internal consistency.

    Prints [ok] or [WARN] lines for each check. Does not raise — all issues
    are advisory so the user can fix them before running generate.

    Args:
        config: Loaded Config instance to validate.
    """
    issues: list[str] = []

    # Numeric threshold validation
    for key, label in [
        ("stale_device_days", "thresholds.stale_device_days"),
        ("critical_disk_percent", "thresholds.critical_disk_percent"),
        ("warning_disk_percent", "thresholds.warning_disk_percent"),
        ("cert_warning_days", "thresholds.cert_warning_days"),
    ]:
        val = config.thresholds.get(key)
        if val is not None:
            try:
                float(val)
            except (TypeError, ValueError):
                issues.append(f"{label} = {val!r} — must be a number, not {type(val).__name__}")

    # Compliance: if enabled, both columns must be set
    comp = config.compliance
    if comp.get("enabled"):
        for col_key in ("failures_count_column", "failures_list_column"):
            if not comp.get(col_key, ""):
                issues.append(
                    f"compliance.{col_key} is empty but compliance.enabled is true —"
                    " the Compliance sheet will fail at generate time"
                )

    # Custom EA type validation
    for ea in config.custom_eas:
        name = ea.get("name", "?")
        ea_type = ea.get("type", "")
        if ea_type not in _VALID_EA_TYPES:
            issues.append(
                f"custom_ea '{name}': type={ea_type!r} is not valid."
                f" Use one of: {', '.join(sorted(_VALID_EA_TYPES))}"
            )
        if ea_type == "boolean" and not ea.get("true_value", ""):
            issues.append(
                f"custom_ea '{name}': boolean EA has no true_value set."
                " Defaulting to 'Yes' — set true_value to the expected compliant value."
            )
        for num_key in ("warning_threshold", "critical_threshold", "warning_days"):
            val = ea.get(num_key)
            if val is not None:
                try:
                    float(str(val).rstrip("%"))
                except (TypeError, ValueError):
                    issues.append(
                        f"custom_ea '{name}': {num_key}={val!r} — must be numeric"
                    )

    # Charts: warn if enabled but matplotlib unavailable
    charts_enabled = config.get("charts", "enabled")
    if charts_enabled is None or charts_enabled:
        if not _load_matplotlib():
            issues.append(
                "charts.enabled is true but matplotlib is not installed."
                " Run: pip install matplotlib"
            )

    if issues:
        for issue in issues:
            print(f"  [WARN] {issue}")
    else:
        print("  [ok] config structure looks valid")


def cmd_check(config: Config, csv_path: Optional[str] = None) -> None:
    """Verify jamf-cli auth and config validity.

    When csv_path is provided, cross-references all configured column names
    against the actual CSV headers and reports any mismatches.

    Args:
        config: Loaded Config instance.
        csv_path: Optional path to CSV export for column validation.
    """
    print("--- Configuration check ---")
    print(f"  config base dir: {config.base_dir}")
    required = ["computer_name", "serial_number", "operating_system", "last_checkin"]
    any_configured = False
    for field in required:
        val = config.columns.get(field, "")
        status = "ok" if val else "not configured"
        print(f"  columns.{field}: {status}" + (f" -> {val!r}" if val else ""))
        if val:
            any_configured = True
    if not any_configured:
        print("  Note: No columns configured. Run scaffold or edit config.yaml to add mappings.")

    if csv_path:
        print("\n--- CSV column validation ---")
        csv_path_obj = _resolve_cli_input_path(csv_path, config)
        try:
            if csv_path_obj is None:
                raise FileNotFoundError("missing CSV path")
            df = pd.read_csv(csv_path_obj, dtype=str, encoding="utf-8-sig").fillna("")
            headers = df.columns.tolist()
            csv_cols = set(headers)
        except Exception as exc:
            checked = _describe_cli_input_candidates(csv_path, config)
            print(f"  Could not read CSV {csv_path!r}: {exc}")
            if checked:
                print(f"  Checked: {checked}")
        else:
            mismatches = []
            for field, col in config.columns.items():
                if not col:
                    continue
                if col in csv_cols:
                    print(f"  [ok] {field}: {col!r}")
                    suggested_col, suggested_score = _best_header_match(headers, field)
                    configured_score = _column_match_score(col, field)
                    if (
                        suggested_col
                        and suggested_col != col
                        and suggested_score > configured_score
                    ):
                        print(
                            f"  [SUGGEST] {field}: {suggested_col!r} looks like a"
                            f" better match than {col!r}"
                        )
                else:
                    print(f"  [MISSING] {field}: {col!r} — not found in CSV")
                    mismatches.append((field, col))
            for ea in config.custom_eas:
                col = ea.get("column", "")
                name = ea.get("name", "?")
                if not col:
                    continue
                if col in csv_cols:
                    print(f"  [ok] custom_ea '{name}': {col!r}")
                else:
                    print(f"  [MISSING] custom_ea '{name}': {col!r} — not found in CSV")
                    mismatches.append((f"custom_ea:{name}", col))
            if mismatches:
                print(
                    f"\n  {len(mismatches)} column(s) not found."
                    " Fix config.yaml or re-run scaffold."
                )
            else:
                print("\n  All configured columns found in CSV.")

            warnings = _semantic_warnings(config, df.head(50))
            if warnings:
                print("\n--- Semantic validation ---")
                for warning in warnings:
                    print(f"  [WARN] {warning}")

    print("\n--- Config validation ---")
    _validate_config_structure(config)

    print("\n--- jamf-cli check ---")
    jamf_cli_cfg = config.jamf_cli
    jamf_cli_dir = config.resolve_path("jamf_cli", "data_dir", default="jamf-cli-data")
    jamf_cli_profile = str(jamf_cli_cfg.get("profile", "") or "").strip()
    live_overview_allowed = jamf_cli_cfg.get("allow_live_overview", True) is True
    bridge = JamfCLIBridge(
        save_output=False,
        data_dir=str(jamf_cli_dir or Path("jamf-cli-data")),
        profile=jamf_cli_profile,
        use_cached_data=jamf_cli_cfg.get("use_cached_data", True) is not False,
    )
    print(f"  data dir: {bridge._data_dir}")
    if jamf_cli_profile:
        print(f"  profile: {jamf_cli_profile}")
    if live_overview_allowed:
        print("  live overview: enabled")
    else:
        print("  live overview: disabled (cached overview only)")
    if bridge.is_available():
        print(f"  jamf-cli: found -> {bridge._binary}")
        report_commands = bridge._report_commands()
        if report_commands:
            current_core = {
                "security",
                "patch-status",
                "inventory-summary",
                "device-compliance",
                "ea-results",
                "software-installs",
            }
            future_optional = {"policy-status", "profile-status"}
            missing_current = sorted(current_core - report_commands)
            missing_optional = sorted(future_optional - report_commands)
            print(f"  supported report commands: {', '.join(sorted(report_commands))}")
            if missing_current:
                print(f"  missing current core commands: {', '.join(missing_current)}")
            if missing_optional:
                print(f"  missing optional commands: {', '.join(missing_optional)}")
        try:
            live_bridge = JamfCLIBridge(
                save_output=False,
                data_dir=str(jamf_cli_dir or Path("jamf-cli-data")),
                profile=jamf_cli_profile,
                use_cached_data=False,
            )
            probe_candidates: list[tuple[str, Any]] = []
            if not report_commands or "inventory-summary" in report_commands:
                probe_candidates.append(("inventory-summary", live_bridge.inventory_summary))
            if not report_commands or "security" in report_commands:
                probe_candidates.append(("security", live_bridge.security_report))
            if not report_commands or "patch-status" in report_commands:
                probe_candidates.append(("patch-status", live_bridge.patch_status))
            if live_overview_allowed:
                probe_candidates.append(("overview", live_bridge.overview))

            last_exc: Optional[RuntimeError] = None
            auth_ok = False
            for label, probe in probe_candidates:
                try:
                    probe()
                    print(f"  auth: ok ({label})")
                    auth_ok = True
                    break
                except RuntimeError as exc:
                    last_exc = exc

            if not auth_ok:
                if last_exc is not None:
                    print(f"  auth: failed — {last_exc}")
                else:
                    print("  auth: skipped — no safe jamf-cli report probe was available")
        except RuntimeError as exc:
            print(f"  auth: failed — {exc}")
        if bridge.has_cached_data():
            print("  cached snapshots: found")
    else:
        print("  jamf-cli: not found (set JAMFCLI_PATH or install via Homebrew)")
        if bridge.has_cached_data():
            print("  cached snapshots: found")
            print("  Note: core sheets can still render from cached jamf-cli JSON snapshots.")
        else:
            print("  Note: CSV-only reports will still work without jamf-cli.")


# ---------------------------------------------------------------------------
# Generate command
# ---------------------------------------------------------------------------


def _post_teams_notification(
    webhook_url: str,
    report_path: Path,
    sheets_written: int,
    generated_at: str,
) -> None:
    """Post an Adaptive Card summary to a Microsoft Teams incoming webhook.

    Args:
        webhook_url: Teams incoming webhook URL (from --notify or config).
        report_path: Path to the generated xlsx file.
        sheets_written: Total number of sheets written to the workbook.
        generated_at: Human-readable generation timestamp string.
    """
    payload = {
        "type": "message",
        "attachments": [
            {
                "contentType": "application/vnd.microsoft.card.adaptive",
                "contentUrl": None,
                "content": {
                    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "type": "AdaptiveCard",
                    "version": "1.4",
                    "body": [
                        {
                            "type": "TextBlock",
                            "size": "Large",
                            "weight": "Bolder",
                            "text": "Jamf Report Generated",
                        },
                        {
                            "type": "FactSet",
                            "facts": [
                                {"title": "File", "value": report_path.name},
                                {"title": "Sheets", "value": str(sheets_written)},
                                {"title": "Generated", "value": generated_at},
                            ],
                        },
                    ],
                },
            }
        ],
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status not in (200, 202):
                print(f"  [warn] Teams webhook returned HTTP {resp.status}; notification may not appear.")
    except urllib.error.URLError as exc:
        print(f"  [warn] Teams webhook notification failed: {exc}")


def cmd_generate(
    config: Config,
    csv_path: Optional[str],
    out_file: Optional[str],
    historical_csv_dir: Optional[str] = None,
    notify_url: Optional[str] = None,
    csv_extra: Optional[list[str]] = None,
) -> None:
    """Run all report generation and write the Excel file.

    Args:
        config: Loaded Config instance.
        csv_path: Optional path to CSV inventory export.
        out_file: Optional output file path override.
        historical_csv_dir: Optional directory of dated CSV snapshots for trend charts.
        notify_url: Optional Teams incoming webhook URL for post-generation notification.
        csv_extra: Optional list of additional CSV paths to merge with csv_path.
    """
    csv_path_obj = _resolve_cli_input_path(csv_path, config)
    csv_path_str = str(csv_path_obj) if csv_path_obj else None

    output_cfg = config.output
    out_dir = config.resolve_path("output", "output_dir", default="Generated Reports")
    if out_dir is None:
        out_dir = Path("Generated Reports")
    out_dir.mkdir(parents=True, exist_ok=True)
    timestamp_outputs = output_cfg.get("timestamp_outputs", True) is not False
    archive_enabled = output_cfg.get("archive_enabled", True) is not False
    keep_latest_runs = _to_int(output_cfg.get("keep_latest_runs", 10), 10)
    run_stamp = _file_stamp()

    jamf_cli_cfg = config.jamf_cli
    jamf_cli_dir = config.resolve_path("jamf_cli", "data_dir", default="jamf-cli-data")
    jamf_cli_profile = str(jamf_cli_cfg.get("profile", "") or "").strip()
    live_overview_allowed = jamf_cli_cfg.get("allow_live_overview", True) is True
    bridge = JamfCLIBridge(
        save_output=True,
        data_dir=str(jamf_cli_dir or Path("jamf-cli-data")),
        profile=jamf_cli_profile,
        use_cached_data=jamf_cli_cfg.get("use_cached_data", True) is not False,
    )
    jamf_cli_ready = bridge.is_available() or bridge.has_cached_data()

    if out_file:
        out_path = _timestamped_output_path(
            Path(out_file).expanduser(), run_stamp, timestamp_outputs
        )
    else:
        if csv_path_str and jamf_cli_ready:
            default_name = "jamf_report_csv_plus_jamf_cli.xlsx"
        elif csv_path_str:
            default_name = "jamf_report_csv_only.xlsx"
        else:
            default_name = "jamf_report_jamf_cli_only.xlsx"
        out_path = _timestamped_output_path(out_dir / default_name, run_stamp, True)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Output: {out_path}")
    print(f"  config base dir: {config.base_dir}")
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M")
    wb = xlsxwriter.Workbook(str(out_path))
    fmts = _build_formats(wb)
    sheets_written = 0
    jamf_cli_written: list[str] = []
    csv_written: list[str] = []
    chart_source = ""
    print(f"  jamf-cli data dir: {bridge._data_dir}")
    if jamf_cli_profile:
        print(f"  jamf-cli profile: {jamf_cli_profile}")
    if not live_overview_allowed:
        print("  live overview disabled; Fleet Overview will use cache only.")
    try:
        if bridge.is_available() or bridge.has_cached_data():
            print("\nGenerating jamf-cli sheets...")
            core = CoreDashboard(config, bridge, wb, fmts)
            jamf_cli_written = core.write_all()
            sheets_written += len(jamf_cli_written)
        else:
            print("\nWarning: jamf-cli not available — skipping core dashboard sheets.")
            print(
                "  Set JAMFCLI_PATH, authenticate jamf-cli, or populate cached"
                " jamf-cli JSON snapshots."
            )

        if csv_path_str:
            print("\nGenerating CSV sheets...")
            try:
                csv_dash = CSVDashboard(config, csv_path_str, wb, fmts, extra_csv_paths=csv_extra)
            except (pd.errors.ParserError, UnicodeDecodeError, OSError) as exc:
                print(f"  [error] Cannot read CSV: {exc}")
                print("  Skipping CSV sheets. Verify the file is a valid UTF-8 CSV export.")
            else:
                csv_written = csv_dash.write_all()
                sheets_written += len(csv_written)
        else:
            print("\nNo CSV provided — skipping inventory sheets.")
            print("  Pass --csv path/to/export.csv to enable inventory analysis.")

        hist_dir_obj = _cli_path(historical_csv_dir)
        if hist_dir_obj is None:
            hist_dir_obj = config.resolve_path("charts", "historical_csv_dir")
        hist_dir = str(hist_dir_obj) if hist_dir_obj else None
        if hist_dir_obj:
            print(f"  historical CSV dir: {hist_dir_obj}")
        if csv_path_str and hist_dir and config.get("charts", "archive_current_csv") is not False:
            try:
                archived_path = _archive_csv_snapshot(csv_path_str, hist_dir)
                if archived_path:
                    print(f"  Archived CSV snapshot: {archived_path}")
            except OSError as exc:
                print(f"  [warn] Could not archive CSV snapshot: {exc}")

        charts_enabled = config.get("charts", "enabled")
        if charts_enabled is None or charts_enabled:
            print("\nGenerating charts...")
            chart_gen = ChartGenerator(
                config,
                csv_path_str,
                hist_dir,
                out_path.parent,
                wb,
                jamf_cli_dir,
                out_path.stem,
            )
            png_paths, chart_sources = chart_gen.generate_all()
            if chart_sources:
                chart_source = " + ".join(chart_sources)
            if png_paths and config.get("charts", "save_png") is not False:
                print(f"  {len(png_paths)} PNG(s) saved to {out_path.parent}/")

        if sheets_written == 0:
            raise SystemExit(
                "Error: No data sources available. Run 'jamf-cli pro setup' or"
                " provide --csv path/to/export.csv"
            )

        _write_report_sources_sheet(
            wb,
            fmts,
            generated_at,
            config,
            csv_path_str,
            hist_dir,
            str(bridge._data_dir),
            jamf_cli_profile,
            live_overview_allowed,
            jamf_cli_written,
            csv_written,
            chart_source,
        )

        wb.close()
    except SystemExit:
        wb.close()
        out_path.unlink(missing_ok=True)
        raise
    except Exception:
        try:
            wb.close()
        except Exception:
            pass
        out_path.unlink(missing_ok=True)
        raise
    if archive_enabled:
        archive_dir = config.resolve_path("output", "archive_dir")
        if archive_dir is None:
            archive_dir = out_path.parent / "archive"
        family_base = _strip_timestamp_suffix(out_path.stem)
        archived_paths = _archive_old_output_runs(
            out_path.parent,
            family_base,
            {".xlsx", ".png"},
            keep_latest_runs,
            archive_dir,
        )
        if archived_paths:
            print(f"  Archived {len(archived_paths)} older output file(s) to {archive_dir}")
    print(f"\nReport written: {out_path}")
    if notify_url:
        print("  Sending Teams notification...")
        _post_teams_notification(notify_url, out_path, sheets_written, generated_at)

    if config.output.get("export_pptx") is True:
        exporter = ReportExporter(
            out_path.parent,
            out_path.stem,
            generated_at,
            jamf_cli_written,
            csv_written,
        )
        pptx_path = exporter.export_pptx()
        if pptx_path:
            print(f"  PPTX export: {pptx_path}")


# ---------------------------------------------------------------------------
# PPTX report exporter
# ---------------------------------------------------------------------------


class ReportExporter:
    """Generates a PPTX executive-summary deck alongside the xlsx report.

    The deck is intentionally minimal — title slide, sheet inventory, and data
    source summary.  It is designed to be opened in PowerPoint or Keynote as a
    starting point for presenting fleet data rather than as a complete document.

    Requires ``python-pptx`` (``pip install python-pptx``).  If the library is
    not installed the export is skipped with a warning.

    Args:
        output_dir: Directory where the xlsx was written.
        report_stem: Base filename (without extension) of the xlsx output.
        generated_at: Human-readable generation timestamp string.
        jamf_cli_sheets: Sheet names generated from jamf-cli data.
        csv_sheets: Sheet names generated from CSV data.
    """

    _TITLE_ACCENT = "#2D5EA2"      # blue matching the workbook header colour

    def __init__(
        self,
        output_dir: Path,
        report_stem: str,
        generated_at: str,
        jamf_cli_sheets: list[str],
        csv_sheets: list[str],
    ) -> None:
        self._output_dir = output_dir
        self._report_stem = report_stem
        self._generated_at = generated_at
        self._jamf_cli_sheets = jamf_cli_sheets
        self._csv_sheets = csv_sheets

    def export_pptx(self) -> Optional[Path]:
        """Generate the PPTX summary file.

        Returns:
            Path to the ``.pptx`` file on success, or ``None`` if python-pptx
            is unavailable or an error occurs during generation.
        """
        if not _load_pptx():
            print("  [skip] PPTX export: python-pptx not installed (pip install python-pptx)")
            return None

        try:
            return self._build_pptx()
        except Exception as exc:
            print(f"  [warn] PPTX export failed: {exc}")
            return None

    def _build_pptx(self) -> Path:
        """Build and save the PPTX deck, returning the output path."""
        prs = pptx_Presentation()
        prs.slide_width = pptx_Inches(13.33)
        prs.slide_height = pptx_Inches(7.5)

        self._add_title_slide(prs)
        self._add_summary_slide(prs)
        if self._jamf_cli_sheets or self._csv_sheets:
            self._add_sheets_slide(prs)

        out_path = self._output_dir / f"{self._report_stem}.pptx"
        prs.save(str(out_path))
        return out_path

    def _add_title_slide(self, prs: Any) -> None:
        """Add the opening title slide."""
        layout = prs.slide_layouts[0]   # Title Slide layout
        slide = prs.slides.add_slide(layout)
        slide.shapes.title.text = "Jamf Pro Fleet Report"
        if len(slide.placeholders) > 1:
            slide.placeholders[1].text = self._generated_at

    def _add_summary_slide(self, prs: Any) -> None:
        """Add a slide summarising what data sources were included."""
        layout = prs.slide_layouts[1]   # Title and Content layout
        slide = prs.slides.add_slide(layout)
        slide.shapes.title.text = "Report Summary"
        tf = slide.placeholders[1].text_frame
        tf.clear()

        total = len(self._jamf_cli_sheets) + len(self._csv_sheets)
        tf.paragraphs[0].text = f"Sheets generated: {total}"

        sources: list[str] = []
        if self._jamf_cli_sheets:
            sources.append("jamf-cli (live or cached snapshots)")
        if self._csv_sheets:
            sources.append("Jamf Pro CSV export")

        for source in sources:
            p = tf.add_paragraph()
            p.text = f"Data source: {source}"
            p.level = 1

        p = tf.add_paragraph()
        p.text = f"Generated: {self._generated_at}"
        p.level = 1

    def _add_sheets_slide(self, prs: Any) -> None:
        """Add a slide listing every sheet written to the workbook."""
        layout = prs.slide_layouts[1]
        slide = prs.slides.add_slide(layout)
        slide.shapes.title.text = "Included Sheets"
        tf = slide.placeholders[1].text_frame
        tf.clear()

        all_sheets = self._jamf_cli_sheets + self._csv_sheets
        tf.paragraphs[0].text = "jamf-cli sheets:" if self._jamf_cli_sheets else "Sheets:"
        for name in all_sheets:
            p = tf.add_paragraph()
            marker = "  •  " + name
            if name in self._csv_sheets and self._jamf_cli_sheets:
                marker = "  ○  " + name   # different bullet for CSV sheets
            p.text = marker
            p.level = 1


def cmd_collect(
    config: Config,
    csv_path: Optional[str] = None,
    historical_csv_dir: Optional[str] = None,
) -> None:
    """Collect live jamf-cli snapshots and optionally archive a CSV snapshot."""
    print("--- Collect snapshots ---")
    print(f"  config base dir: {config.base_dir}")

    collected = 0
    jamf_cli_dir = config.resolve_path("jamf_cli", "data_dir", default="jamf-cli-data")
    jamf_cli_profile = str(config.jamf_cli.get("profile", "") or "").strip()
    live_overview_allowed = config.jamf_cli.get("allow_live_overview", True) is True
    bridge = JamfCLIBridge(
        save_output=True,
        data_dir=str(jamf_cli_dir or Path("jamf-cli-data")),
        profile=jamf_cli_profile,
        use_cached_data=False,
    )
    print(f"  jamf-cli data dir: {bridge._data_dir}")
    if jamf_cli_profile:
        print(f"  jamf-cli profile: {jamf_cli_profile}")
    if bridge.is_available():
        stale_days = int(config.thresholds.get("stale_device_days", 30))
        commands = []
        if live_overview_allowed:
            commands.append(("Fleet Overview", bridge.overview))
        else:
            print("  [skip] Fleet Overview: live overview disabled in config")
        commands.extend(
            [
                ("Inventory Summary", bridge.inventory_summary),
                ("Security Posture", bridge.security_report),
                ("Device Compliance", lambda: bridge.device_compliance(stale_days)),
                ("EA Coverage", lambda: bridge.ea_results_report(include_all=True)),
                ("EA Definitions", bridge.computer_extension_attributes),
                ("Software Installs", bridge.software_installs),
                ("Patch Compliance", bridge.patch_status),
                ("Patch Failures", bridge.patch_device_failures),
                ("Policy Health", bridge.policy_status),
                ("Profile Status", bridge.profile_status),
            ]
        )
        for label, command in commands:
            try:
                command()
                collected += 1
                print(f"  [ok] {label}")
            except RuntimeError as exc:
                print(f"  [skip] {label}: {exc}")
    else:
        print("  jamf-cli: not found; skipping live snapshot collection.")

    archived = False
    csv_path_obj = _resolve_cli_input_path(csv_path, config)
    hist_dir_obj = _cli_path(historical_csv_dir)
    if hist_dir_obj is None:
        hist_dir_obj = config.resolve_path("charts", "historical_csv_dir")
    if hist_dir_obj:
        print(f"  historical CSV dir: {hist_dir_obj}")
    if (
        csv_path_obj
        and hist_dir_obj
        and config.get("charts", "archive_current_csv") is not False
    ):
        archived_path = _archive_csv_snapshot(str(csv_path_obj), str(hist_dir_obj))
        if archived_path:
            archived = True
            print(f"  [ok] Archived CSV snapshot: {archived_path}")

    if collected == 0 and not archived:
        raise SystemExit(
            "Error: No snapshots collected. Authenticate jamf-cli for live data or"
            " pass --csv plus --historical-csv-dir to archive a CSV snapshot."
        )


def cmd_inventory_csv(config: Config, out_file: Optional[str]) -> None:
    """Export a wide computer inventory CSV from jamf-cli inventory and EA data."""
    output_cfg = config.output
    out_dir = config.resolve_path("output", "output_dir", default="Generated Reports")
    if out_dir is None:
        out_dir = Path("Generated Reports")
    out_dir.mkdir(parents=True, exist_ok=True)
    timestamp_outputs = output_cfg.get("timestamp_outputs", True) is not False
    archive_enabled = output_cfg.get("archive_enabled", True) is not False
    keep_latest_runs = _to_int(output_cfg.get("keep_latest_runs", 10), 10)

    jamf_cli_dir = config.resolve_path("jamf_cli", "data_dir", default="jamf-cli-data")
    jamf_cli_profile = str(config.jamf_cli.get("profile", "") or "").strip()
    run_stamp = _file_stamp()
    if out_file:
        out_path = _timestamped_output_path(
            Path(out_file).expanduser(), run_stamp, timestamp_outputs
        )
    else:
        profile_component = _filename_component(jamf_cli_profile) if jamf_cli_profile else ""
        if profile_component:
            base_name = f"jamf_inventory_{profile_component}.csv"
        else:
            base_name = "jamf_inventory.csv"
        out_path = _timestamped_output_path(out_dir / base_name, run_stamp, True)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Output: {out_path}")
    print(f"  config base dir: {config.base_dir}")

    bridge = JamfCLIBridge(
        save_output=False,
        data_dir=str(jamf_cli_dir or Path("jamf-cli-data")),
        profile=jamf_cli_profile,
        use_cached_data=False,
    )
    if not bridge.is_available():
        raise SystemExit("Error: jamf-cli not found. Install it or set JAMFCLI_PATH.")

    computers_raw = bridge.computers_list()
    computers = computers_raw if isinstance(computers_raw, list) else []
    if not computers:
        raise SystemExit("Error: jamf-cli returned no computers.")

    duplicate_names: set[str] = set()
    counts_by_name: dict[str, int] = {}
    base_rows: list[dict[str, Any]] = []
    for item in computers:
        if not isinstance(item, dict):
            continue
        row = _inventory_export_row(item)
        name = row["Computer Name"]
        counts_by_name[name] = counts_by_name.get(name, 0) + 1
        if counts_by_name[name] > 1:
            duplicate_names.add(name)
        base_rows.append(row)

    if duplicate_names:
        names_preview = ", ".join(sorted(duplicate_names)[:5])
        raise SystemExit(
            "Error: duplicate computer names prevent a reliable EA join via"
            f" jamf-cli ea-results: {names_preview}"
        )

    rows_by_name = {row["Computer Name"]: row for row in base_rows}
    detail_enriched, detail_failures = _enrich_inventory_rows_with_security_details(
        bridge,
        computers,
        rows_by_name,
    )
    ea_columns: set[str] = set()
    unmatched_devices: set[str] = set()
    ea_raw = bridge.ea_results(include_all=True)
    ea_rows = ea_raw if isinstance(ea_raw, list) else []
    for item in ea_rows:
        if not isinstance(item, dict):
            continue
        device = str(item.get("device", "") or "").strip()
        ea_name = str(item.get("ea_name", "") or "").strip()
        if not device or not ea_name:
            continue
        if device not in rows_by_name:
            unmatched_devices.add(device)
            continue
        rows_by_name[device][ea_name] = str(item.get("value", "") or "").strip()
        ea_columns.add(ea_name)

    ordered_columns = INVENTORY_EXPORT_COLUMNS + sorted(
        column for column in ea_columns if column not in INVENTORY_EXPORT_COLUMNS
    )
    export_rows = [rows_by_name[row["Computer Name"]] for row in base_rows]
    df = pd.DataFrame(export_rows, columns=ordered_columns).fillna("")
    df.to_csv(out_path, index=False, encoding="utf-8-sig")

    print(f"  [ok] Exported {len(df)} computers")
    print(
        "  [ok] Added"
        f" {len(INVENTORY_SECURITY_DETAIL_COLUMNS)} generic security detail column(s)"
    )
    if detail_enriched:
        print(f"  [ok] Enriched security details for {detail_enriched} computer(s)")
    if detail_failures:
        print(
            "  [warn] Could not enrich device security details for"
            f" {detail_failures} computer(s)"
        )
    print(f"  [ok] Included {len(ea_columns)} extension attribute columns")
    if unmatched_devices:
        print(
            "  [warn] Ignored EA rows for devices not present in computers list:"
            f" {len(unmatched_devices)}"
        )
    print(
        "  Note: this export is built from jamf-cli computers list plus"
        " per-device security details and jamf-cli report ea-results."
    )
    if archive_enabled:
        archive_dir = config.resolve_path("output", "archive_dir")
        if archive_dir is None:
            archive_dir = out_path.parent / "archive"
        family_base = _strip_timestamp_suffix(out_path.stem)
        archived_paths = _archive_old_output_runs(
            out_path.parent,
            family_base,
            {".csv"},
            keep_latest_runs,
            archive_dir,
        )
        if archived_paths:
            print(f"  Archived {len(archived_paths)} older inventory export(s) to {archive_dir}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    """Parse arguments and dispatch to the appropriate command."""
    parser = argparse.ArgumentParser(
        description="Community Jamf Pro reporting tool.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Commands:\n"
            "  generate      Build the Excel report\n"
            "  collect       Save jamf-cli snapshots and optional CSV history\n"
            "  inventory-csv Export a wide CSV from jamf-cli inventory plus EAs\n"
            "  scaffold      Generate a starter config.yaml from a CSV\n"
            "  check         Verify jamf-cli auth and config\n"
            "  device        Print a device detail view from jamf-cli pro device\n"
        ),
    )
    parser.add_argument(
        "command",
        choices=["generate", "collect", "inventory-csv", "scaffold", "check", "device"],
    )
    parser.add_argument("--config", default="config.yaml", help="Path to config.yaml")
    parser.add_argument("--csv", help="Path to Jamf Pro CSV export")
    parser.add_argument("--out-file", help="Output file path (generate or inventory-csv)")
    parser.add_argument("--out", default="config.yaml", help="Output config path (scaffold only)")
    parser.add_argument(
        "--historical-csv-dir",
        help="Directory of dated CSV snapshots for trend charts or collection",
    )
    parser.add_argument(
        "--notify",
        metavar="WEBHOOK_URL",
        help="Microsoft Teams incoming webhook URL; posts an Adaptive Card after generate",
    )
    parser.add_argument(
        "--interactive", "-i",
        action="store_true",
        help="Walk through each column mapping interactively after auto-matching (scaffold only)",
    )
    parser.add_argument(
        "--id",
        metavar="DEVICE_ID",
        help="Jamf Pro computer ID or serial number to look up (device command only)",
    )
    parser.add_argument(
        "--csv-extra",
        action="append",
        metavar="CSV_PATH",
        dest="csv_extra",
        help=(
            "Additional CSV export to merge with --csv (can be repeated). "
            "Useful for combining computers, mobile-device, and users exports. "
            "A 'CSV Source' column is added to identify which file each row came from."
        ),
    )
    args = parser.parse_args()

    if args.command == "scaffold":
        if not args.csv:
            parser.error("scaffold requires --csv")
        cmd_scaffold(args.csv, args.out, interactive=args.interactive)
        return

    if args.command == "device":
        if not args.id:
            parser.error("device requires --id")
        config = Config(args.config)
        cmd_device(config, args.id)
        return

    config = Config(args.config)

    if args.command == "check":
        cmd_check(config, args.csv)
    elif args.command == "collect":
        cmd_collect(config, args.csv, args.historical_csv_dir)
    elif args.command == "inventory-csv":
        cmd_inventory_csv(config, args.out_file)
    elif args.command == "generate":
        cmd_generate(
            config, args.csv, args.out_file, args.historical_csv_dir,
            args.notify, args.csv_extra,
        )


if __name__ == "__main__":
    main()
