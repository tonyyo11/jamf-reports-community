#!/bin/zsh
# Re-captures jamf-cli's command catalog for the help-contract test.
# Run by hand when the jamf-cli floor moves; tests never run jamf-cli.
#   scripts/capture-jamf-cli-catalog.zsh [path/to/jamf-cli]
# jamf-cli prints each row's aliases in map order, so the capture sorts them and writes the
# JSON with 2-space indent: a re-capture then differs from the committed file only where
# jamf-cli changed.
set -euo pipefail

jamf_cli="${1:-jamf-cli}"
dest_dir="${0:A:h:h}/Tests/JamfReportsTests/Fixtures/jamf-cli"

if ! command -v "${jamf_cli}" >/dev/null 2>&1; then
  print -u2 "capture-jamf-cli-catalog: '${jamf_cli}' not found"
  exit 1
fi

# `jamf-cli version` starts with "jamf-cli 1.31.1".
version_text="$("${jamf_cli}" version)"
first_line="${version_text%%$'\n'*}"
version="${first_line##* }"
if [[ -z "${version}" || "${version}" == "${first_line}" ]]; then
  print -u2 "capture-jamf-cli-catalog: could not read the version from '${jamf_cli} version'"
  exit 1
fi

dest="${dest_dir}/commands-${version}.json"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

"${jamf_cli}" commands -o json >"${tmp}"
# Fails on a catalog that is not a JSON array of rows, which every test that reads it needs.
/usr/bin/python3 -I - "${tmp}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    rows = json.load(f)
assert isinstance(rows, list), "commands -o json is not a JSON array"
for row in rows:
    if isinstance(row.get("aliases"), str):
        words = [w.strip() for w in row["aliases"].split(",") if w.strip()]
        row["aliases"] = ", ".join(sorted(words))
with open(path, "w") as f:
    json.dump(rows, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

mkdir -p "${dest_dir}"
mv "${tmp}" "${dest}"
chmod 644 "${dest}"
print "captured ${dest}"
