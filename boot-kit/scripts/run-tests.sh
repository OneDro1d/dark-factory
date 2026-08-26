#!/usr/bin/env bash
# run-tests.sh — run EVERY test suite in the repo, discovered by existence.
#
# WHY THIS EXISTS. Until now `.github/workflows/gate.yml` named exactly one suite from
# `boot-kit/scripts/tests/` (`test-p8-reachability.sh`). The repo ships two dozen suites
# across four directories — the exact number is deliberately not written down here, since
# a count in prose is the same rotting hand-written list in miniature, and this one was
# already wrong (22) by the time it was read. All but that one executed only when a human
# typed the path, so their
# correctness was maintained by someone remembering to — and nothing would have said so
# if one of them had started failing. That is the same defect this repo's own missions
# keep finding elsewhere: a check that decays silently and looks green because absence
# has no signal.
#
# The fix is not "add the missing suites to the workflow". A hand-written list is the
# thing that rots: the ticket that filed this finding enumerated the suites BY HAND and
# its list was already wrong — it omitted `test-skill-frontmatter.sh`, which is on main,
# and counted a suite that only exists in an unmerged PR. Enrolment must be a property of
# the file EXISTING, not of anyone remembering. So this runner globs, and a new suite is
# enrolled the moment it is committed.
#
# Two failure modes this deliberately guards against, because both would restore the
# original defect while looking like a fix:
#
#   1. A naive `for f in …; do bash "$f"; done` exits with the LAST child's status. One
#      suite failing early then a passing suite after it exits 0. Every failure is
#      recorded and the exit status is derived from the total, never from the last child.
#   2. A glob that matches nothing exits 0. "No suites found" is a broken checkout or a
#      moved directory, not a pass — discovering zero suites is a hard failure.
#
# THE ASSERTION-COUNT CONTRACT. Exit status alone cannot tell "asserted 44 things" from
# "asserted nothing" — both exit 0, and until this was added both rendered as `PASS 0s`.
# That is the same defect one level down from the one above: a suite whose glob stops
# matching, whose fixture directory moves, or whose assertions get commented out during a
# debug session keeps reporting PASS forever, because a proxy for having-been-checked
# decays without a signal.
#
# So every suite must print a line
#
#     ASSERTIONS: <n>
#
# where <n> is how many assertions it actually executed, and this runner reads it:
#
#   * no such line          -> UNMEASURED — counted as a failure, not a pass.
#   * `ASSERTIONS: 0`       -> VACUOUS    — counted as a failure. Kept distinct from
#                              UNMEASURED because the repairs differ: UNMEASURED means
#                              the suite has not adopted the contract, VACUOUS means its
#                              assertions stopped executing.
#   * several such lines    -> the LAST wins. A suite that drives sub-suites prints one
#                              per child; the last is its own total.
#
# DECLARED, not parsed, and that is the whole design. The suites in this repo print their
# totals in six different formats — `N passed, 0 failed`, `=== N passed …`,
# `forward : N assertions passed …`, `RESULT: PASS — 9/9 cases behave (9 asserted)`,
# `passed: 14   failed: 0`, `4/4 classes behave`. A runner that greps for a count is a
# hand-written list of FORMATS, which rots exactly like the hand-written list of SUITES
# this runner's glob replaced. The suite declares; the runner does not guess.
#
# Scope note: `landmarks.conf` is gitignored, so the six landmark-reading suites exercise
# fewer pattern branches in CI than they do on a maintainer's machine. They still run and
# still pass there; the gate workflow reports which config was used. A green run here is
# "no suite regressed under the configuration available", not "the branch is landmark-free".
#
# Usage:
#   bash boot-kit/scripts/run-tests.sh              # run every suite under the repo root
#   bash boot-kit/scripts/run-tests.sh --root DIR   # run every suite under DIR
#   bash boot-kit/scripts/run-tests.sh --root=DIR   # same, `=` form
#   bash boot-kit/scripts/run-tests.sh --list       # print what WOULD run, run nothing
#
# Exit: 0 = every discovered suite passed AND declared a positive assertion count.
# 1 = at least one suite failed, was UNMEASURED, or was VACUOUS. 2 = usage error, or no
# suites discovered.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIST_ONLY=0

# Both `--root DIR` and `--root=DIR` are accepted, and anything unrecognised exits 2
# rather than being ignored. A flag parser that reads only `$1`, or only one spelling,
# silently runs against the wrong tree and prints a confident verdict about it.
while [ $# -gt 0 ]; do
  case "$1" in
    --root)   [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "run-tests: --root needs a path" >&2; exit 2; }
              ROOT="$2"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"
              [ -n "$ROOT" ] || { echo "run-tests: --root needs a path" >&2; exit 2; }
              shift ;;
    --list)   LIST_ONLY=1; shift ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)        echo "run-tests: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -d "$ROOT" ] || { echo "run-tests: not a directory: $ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"

# RE-ENTRANCY. This runner discovers `test-*.sh`, and one of them is the suite that tests
# this runner — so a suite invoking it WITHOUT `--root` re-enters it on a tree containing
# itself, and the run never terminates. That is not hypothetical: it is how the first
# ablation of the unknown-argument arm behaved, because an ignored flag makes discovery
# fall back to the repo root. Nesting is legitimate (the runner's own suite drives it over
# scratch trees); nesting onto a tree that CONTAINS this file is not.
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
if [ -n "${RUN_TESTS_ACTIVE:-}" ]; then
  case "$SELF" in
    "$ROOT"/*) echo "run-tests: refusing to re-enter — $ROOT contains this runner." >&2
               echo "run-tests: a suite that drives this runner must pass --root." >&2
               exit 2 ;;
  esac
fi
export RUN_TESTS_ACTIVE=1

# Prune the generated and vendored trees. `vendor/` is a per-instance cache that can hold
# a COPY of these very suites; running those would report on the cache, not on this repo.
SUITES="$(find "$ROOT" \
  \( -name .git -o -name vendor -o -name node_modules -o -name .venv -o -name __pycache__ \) -prune \
  -o -type f -name 'test-*.sh' -print | LC_ALL=C sort)"

COUNT=0
[ -n "$SUITES" ] && COUNT=$(printf '%s\n' "$SUITES" | wc -l | tr -d ' ')

if [ "$COUNT" -eq 0 ]; then
  echo "run-tests: discovered 0 suites under $ROOT" >&2
  echo "run-tests: that is a broken checkout or a moved directory, not a pass." >&2
  exit 2
fi

echo "run-tests: discovered $COUNT suites under $ROOT"
if [ "$LIST_ONLY" -eq 1 ]; then
  printf '%s\n' "$SUITES" | sed "s#^$ROOT/##"
  exit 0
fi
echo

PASSED=0
FAILED=0
ASSERTIONS=0
FAILED_NAMES=""

# The child's output is CAPTURED rather than discarded, because the assertion count is in
# it. It is still not echoed on a pass — a green run stays one line per suite, and a
# reader who wants the detail re-runs that one suite. On a failure the tail is shown,
# since the old behaviour (discard everything, print `rc=1`) made every failure a second
# command before you learned anything.
CAP="$(mktemp "${TMPDIR:-/tmp}/run-tests.XXXXXX")"
trap 'rm -f "$CAP"' EXIT

# `while read` in a subshell would lose the counters, so feed the loop from a here-string.
while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  rel="${suite#$ROOT/}"
  start=$(date +%s)
  if bash "$suite" >"$CAP" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  elapsed=$(( $(date +%s) - start ))

  # LAST match wins — a suite that drives sub-suites prints one line per child, and its
  # own total is the last one. `10#` forces base 10, so a suite printing `ASSERTIONS: 08`
  # is not an octal error inside `[ … -eq … ]`, which would read as a runner bug.
  n="$(grep -Eo '^[[:space:]]*ASSERTIONS:[[:space:]]*[0-9]+[[:space:]]*$' "$CAP" \
       | tail -1 | tr -cd '0-9')"
  [ -n "$n" ] && n=$((10#$n))

  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    FAILED_NAMES="$FAILED_NAMES$rel (rc=$rc)
"
    printf 'FAIL  %3ss  %s  rc=%s\n' "$elapsed" "$rel" "$rc"
    tail -5 "$CAP" | sed 's/^/          | /'
  elif [ -z "$n" ]; then
    # Exited 0 and told us nothing. This is the state the whole contract exists for: it
    # is indistinguishable from a pass by exit status, so it must not be scored as one.
    FAILED=$((FAILED + 1))
    FAILED_NAMES="$FAILED_NAMES$rel (UNMEASURED — exited 0 but printed no 'ASSERTIONS: <n>' line)
"
    printf 'UNMEASURED  %3ss  %s  — exited 0 but declared no assertion count\n' "$elapsed" "$rel"
  elif [ "$n" -eq 0 ]; then
    FAILED=$((FAILED + 1))
    FAILED_NAMES="$FAILED_NAMES$rel (VACUOUS — declared 0 assertions)
"
    printf 'VACUOUS     %3ss  %s  — declared 0 assertions\n' "$elapsed" "$rel"
  else
    PASSED=$((PASSED + 1))
    ASSERTIONS=$((ASSERTIONS + n))
    printf 'PASS  %3ss  %s  (%s assertions)\n' "$elapsed" "$rel" "$n"
  fi
done <<EOF
$SUITES
EOF

echo
echo "=== $PASSED passed ($ASSERTIONS assertions), $FAILED failed, of $COUNT discovered ==="

# The exit status is derived from the tally, never from the last child. A run where suite
# 1 fails and suite 22 passes must not exit 0.
if [ "$FAILED" -gt 0 ]; then
  echo
  echo "Failing suites:"
  printf '%s' "$FAILED_NAMES"
  echo
  echo "Re-run one directly to see its output:  bash <path>"
  echo "UNMEASURED means the suite must print 'ASSERTIONS: <n>' — see the header of this runner."
  exit 1
fi
exit 0
