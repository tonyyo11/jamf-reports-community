#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON_BIN="${PYTHON:-python3}"
PYTHON_BIN="$(command -v "$PYTHON_BIN" 2>/dev/null || true)"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if [[ -z "$PYTHON_BIN" ]]; then
    echo "Unable to resolve Python interpreter." >&2
    exit 1
fi

MODE="${1:-all}"
OUT_DIR="${2:-$REPO_DIR/Generated Reports/demo}"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/demo.sh [all|html|xlsx|mobile|school] [output-dir]

Modes:
  all     Generate every committed offline demo report.
  html    Generate the fixture-backed Jamf Pro HTML report.
  xlsx    Generate the fixture-backed Jamf Pro jamf-cli workbook.
  mobile  Generate the fixture-backed mobile CSV workbook.
  school  Generate the fixture-backed Jamf School CSV workbook.

Examples:
  ./scripts/demo.sh
  ./scripts/demo.sh html
  ./scripts/demo.sh school /tmp/jrc-demo
EOF
}

run_html() {
    DEMO_MODE="html" run_demo_python
}

run_xlsx() {
    DEMO_MODE="xlsx" run_demo_python
}

run_mobile() {
    DEMO_MODE="mobile" run_demo_python
}

run_school() {
    DEMO_MODE="school" run_demo_python
}

run_demo_python() {
    env PATH="$SAFE_PATH" REPO_DIR="$REPO_DIR" OUT_DIR="$OUT_DIR" DEMO_MODE="$DEMO_MODE" \
        "$PYTHON_BIN" - <<'PY'
import importlib.util
import os
from pathlib import Path

repo_dir = Path(os.environ["REPO_DIR"])
out_dir = Path(os.environ["OUT_DIR"])
demo_mode = os.environ["DEMO_MODE"]

spec = importlib.util.spec_from_file_location(
    "jamf_reports_community",
    repo_dir / "jamf-reports-community.py",
)
if spec is None or spec.loader is None:
    raise SystemExit("Unable to load jamf-reports-community.py")

jrc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jrc)
jrc._find_jamf_cli_binary = lambda: None

if demo_mode == "html":
    config = jrc.Config(str(repo_dir / "tests/fixtures/config/dummy.yaml"))
    jrc.cmd_html(config, str(out_dir / "jamf-pro-cached.html"), no_open=True)
elif demo_mode == "xlsx":
    config = jrc.Config(str(repo_dir / "tests/fixtures/config/dummy.yaml"))
    jrc.cmd_generate(config, None, str(out_dir / "jamf-pro-cached.xlsx"))
elif demo_mode == "mobile":
    config = jrc.Config(str(repo_dir / "tests/fixtures/config/harbor-mobile.yaml"))
    jrc.cmd_generate(
        config,
        str(repo_dir / "tests/fixtures/csv/harbor_mobile_insights_all_devices.csv"),
        str(out_dir / "jamf-pro-mobile-csv.xlsx"),
    )
elif demo_mode == "school":
    config = jrc.Config(str(repo_dir / "tests/fixtures/config/school_test.yaml"))
    jrc.cmd_school_generate(
        config,
        csv_path=str(repo_dir / "tests/fixtures/csv/harboredu_school_devices.csv"),
        out_file=str(out_dir / "jamf-school-csv.xlsx"),
    )
else:
    raise SystemExit(f"Unknown demo mode: {demo_mode}")
PY
}

case "$MODE" in
    -h|--help|help)
        usage
        exit 0
        ;;
    all|html|xlsx|mobile|school)
        ;;
    *)
        echo "Unknown demo mode: $MODE" >&2
        usage >&2
        exit 1
        ;;
esac

mkdir -p "$OUT_DIR"

echo "Repo:   $REPO_DIR"
echo "Python: $PYTHON_BIN"
echo "PATH:   $SAFE_PATH"
echo "Mode:   $MODE"
echo "Output: $OUT_DIR"

case "$MODE" in
    all)
        run_html
        run_xlsx
        run_mobile
        run_school
        ;;
    html)
        run_html
        ;;
    xlsx)
        run_xlsx
        ;;
    mobile)
        run_mobile
        ;;
    school)
        run_school
        ;;
esac

echo ""
echo "Demo output ready in: $OUT_DIR"
