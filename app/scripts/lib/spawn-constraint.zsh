#!/bin/zsh
# The launchd spawn constraint on the bundled tick agent's plist (SpawnConstraint key, honored
# from macOS 14): launchd starts Contents/MacOS/JamfReports for the tick only when its code
# signature carries the team and signing identifier the release was built with. build-app.sh adds
# it when it signs with a real identity and never for an ad-hoc build, so a source build with
# its own team or none still runs its tick. scripts/test-spawn-constraint.zsh covers it in CI.
#
# Sourced, never executed. It defines jr_* functions and nothing else, and sticks to syntax bash
# also parses, because CI lints it with `shellcheck --shell=bash`.

# jr_team_id_from_subject <certificate subject>
# Prints the team ID, the OU of a Developer ID or Apple Development certificate (ten letters and
# digits), or nothing.
jr_team_id_from_subject() {
  local subject="${1-}" team
  team="$(printf '%s\n' "$subject" | sed -n 's/.*OU[ ]*=[ ]*\([A-Z0-9]\{10\}\)\([,\/ ].*\)\{0,1\}$/\1/p' | head -1)"
  printf '%s\n' "$team"
}

# jr_identity_team_id <signing identity name>
# Prints the team ID from the named identity's certificate, else from a trailing "(TEAMID)" in
# the name, or nothing when neither gives one (a SHA-1 hash identity with no keychain match).
jr_identity_team_id() {
  local pem subject team trailing='\(([A-Z0-9]{10})\)$'
  pem="$(security find-certificate -c "${1-}" -p 2>/dev/null)"
  if [[ -n "$pem" ]]; then
    subject="$(printf '%s\n' "$pem" | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null)"
    team="$(jr_team_id_from_subject "$subject")"
  fi
  if [[ -z "$team" && "${1-}" =~ $trailing ]]; then
    team="${1##*\(}"
    team="${team%\)}"
  fi
  printf '%s\n' "$team"
}

# jr_add_spawn_constraint <plist> <team ID> <signing identifier>
# Sets SpawnConstraint on the plist (replacing one already there) and lints the result. Returns
# 1 with a message on stderr for a team ID that is not ten letters/digits, an identifier with
# anything but letters, digits, dots and dashes, or a plist plutil rejects.
jr_add_spawn_constraint() {
  local plist="${1-}" team="${2-}" identifier="${3-}"
  if [[ ! -f "$plist" ]]; then
    echo "✗ spawn constraint: $plist not found" >&2; return 1
  fi
  if ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "✗ spawn constraint: team ID '$team' is not ten letters/digits" >&2; return 1
  fi
  if ! [[ "$identifier" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "✗ spawn constraint: signing identifier '$identifier' is not usable" >&2; return 1
  fi
  plutil -replace SpawnConstraint -json \
    "{\"team-identifier\":\"${team}\",\"signing-identifier\":\"${identifier}\"}" "$plist" \
    && plutil -lint "$plist" >/dev/null
}

# jr_verify_spawn_constraint <app bundle> <required|none>
# "required": fails unless the tick plist carries a SpawnConstraint and the bundled executable's
# signature has the team and identifier it demands, so a build launchd would refuse to start is
# stopped here. "none": fails if the plist carries one (an ad-hoc build must not).
jr_verify_spawn_constraint() {
  local app="${1-}" mode="${2-}" plist team identifier info
  case "$mode" in
    required|none) ;;
    *) echo "✗ spawn constraint: mode must be required or none" >&2; return 1 ;;
  esac
  plist="$(ls "$app"/Contents/Library/LaunchAgents/*.tick.plist 2>/dev/null | head -1)"
  if [[ -z "$plist" ]]; then
    echo "✗ spawn constraint: no tick plist in $app" >&2; return 1
  fi
  team="$(plutil -extract SpawnConstraint.team-identifier raw -o - "$plist" 2>/dev/null)"
  identifier="$(plutil -extract SpawnConstraint.signing-identifier raw -o - "$plist" 2>/dev/null)"
  if [[ "$mode" == "none" ]]; then
    if plutil -extract SpawnConstraint raw -o - "$plist" >/dev/null 2>&1; then
      echo "✗ spawn constraint: an unsigned or ad-hoc build must not carry one" >&2; return 1
    fi
    return 0
  fi
  if [[ -z "$team" || -z "$identifier" ]]; then
    echo "✗ spawn constraint: the tick plist has no complete SpawnConstraint" >&2; return 1
  fi
  info="$(codesign -dvv "$app/Contents/MacOS/JamfReports" 2>&1)"
  if ! printf '%s\n' "$info" | grep -qx "TeamIdentifier=${team}" \
     || ! printf '%s\n' "$info" | grep -qx "Identifier=${identifier}"; then
    echo "✗ the signed executable does not match the tick agent's SpawnConstraint" >&2
    printf '%s\n' "$info" | grep -E '^(Identifier|TeamIdentifier)=' >&2
    return 1
  fi
}
