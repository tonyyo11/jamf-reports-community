#!/bin/zsh
# Rebuilds Localization/Localizable.xcstrings from what the compiler extracts from the source.
# New keys join with no translation, and the catalog tests fail until they have one. Keys no
# source uses are marked stale; drop them with --prune-stale.
set -euo pipefail
cd "${0:A:h}/.."
catalog=Localization/Localizable.xcstrings
work="$(mktemp -d)"
trap 'trash "$work" 2>/dev/null || true' EXIT
swift build --product JamfReports --scratch-path "$work/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$work/data"
[[ -f "$catalog" ]] || print -r -- '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "$catalog"
xcrun xcstringstool sync "$catalog" --stringsdata "$work"/data/*.stringsdata
if [[ "${1:-}" == "--prune-stale" ]]; then
  /usr/bin/python3 -I - "$catalog" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p,encoding='utf8'))
d['strings']={k:v for k,v in d['strings'].items() if v.get('extractionState')!='stale'}
json.dump(d,open(p,'w',encoding='utf8'),ensure_ascii=False,indent=2,sort_keys=True,separators=(',',' : '))
PY
fi
