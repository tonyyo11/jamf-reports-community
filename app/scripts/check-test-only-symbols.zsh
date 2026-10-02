#!/bin/zsh
# Fails when a type or function declared in app/Sources is referenced only from
# app/Tests. A feature once survived for months with no production caller because
# its tests made it look used; this keeps that from accumulating again.
#
# A declaration is reported when its name
#   - is declared by `struct`, `class`, `enum`, `actor`, `protocol` or `func`,
#   - is at least 6 characters long,
#   - appears as a whole word exactly once in app/Sources (the declaration, so
#     it is also declared exactly once), and
#   - appears as a whole word at least once in app/Tests.
# A whole word is a run of [A-Za-z0-9_], the same boundary `grep -w` uses.
#
# Deliberate test seams go in app/scripts/test-only-symbols.allow, one per line
# as `Name  # reason`. A line without a reason is an error, so the list stays
# explained.
#
# What counts as an occurrence, in both trees:
#   - Line comments (`//` and `///`, to the end of the line) do not count, so a
#     `// MARK: - Name` or a doc comment cannot make a type look used. A `//`
#     inside a string literal also ends the line, except the one in `://`.
#   - Block comments and string literals do count, which errs toward not
#     reporting a name that only a block comment or a string mentions.
#
# Other limits, all of which err toward not reporting:
#   - Declarations are found line by line. A keyword is recognised only at the
#     start of a line after attributes and modifiers (`@MainActor final class`).
#   - Operators, backticked names and names under 6 characters are skipped, as
#     are overloads and the same name in two types (declared more than once).
#   - Properties, cases and initializers are not checked.
#
# One awk pass counts every identifier in both trees, about a second on this
# repo. It needs only zsh and /usr/bin/awk, find and sort, so CI runs it on the
# ubuntu shellcheck job (mawk) and a Mac runs it with BSD awk; the awk program
# uses POSIX features only. It sticks to syntax bash also parses, because CI
# lints it with `shellcheck --shell=bash`.
#
# Usage: zsh app/scripts/check-test-only-symbols.zsh [repo-root]
# repo-root defaults to the checkout this script lives in.
# Exit 0: clean. Exit 1: symbols reported. Exit 2: bad layout or allow-list.

set -euo pipefail

# C locale: byte-wise matching is faster and identical on every runner.
export LC_ALL=C

readonly SOURCES_DIR="app/Sources"
readonly TESTS_DIR="app/Tests"
readonly ALLOW_FILE="app/scripts/test-only-symbols.allow"

die() {
  printf 'check-test-only-symbols: %s\n' "$1" >&2
  exit 2
}

repo_root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "${repo_root}" || die "cannot enter repo root '${repo_root}'"
[[ -d "${SOURCES_DIR}" ]] || die "no ${SOURCES_DIR} directory under '${repo_root}'"
[[ -d "${TESTS_DIR}" ]] || die "no ${TESTS_DIR} directory under '${repo_root}'"

# Allow-list: `Name  # reason`, blank lines and whole-line comments ignored.
typeset -A allowed
if [[ -f "${ALLOW_FILE}" ]]; then
  lineno=0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    lineno=$((lineno + 1))
    entry="${raw%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "${entry}" ]] && continue
    if [[ "${raw}" != *"#"* ]]; then
      die "${ALLOW_FILE}:${lineno}: '${entry}' has no reason; write 'Name  # why tests need it'"
    fi
    reason="${raw#*#}"
    reason="${reason#"${reason%%[![:space:]]*}"}"
    [[ -n "${reason}" ]] || die "${ALLOW_FILE}:${lineno}: '${entry}' has an empty reason"
    [[ "${entry}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
      die "${ALLOW_FILE}:${lineno}: '${entry}' is not a single identifier"
    allowed[${entry}]=1
  done <"${ALLOW_FILE}"
fi

# The loop variable is not `path`: in zsh that is tied to PATH.
source_files=()
while IFS= read -r swift_file; do
  source_files+=("${swift_file}")
done < <(/usr/bin/find "${SOURCES_DIR}" -type f -name '*.swift' | /usr/bin/sort)
test_files=()
while IFS= read -r swift_file; do
  test_files+=("${swift_file}")
done < <(/usr/bin/find "${TESTS_DIR}" -type f -name '*.swift' | /usr/bin/sort)
((${#source_files[@]} > 0)) || die "no .swift files under ${SOURCES_DIR}"
((${#test_files[@]} > 0)) || die "no .swift files under ${TESTS_DIR}"

# Sources come first on the awk command line. The first tests file closes the
# candidate set (declared names with one occurrence in Sources); tests then only
# count tokens that are candidates. Output: "path:line<TAB>name", one per hit.
# shellcheck disable=SC2016 # the awk program is single-quoted on purpose
readonly AWK_PROGRAM='
# Strip leading attributes and modifiers so a declaration keyword comes first.
function bare(s) {
  while (1) {
    if (match(s, /^@[A-Za-z0-9_.]+(\([^)]*\))?[ \t]+/)) { s = substr(s, RLENGTH + 1); continue }
    if (s ~ /^class[ \t]+func[ \t]/) { match(s, /^class[ \t]+/); s = substr(s, RLENGTH + 1); continue }
    if (match(s, /^(public|private|fileprivate|internal|open|package|final|static|nonisolated|indirect|override|mutating|nonmutating|convenience|required|dynamic|prefix|postfix|infix|isolated|distributed|unowned|weak)[ \t]+/)) {
      s = substr(s, RLENGTH + 1); continue
    }
    return s
  }
}

# One occurrence in Sources is the declaration itself, so this also means the
# name is declared once: every declaration adds an occurrence.
function build_candidates(   name) {
  if (built) return
  built = 1
  for (name in ndecl)
    if (length(name) >= 6 && scount[name] == 1) cand[name] = 1
}

FNR == 1 {
  in_tests = (index(FILENAME, tests_prefix) == 1)
  if (in_tests) build_candidates()
}

{
  # Drop a line comment (// and ///) in both trees. ":/" for "://" keeps the
  # slashes of a URL in a string from starting one; its tokens are unchanged.
  line = $0
  gsub(/:\/\//, ":/", line)
  sub(/\/\/.*$/, "", line)
  if (!in_tests) {
    d = line
    sub(/^[ \t]+/, "", d)
    if (d ~ /(struct|class|enum|actor|protocol|func)[ \t]+[A-Za-z_]/) {
      d = bare(d)
      if (match(d, /^(struct|class|enum|actor|protocol|func)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
        name = substr(d, 1, RLENGTH)
        sub(/^[a-z]+[ \t]+/, "", name)
        if (!(name in ndecl)) loc[name] = FILENAME ":" FNR
        ndecl[name]++
      }
    }
  }
  gsub(/[^A-Za-z0-9_]+/, " ", line)
  n = split(line, tok, " ")
  if (in_tests) {
    for (i = 1; i <= n; i++) if (tok[i] in cand) tcount[tok[i]]++
  } else {
    for (i = 1; i <= n; i++) scount[tok[i]]++
  }
}

END {
  build_candidates()
  for (name in cand) if (tcount[name] > 0) printf "%s\t%s\n", loc[name], name
}
'

if ! hits="$(/usr/bin/awk -v tests_prefix="${TESTS_DIR}/" "${AWK_PROGRAM}" \
  "${source_files[@]}" "${test_files[@]}" | /usr/bin/sort)"; then
  die "awk failed while scanning ${SOURCES_DIR} and ${TESTS_DIR}"
fi

reported=0
allow_hits=0
while IFS=$'\t' read -r where name; do
  [[ -n "${where}" ]] || continue
  if [[ -n "${allowed[${name}]-}" ]]; then
    allow_hits=$((allow_hits + 1))
    continue
  fi
  printf '%s: %s is referenced only from %s\n' "${where}" "${name}" "${TESTS_DIR}" >&2
  reported=$((reported + 1))
done <<<"${hits}"

if ((reported > 0)); then
  printf 'check-test-only-symbols: %d symbol(s) used only by tests. Delete them, or list a deliberate test seam with a reason in %s\n' \
    "${reported}" "${ALLOW_FILE}" >&2
  exit 1
fi
printf 'check-test-only-symbols: OK, no symbol in %s is referenced only from %s (%d allow-listed)\n' \
  "${SOURCES_DIR}" "${TESTS_DIR}" "${allow_hits}"
