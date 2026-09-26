#!/bin/zsh
# Behavioural tests for scripts/lib/versioning.zsh: the release channel, build
# number and artifact names that build-app.sh, build-pkg.sh and package-dmg.sh
# share. Needs only zsh and git (no Xcode, no macOS), so CI runs it on every
# push from the ubuntu shellcheck job.
#
# Usage: zsh app/scripts/test-versioning.zsh   (works from any directory)
# Prints each failing check and a summary; exits 1 if any check fails.

# No -e: a failing check is counted and reported instead of ending the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/versioning.zsh
source "${SCRIPT_DIR}/lib/versioning.zsh"

passed=0
failed=0

# expect <label> <expected> <actual>
expect() {
  if [[ "$3" == "$2" ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL  %s\n      expected: [%s]\n      actual:   [%s]\n' "$1" "$2" "$3"
  fi
}

# verdict <command...>: prints "accept" when the command succeeds, else "reject".
verdict() {
  if "$@" >/dev/null 2>&1; then
    printf 'accept\n'
  else
    printf 'reject\n'
  fi
}

# --- Release channel: only exactly "1" makes a release -------------------------
# channel_row <RELEASE value> <expected channel>
channel_row() { expect "jr_release_channel '$1'" "$2" "$(jr_release_channel "$1")"; }
channel_row 1 release
channel_row 0 beta
channel_row "" beta
channel_row true beta
channel_row yes beta
channel_row TRUE beta
channel_row 01 beta
channel_row " 1" beta
channel_row release beta
expect "jr_release_channel with no argument" beta "$(jr_release_channel)"
# build-app.sh passes "${RELEASE:-0}", so an unset RELEASE is a beta build.
expect "RELEASE unset" beta "$(unset RELEASE; jr_release_channel "${RELEASE:-0}")"

# --- Build number: BUILD_NUMBER, else the git commit count, else 0 -------------
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
# Git must look only at the repositories made here, whatever the caller exported.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# Git with no identity (CI runners have none) and no commit signing (a
# developer's global config may require it).
tgit() {
  git -c user.name=versioning-test -c user.email=versioning-test@example.com \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

repo="${tmp_root}/repo"
empty_repo="${tmp_root}/empty-repo"
plain_dir="${tmp_root}/plain"
mkdir -p "$repo" "$empty_repo" "$plain_dir"
tgit -C "$repo" init -q
for n in 1 2 3; do
  tgit -C "$repo" commit -q --allow-empty -m "commit $n"
done
tgit -C "$empty_repo" init -q

# build_number_in <dir> [BUILD_NUMBER value]: jr_build_number run in <dir>, with
# BUILD_NUMBER set to the value when one is given and unset otherwise.
build_number_in() {
  (
    cd "$1" || exit 1
    unset BUILD_NUMBER
    if (( $# > 1 )); then
      export BUILD_NUMBER="$2"
    fi
    # Stop git searching above the temp dir for a repository.
    export GIT_CEILING_DIRECTORIES="$tmp_root"
    jr_build_number
  )
}
expect "BUILD_NUMBER unset: commit count" 3 "$(build_number_in "$repo")"
expect "BUILD_NUMBER empty: commit count" 3 "$(build_number_in "$repo" "")"
expect "BUILD_NUMBER=4242 overrides the count" 4242 "$(build_number_in "$repo" 4242)"
expect "BUILD_NUMBER=0 is honoured" 0 "$(build_number_in "$repo" 0)"
expect "repository with no commits: 0" 0 "$(build_number_in "$empty_repo")"
expect "outside any repository: 0" 0 "$(build_number_in "$plain_dir")"
expect "outside any repository, BUILD_NUMBER=77" 77 "$(build_number_in "$plain_dir" 77)"

# --- Validators ----------------------------------------------------------------
# marketing_row <value> <accept|reject>
marketing_row() {
  expect "marketing version '$1'" "$2" "$(verdict jr_is_valid_marketing_version "$1")"
}
marketing_row 2.8.0 accept
marketing_row 10.12.3 accept
marketing_row 2.8 accept          # build-pkg.sh has always taken N.N
marketing_row 2.8.0-beta1 reject
marketing_row 2.8.0-beta812 reject
marketing_row v2.8.0 reject
marketing_row 2.8.0.1 reject
marketing_row 2 reject
marketing_row 2.8. reject
marketing_row "" reject
marketing_row " 2.8.0" reject
marketing_row "2.8.0 " reject
marketing_row 2x8 reject          # an inline \. in zsh matched any character
marketing_row 2x8x0 reject

# build_row <value> <accept|reject>
build_row() { expect "build number '$1'" "$2" "$(verdict jr_is_valid_build_number "$1")"; }
build_row 812 accept
build_row 0 accept
build_row "" reject
build_row abc reject
build_row 812a reject
build_row 8.1 reject
build_row 2.8.0 reject
build_row -1 reject
build_row " 812" reject

# --- Artifact version and names ------------------------------------------------
# version_row <expected> <marketing-version> <build> <channel>
version_row() {
  expect "jr_artifact_version $2 $3 '$4'" "$1" "$(jr_artifact_version "$2" "$3" "$4")"
}
version_row 2.8.0-beta812 2.8.0 812 beta
version_row 2.8.0 2.8.0 812 release
version_row 2.8.0-beta812 2.8.0 812 ""

# name_row <expected> <marketing-version> <build> <channel> <extension>
name_row() {
  expect "jr_artifact_name $2 $3 '$4' $5" "$1" "$(jr_artifact_name "$2" "$3" "$4" "$5")"
}
name_row JamfReports-2.8.0-beta812.pkg 2.8.0 812 beta pkg
name_row JamfReports-2.8.0-beta812.dmg 2.8.0 812 beta dmg
name_row JamfReports-2.8.0.pkg 2.8.0 812 release pkg
name_row JamfReports-2.8.0.dmg 2.8.0 812 release dmg
# An .app without JRReleaseChannel reads back as "beta". An empty or unknown
# value is never a release either: only exactly "release" drops the suffix.
name_row JamfReports-2.8.0-beta812.pkg 2.8.0 812 "" pkg
name_row JamfReports-2.8.0-beta812.dmg 2.8.0 812 "" dmg
name_row JamfReports-2.8.0-beta812.pkg 2.8.0 812 Release pkg
name_row JamfReports-2.8.0-beta812.pkg 2.8.0 812 releases pkg

expect "jr_artifact_path build/" build/JamfReports-2.8.0-beta812.pkg \
  "$(jr_artifact_path build 2.8.0 812 beta pkg)"
expect "jr_artifact_path strips a trailing slash" /tmp/app/build/JamfReports-2.8.0.dmg \
  "$(jr_artifact_path /tmp/app/build/ 2.8.0 812 release dmg)"
expect "jr_artifact_version with 2 args fails" reject "$(verdict jr_artifact_version 2.8.0 812)"
expect "jr_artifact_name with 3 args fails" reject "$(verdict jr_artifact_name 2.8.0 812 beta)"
expect "jr_artifact_path with 4 args fails" reject \
  "$(verdict jr_artifact_path build 2.8.0 812 beta)"

# The whole chain: RELEASE at build time, JRReleaseChannel read back at packaging.
expect "RELEASE=1 build packages as a release" JamfReports-2.8.0.pkg \
  "$(jr_artifact_name 2.8.0 812 "$(jr_release_channel 1)" pkg)"
expect "RELEASE unset build packages as a beta" JamfReports-2.8.0-beta812.dmg \
  "$(jr_artifact_name 2.8.0 812 "$(jr_release_channel 0)" dmg)"

# --- Wiring --------------------------------------------------------------------
# The checks above only matter while the scripts use the library, so each one
# must source it, call the functions it needs, and keep no -beta naming of its own.
# wired <script> <function...>
wired() {
  local script="$1" file="${APP_DIR}/$1" fn
  shift
  expect "$script sources lib/versioning.zsh" yes "$(
    grep -qE '^[[:space:]]*source .*lib/versioning\.zsh' "$file" && echo yes || echo no)"
  for fn in "$@"; do
    expect "$script calls $fn" yes "$(grep -qw "$fn" "$file" && echo yes || echo no)"
  done
  expect "$script has no inline -beta naming" no "$(
    grep -qF -e "-beta\${" "$file" && echo yes || echo no)"
}
wired build-app.sh jr_build_number jr_release_channel
wired build-pkg.sh jr_is_valid_marketing_version jr_is_valid_build_number \
  jr_artifact_path jr_artifact_version
wired scripts/package-dmg.sh jr_is_valid_build_number jr_artifact_path

# --- Summary -------------------------------------------------------------------
total=$((passed + failed))
if (( failed > 0 )); then
  printf '\nversioning: %d of %d checks failed\n' "$failed" "$total"
  exit 1
fi
printf 'versioning: all %d checks passed\n' "$total"
