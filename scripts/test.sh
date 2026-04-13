#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

python3 -c "import py_compile; py_compile.compile('jamf-reports-community.py', doraise=True)"
python3 -m pytest tests -q "$@"
