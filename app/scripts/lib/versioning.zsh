#!/bin/zsh
# Version, release-channel and artifact-naming rules shared by build-app.sh
# (the build number and channel it stamps into Info.plist), build-pkg.sh and
# scripts/package-dmg.sh (the names they give the .pkg and .dmg). One copy, so
# the three cannot drift apart; scripts/test-versioning.zsh covers it in CI.
#
# Sourced, never executed. It defines jr_* functions and nothing else (no
# variables, no `set` options), so the caller's shell is left as it was. It
# sticks to syntax bash also parses, because CI lints it with
# `shellcheck --shell=bash`.

# jr_release_channel <RELEASE value>
# Prints "release" when the value is exactly "1" and "beta" for anything else,
# including empty, "0", "true" and "yes", so a release is never cut by accident.
jr_release_channel() {
  if [[ "${1-}" == "1" ]]; then
    printf 'release\n'
  else
    printf 'beta\n'
  fi
}

# jr_build_number
# Prints the build number (CFBundleVersion): $BUILD_NUMBER when it is set and
# non-empty, otherwise the commit count of the git repository around the
# current directory, otherwise 0.
jr_build_number() {
  if [[ -n "${BUILD_NUMBER:-}" ]]; then
    printf '%s\n' "$BUILD_NUMBER"
    return 0
  fi
  local count
  if count="$(git rev-list --count HEAD 2>/dev/null)" && [[ -n "$count" ]]; then
    printf '%s\n' "$count"
  else
    printf '0\n'
  fi
}

# jr_is_valid_marketing_version <version>
# Succeeds for N.N or N.N.N, digits only (CFBundleShortVersionString). The dots
# are written [.] rather than \. on purpose: zsh strips the backslash from an
# inline =~ pattern, so \. matched any character and "2x8" passed.
jr_is_valid_marketing_version() {
  [[ "${1-}" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]]
}

# jr_is_valid_build_number <build>
# Succeeds for a non-negative integer (CFBundleVersion).
jr_is_valid_build_number() {
  [[ "${1-}" =~ ^[0-9]+$ ]]
}

# jr_artifact_version <marketing-version> <build> <channel>
# Prints the version an artifact carries: "2.8.0" on the release channel and
# "2.8.0-beta812" on any other, including an empty or unknown channel. Only
# the exact string "release" counts as the release channel.
jr_artifact_version() {
  if (( $# != 3 )); then
    printf 'jr_artifact_version: want 3 args (version build channel), got %d\n' "$#" >&2
    return 2
  fi
  if [[ "$3" == "release" ]]; then
    printf '%s\n' "$1"
  else
    printf '%s-beta%s\n' "$1" "$2"
  fi
}

# jr_artifact_name <marketing-version> <build> <channel> <extension>
# Prints the artifact file name, e.g. JamfReports-2.8.0-beta812.pkg or
# JamfReports-2.8.0.dmg.
jr_artifact_name() {
  if (( $# != 4 )); then
    printf 'jr_artifact_name: want 4 args (version build channel ext), got %d\n' "$#" >&2
    return 2
  fi
  local version
  version="$(jr_artifact_version "$1" "$2" "$3")" || return
  printf 'JamfReports-%s.%s\n' "$version" "$4"
}

# jr_artifact_path <directory> <marketing-version> <build> <channel> <extension>
# Prints <directory>/<artifact name>, e.g. build/JamfReports-2.8.0.pkg.
jr_artifact_path() {
  if (( $# != 5 )); then
    printf 'jr_artifact_path: want 5 args (dir version build channel ext), got %d\n' "$#" >&2
    return 2
  fi
  local name
  name="$(jr_artifact_name "$2" "$3" "$4" "$5")" || return
  printf '%s/%s\n' "${1%/}" "$name"
}
