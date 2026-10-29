#!/bin/zsh
# Re-captures jamf-cli's command catalog for the help-contract test.
# Run by hand when the jamf-cli floor moves; tests never run jamf-cli.
#   scripts/capture-jamf-cli-catalog.zsh [path/to/jamf-cli]
set -euo pipefail

jamf_cli="${1:-jamf-cli}"
dest_dir="${0:A:h:h}/Tests/JamfReportsTests/Fixtures/jamf-cli"

if ! command -v "${jamf_cli}" >/dev/null 2>&1; then
  print -u2 "capture-jamf-cli-catalog: '${jamf_cli}' not found"
  exit 1
fi

# First line of `jamf-cli version` is "jamf-cli 1.31.1".
version="$("${jamf_cli}" version | head -n 1 | awk '{print $2}')"
if [[ -z "${version}" ]]; then
  print -u2 "capture-jamf-cli-catalog: could not read the version from '${jamf_cli} version'"
  exit 1
fi

dest="${dest_dir}/commands-${version}.json"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

"${jamf_cli}" commands -o json >"${tmp}"
# A catalog that is not a JSON array would fail every test that reads it.
/usr/bin/python3 -I -c 'import json,sys; assert isinstance(json.load(open(sys.argv[1])), list)' "${tmp}"

mkdir -p "${dest_dir}"
mv "${tmp}" "${dest}"
chmod 644 "${dest}"
print "captured ${dest}"
