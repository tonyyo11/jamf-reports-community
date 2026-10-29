#!/bin/zsh
# Tests for scripts/lib/spawn-constraint.zsh against a copy of the tick plist and a scratch
# bundle signed ad hoc. Needs macOS (plutil, codesign); nothing is installed or registered.
#
# Usage: zsh app/scripts/test-spawn-constraint.zsh   (works from any directory)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/spawn-constraint.zsh
source "${SCRIPT_DIR}/lib/spawn-constraint.zsh"

passed=0
failed=0
expect() {
  if [[ "$3" == "$2" ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL  %s\n      expected: [%s]\n      actual:   [%s]\n' "$1" "$2" "$3"
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
src="${APP_DIR}/LaunchAgents/com.github.tonyyo11.jamf-reports-community.tick.plist"
plist="${work}/tick.plist"

expect "team from a Developer ID subject" "ABCDE12345" \
  "$(jr_team_id_from_subject 'UID=ABCDE12345,CN=Developer ID Application: A B (ABCDE12345),OU=ABCDE12345,O=A B,C=US')"
expect "team from a multiline subject" "ABCDE12345" \
  "$(jr_team_id_from_subject 'subject= /UID=X/CN=n/OU=ABCDE12345/O=o/C=US')"
expect "no OU, no team" "" "$(jr_team_id_from_subject 'CN=nobody,O=o')"

cp "$src" "$plist"
jr_add_spawn_constraint "$plist" ABCDE12345 com.tonyyo.jamfreports
expect "lints" "0" "$(plutil -lint "$plist" >/dev/null 2>&1; echo $?)"
expect "team key" "ABCDE12345" "$(plutil -extract SpawnConstraint.team-identifier raw -o - "$plist")"
expect "identifier key" "com.tonyyo.jamfreports" \
  "$(plutil -extract SpawnConstraint.signing-identifier raw -o - "$plist")"
expect "Label kept" "com.github.tonyyo11.jamf-reports-community.tick" \
  "$(plutil -extract Label raw -o - "$plist")"
expect "BundleProgram kept" "Contents/MacOS/JamfReports" \
  "$(plutil -extract BundleProgram raw -o - "$plist")"
jr_add_spawn_constraint "$plist" ZZZZZ99999 com.example.other
expect "second call replaces" "ZZZZZ99999" "$(plutil -extract SpawnConstraint.team-identifier raw -o - "$plist")"

expect "short team ID refused" "1" "$(jr_add_spawn_constraint "$plist" ABC com.x 2>/dev/null; echo $?)"
expect "lowercase team ID refused" "1" "$(jr_add_spawn_constraint "$plist" abcde12345 com.x 2>/dev/null; echo $?)"
expect "identifier with a quote refused" "1" \
  "$(jr_add_spawn_constraint "$plist" ABCDE12345 'a"b' 2>/dev/null; echo $?)"
expect "missing plist refused" "1" \
  "$(jr_add_spawn_constraint "${work}/none.plist" ABCDE12345 com.x 2>/dev/null; echo $?)"

# An ad-hoc bundle has no team: a constrained plist must fail "required", an unconstrained
# one must fail "required" too (nothing to enforce) and pass "none".
app="${work}/T.app"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Library/LaunchAgents"
cp /bin/echo "${app}/Contents/MacOS/JamfReports"
cat > "${app}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.t</string>
<key>CFBundleExecutable</key><string>JamfReports</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
tickplist="${app}/Contents/Library/LaunchAgents/$(basename "$src")"
verify() { jr_verify_spawn_constraint "$app" "$1" >/dev/null 2>&1; echo $?; }

expect "no tick plist fails required" "1" "$(verify required)"
expect "no tick plist fails none" "1" "$(verify none)"
cp "$src" "$tickplist"
codesign --force --sign - "$app" >/dev/null 2>&1
expect "unconstrained passes none" "0" "$(verify none)"
expect "unconstrained fails required" "1" "$(verify required)"
expect "bad mode refused" "1" "$(verify maybe)"
jr_add_spawn_constraint "$tickplist" ABCDE12345 com.example.t
expect "constrained fails none" "1" "$(verify none)"
expect "constrained ad-hoc bundle fails required" "1" "$(verify required)"

printf '%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
