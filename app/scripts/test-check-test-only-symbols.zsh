#!/bin/zsh
# Behavioural tests for check-test-only-symbols.zsh. Each case builds a small
# repo layout (app/Sources, app/Tests, the allow-list) in a temp directory and
# runs the check against it. Needs only zsh and the tools the check uses, so CI
# runs it on every push from the ubuntu shellcheck job.
#
# Usage: zsh app/scripts/test-check-test-only-symbols.zsh   (works from any directory)
# Prints each failing check and a summary; exits 1 if any check fails.

# No -e: a failing check is counted and reported instead of ending the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="${SCRIPT_DIR}/check-test-only-symbols.zsh"

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

# has <label> <text> <needle>: passes when the text contains the needle.
has() {
  if [[ "$2" == *"$3"* ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL  %s\n      missing: [%s]\n      in:      [%s]\n' "$1" "$3" "$2"
  fi
}

# lacks <label> <text> <needle>: passes when the text does not contain the needle.
lacks() {
  if [[ "$2" != *"$3"* ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL  %s\n      unexpected: [%s]\n      in:         [%s]\n' "$1" "$3" "$2"
  fi
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

# put <file> <line>...: writes the lines to the file, creating its directory.
# Not named `path`: in zsh that is tied to PATH.
put() {
  local dest="$1"
  shift
  mkdir -p "$(dirname "${dest}")"
  printf '%s\n' "$@" >"${dest}"
}

# run_check <root> [args]: runs the check; sets CODE, OUT (stdout) and ERR (stderr).
run_check() {
  OUT="$(zsh "${CHECK}" "$@" 2>"${tmp_root}/stderr")"
  CODE=$?
  ERR="$(<"${tmp_root}/stderr")"
}

# new_tree <name>: prints the root of a repo layout where nothing is test-only.
# The root has a space in it, as a checkout under "~/Library/Mobile Documents" does.
# Every symbol below must stay out of the report.
new_tree() {
  local root="${tmp_root}/$1 repo"
  put "${root}/app/Sources/Demo/Used.swift" 'struct UsedWidget {}'
  put "${root}/app/Sources/Demo/Caller.swift" \
    'func makeThings() {' \
    '    let note = "see StringMention"' \
    '    _ = UsedWidget()' \
    '    _ = Holder()' \
    '    let endpoint = "https://example.com/path"; _ = AfterUrlHelper()' \
    '}'
  # Declared once, no references at all: dead code, not test-only.
  put "${root}/app/Sources/Demo/Unused.swift" 'func neverCalledAnywhere() {}'
  # Too short to report, however it is used.
  put "${root}/app/Sources/Demo/Short.swift" 'func tiny() {}'
  # The same name declared twice.
  put "${root}/app/Sources/Demo/DupeA.swift" 'struct DupeThing {}'
  put "${root}/app/Sources/Demo/DupeB.swift" 'enum Namespace { struct DupeThing {} }'
  # Only a string literal in Sources mentions it; a string counts, a comment does not.
  put "${root}/app/Sources/Demo/Mention.swift" 'struct StringMention {}'
  # Its only other use in Sources follows a URL on the same line: "://" must not
  # start a comment and hide it.
  put "${root}/app/Sources/Demo/AfterUrl.swift" 'struct AfterUrlHelper {}'
  # Only a comment in Tests mentions it: no test reference, so not test-only.
  put "${root}/app/Sources/Demo/TestComment.swift" 'struct TestCommentOnly {}'
  # Backticked names are skipped. The backticks are Swift source, not shell.
  # shellcheck disable=SC2016
  put "${root}/app/Sources/Demo/Ticks.swift" 'func `repository`() {}'
  # Deliberate seam, allow-listed with a reason.
  put "${root}/app/Sources/Demo/Seam.swift" 'enum SeamHelper {}'
  put "${root}/app/Sources/Demo/Holder.swift" 'class Holder {}'
  put "${root}/app/scripts/test-only-symbols.allow" \
    '# header comment' \
    '' \
    'SeamHelper   # tests build it directly'
  # shellcheck disable=SC2016 # backticks in the Swift line below, not shell
  put "${root}/app/Tests/DemoTests/UsedTests.swift" \
    'func checkUsed() {' \
    '    _ = UsedWidget()' \
    '    tiny()' \
    '    _ = DupeThing()' \
    '    _ = StringMention()' \
    '    _ = AfterUrlHelper()' \
    '    // TestCommentOnly is covered elsewhere' \
    '    `repository`()' \
    '    _ = SeamHelper()' \
    '}'
  printf '%s' "${root}"
}

# --- Clean tree: exit 0 and a one-line summary on stdout -----------------------
root="$(new_tree clean)"
run_check "${root}"
expect "clean tree exits 0" 0 "${CODE}"
has "clean tree prints OK" "${OUT}" "check-test-only-symbols: OK"
has "clean tree counts the allow-listed seam" "${OUT}" "(1 allow-listed)"
expect "clean tree prints one stdout line" 1 "$(printf '%s\n' "${OUT}" | grep -c .)"
expect "clean tree prints nothing on stderr" "" "${ERR}"

# --- Test-only symbols: each reported with path:line, exit 1 -------------------
root="$(new_tree orphans)"
put "${root}/app/Sources/Demo/Orphan.swift" \
  '// header' \
  'struct OrphanWidget {}'
put "${root}/app/Sources/Demo/Methods.swift" \
  'extension Holder {' \
  '    static func orphanFunc() {}' \
  '    @MainActor final class InlineAttr {}' \
  '    private final class PrivateOrphan {}' \
  '    class func classOrphan() {}' \
  '}' \
  '@available(macOS 15, *) struct AvailableOrphan {}'
# Line comments that name a symbol must not hide it: a MARK line, a doc comment
# and a trailing comment all mention a type that real code never uses.
put "${root}/app/Sources/Demo/Marked.swift" \
  '// MARK: - MarkedOrphan' \
  'struct MarkedOrphan {}' \
  '/// Names DocOrphan in a doc comment.' \
  'struct DocOrphan {} // and TrailingOrphan, in a trailing comment' \
  'struct TrailingOrphan {}'
put "${root}/app/Tests/DemoTests/OrphanTests.swift" \
  'func checkOrphans() {' \
  '    _ = MarkedOrphan()' \
  '    _ = DocOrphan()' \
  '    _ = TrailingOrphan()' \
  '    _ = OrphanWidget()' \
  '    Holder.orphanFunc()' \
  '    _ = Holder.InlineAttr()' \
  '    _ = Holder.PrivateOrphan()' \
  '    Holder.classOrphan()' \
  '    _ = AvailableOrphan()' \
  '}'
run_check "${root}"
expect "orphans exit 1" 1 "${CODE}"
expect "orphans print nothing on stdout" "" "${OUT}"
has "reports a test-only struct" "${ERR}" \
  "app/Sources/Demo/Orphan.swift:2: OrphanWidget is referenced only from app/Tests"
has "reports a static func" "${ERR}" \
  "app/Sources/Demo/Methods.swift:2: orphanFunc is referenced only from app/Tests"
has "reports a class after attributes and modifiers" "${ERR}" \
  "app/Sources/Demo/Methods.swift:3: InlineAttr is referenced only from app/Tests"
has "reports a private class" "${ERR}" \
  "app/Sources/Demo/Methods.swift:4: PrivateOrphan is referenced only from app/Tests"
has "reports a class func" "${ERR}" \
  "app/Sources/Demo/Methods.swift:5: classOrphan is referenced only from app/Tests"
has "reports a type after an availability attribute" "${ERR}" \
  "app/Sources/Demo/Methods.swift:7: AvailableOrphan is referenced only from app/Tests"
has "a MARK comment does not hide a type" "${ERR}" \
  "app/Sources/Demo/Marked.swift:2: MarkedOrphan is referenced only from app/Tests"
has "a doc comment does not hide a type" "${ERR}" \
  "app/Sources/Demo/Marked.swift:4: DocOrphan is referenced only from app/Tests"
has "a trailing comment does not hide a type" "${ERR}" \
  "app/Sources/Demo/Marked.swift:5: TrailingOrphan is referenced only from app/Tests"
expect "orphans report exactly nine symbols" 9 \
  "$(printf '%s\n' "${ERR}" | grep -c 'is referenced only from app/Tests')"
has "orphans name the allow-list file" "${ERR}" "app/scripts/test-only-symbols.allow"
for name in UsedWidget makeThings Holder neverCalledAnywhere tiny DupeThing StringMention \
  AfterUrlHelper TestCommentOnly repository SeamHelper; do
  lacks "does not report ${name}" "${ERR}" ": ${name} is referenced"
done

# --- Allow-listing the orphans clears the report -------------------------------
put "${root}/app/scripts/test-only-symbols.allow" \
  'SeamHelper      # tests build it directly' \
  'OrphanWidget    # pinned by a test' \
  'orphanFunc      # pinned by a test' \
  'InlineAttr      # pinned by a test' \
  'PrivateOrphan   # pinned by a test' \
  'classOrphan     # pinned by a test' \
  'AvailableOrphan # pinned by a test' \
  'MarkedOrphan    # pinned by a test' \
  'DocOrphan       # pinned by a test' \
  'TrailingOrphan  # pinned by a test'
run_check "${root}"
expect "allow-listed orphans exit 0" 0 "${CODE}"
has "allow-listed orphans are counted" "${OUT}" "(10 allow-listed)"
expect "fully matched allow-list warns about nothing" "" "${ERR}"

# --- An allow-list entry that matches nothing is a warning, not a failure ------
put "${root}/app/scripts/test-only-symbols.allow" \
  'SeamHelper      # tests build it directly' \
  'GoneSymbol      # deleted since' \
  'OrphanWidget    # pinned by a test' \
  'orphanFunc      # pinned by a test' \
  'InlineAttr      # pinned by a test' \
  'PrivateOrphan   # pinned by a test' \
  'classOrphan     # pinned by a test' \
  'AvailableOrphan # pinned by a test' \
  'MarkedOrphan    # pinned by a test' \
  'DocOrphan       # pinned by a test' \
  'TrailingOrphan  # pinned by a test'
run_check "${root}"
expect "a stale entry still exits 0" 0 "${CODE}"
has "a stale entry is named with its line" "${ERR}" \
  "app/scripts/test-only-symbols.allow:2: GoneSymbol is not referenced only from app/Tests; remove the entry"
expect "only the stale entry warns" 1 "$(printf '%s\n' "${ERR}" | grep -c 'warning:')"
has "the summary still prints" "${OUT}" "(10 allow-listed)"

# --- A symbol with no test reference is not reported ---------------------------
root="$(new_tree no-test-reference)"
put "${root}/app/Sources/Demo/Lonely.swift" 'struct LonelyWidget {}'
run_check "${root}"
expect "an unreferenced symbol exits 0" 0 "${CODE}"

# --- Allow-list entries must carry a reason ------------------------------------
root="$(new_tree no-reason)"
put "${root}/app/scripts/test-only-symbols.allow" 'SeamHelper'
run_check "${root}"
expect "an entry without a reason exits 2" 2 "${CODE}"
has "names the line and the missing reason" "${ERR}" \
  "app/scripts/test-only-symbols.allow:1: 'SeamHelper' has no reason"

put "${root}/app/scripts/test-only-symbols.allow" '# fine' 'SeamHelper #   '
run_check "${root}"
expect "an entry with an empty reason exits 2" 2 "${CODE}"
has "names the empty reason" "${ERR}" "'SeamHelper' has an empty reason"

put "${root}/app/scripts/test-only-symbols.allow" 'Seam Helper # two words'
run_check "${root}"
expect "an entry that is not one identifier exits 2" 2 "${CODE}"

# --- A missing allow-list file is the same as an empty one ---------------------
root="$(new_tree no-allow-file)"
rm "${root}/app/scripts/test-only-symbols.allow"
run_check "${root}"
expect "without an allow-list the seam is reported" 1 "${CODE}"
has "the seam is named" "${ERR}" ": SeamHelper is referenced only from app/Tests"

# --- Layout problems fail loudly rather than pass vacuously --------------------
root="$(new_tree no-tests-dir)"
rm -r "${root}/app/Tests"
run_check "${root}"
expect "a missing app/Tests exits 2" 2 "${CODE}"
has "names the missing directory" "${ERR}" "no app/Tests directory"

root="$(new_tree empty-tests)"
rm "${root}/app/Tests/DemoTests/UsedTests.swift"
run_check "${root}"
expect "an empty app/Tests exits 2" 2 "${CODE}"

run_check "${tmp_root}/does not exist"
expect "a missing repo root exits 2" 2 "${CODE}"

# --- Summary -------------------------------------------------------------------
total=$((passed + failed))
if ((failed > 0)); then
  printf '\ncheck-test-only-symbols: %d of %d checks failed\n' "$failed" "$total"
  exit 1
fi
printf 'check-test-only-symbols: all %d checks passed\n' "$total"
