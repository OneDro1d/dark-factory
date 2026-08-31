#!/usr/bin/env bash
# run-tests.sh — run EVERY test suite in this instance, discovered by existence.
#
# WHY THIS EXISTS. A Tier-3 instance is the record of ONE machine: a lockfile plus the
# config that decides what actually gets installed there. It is the last tier before a
# real environment, and it was the ONLY tier in the estate with no runner and no
# `.github/` — measured 2026-08-31. Tier 1 fixed that for itself, then Tier 2 got the same
# treatment, and Tier 3 was left behind twice.
#
# ⚠️ THE SHAPE OF THE GAP, because it is worse than "no tests". The reference instance in the
# estate this method came from SHIPS a suite under `boot-kit/tests/` and has no runner and no
# workflow, so it executes only when a human types the path. Somebody wrote a check that
# nothing runs. That is not an absence of testing; it is testing that reports nothing, which
# is the failure mode this estate keeps paying for at every tier.
#
# WHY THIS IS NOT A BYTE-COPY OF THE TIER-2 RUNNER, and the difference fails silently.
# The guarantees below are carried over deliberately, but DEPTH is not portable between
# tiers. The Tier-2 copy sits at `scripts/` and computes `ROOT="$HERE/.."`. This one sits at
# `boot-kit/scripts/`, matching where a live instance keeps its tooling — so it needs
# `$HERE/../..`. Copy that line across without thinking and ROOT lands on `boot-kit/`:
# discovery sweeps a fraction of the repo and prints a confident verdict about the whole of
# it. The Tier-2 header names depth as the first reason it is not a byte-copy of Tier 1's;
# this is the same hazard one tier further down.
#
# The guarantees ARE carried over verbatim, because each one exists to stop a specific way
# a runner reports a false pass:
#
#   1. Enrolment is by the file EXISTING, never by a hand-written list. A list is the
#      thing that rots: Tier 1's workflow once named ONE suite while the repo shipped 22.
#   2. A naive `for f in …; do bash "$f"; done` exits with the LAST child's status, so a
#      suite failing early followed by a passing one exits 0. The status here is derived
#      from the TALLY.
#   3. A glob that matches nothing exits 0. Discovering zero suites is a HARD FAILURE,
#      not a pass — it means a broken checkout, a moved directory, or a gate wired up
#      before anything was written for it to run.
#   4. THE ASSERTION-COUNT CONTRACT. Exit status cannot tell "asserted 44 things" from
#      "asserted nothing" — both exit 0. Every suite must print `ASSERTIONS: <n>` as its
#      last word on the subject, and this runner reads it:
#        * no such line     -> UNMEASURED, counted as a FAILURE. The suite has not
#                              adopted the contract, so its green means nothing.
#        * `ASSERTIONS: 0`  -> VACUOUS, counted as a FAILURE. Distinct from UNMEASURED
#                              because the repair differs: this one HAS the contract and
#                              its assertions stopped executing.
#      Consequence for the child call: output is CAPTURED, not discarded, because the
#      count is in it. A pass still prints one line; a failure now shows the tail.
#
# ⚠️ GUARANTEE 4 ARRIVED LATE UPSTREAM, AND THIS FILE IS THE THIRD COPY OF THAT LESSON.
# Tier 1 added the assertion-count contract in its own runner (PR #35); the Tier-2 template
# was not updated for weeks, so every layer minted in the interval was born unable to tell a
# dead suite from a passing one. It arrives here already complete only because that was
# caught first. Whoever adds a FIFTH guarantee upstream must land it in all three copies in
# the same change: a generator that lags its parent ships the lag to every consumer it
# stamps out, and there is now a tier of consumers below this one.
#
# Usage:
#   bash boot-kit/scripts/run-tests.sh              # every suite under the repo root
#   bash boot-kit/scripts/run-tests.sh --root DIR   # every suite under DIR
#   bash boot-kit/scripts/run-tests.sh --root=DIR   # same, `=` form
#   bash boot-kit/scripts/run-tests.sh --list       # print what WOULD run, run nothing
#
# Exit: 0 = every discovered suite passed AND declared a positive assertion count.
# 1 = at least one suite failed, was UNMEASURED, or was VACUOUS. 2 = usage error, or no
# suites discovered.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"   # boot-kit/scripts/ -> repo root. TWO levels; see header.
LIST_ONLY=0

# Both `--root DIR` and `--root=DIR` are accepted, and anything unrecognised exits 2
# rather than being ignored. A parser that reads only one spelling silently runs against
# the wrong tree and prints a confident verdict about it — measured twice in this estate.
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

# RE-ENTRANCY. This runner discovers `test-*.sh`, and a suite may legitimately drive it
# over a scratch tree. Nesting onto a tree that CONTAINS this file would never terminate.
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
if [ -n "${RUN_TESTS_ACTIVE:-}" ]; then
  case "$SELF" in
    "$ROOT"/*) echo "run-tests: refusing to re-enter — $ROOT contains this runner." >&2
               echo "run-tests: a suite that drives this runner must pass --root." >&2
               exit 2 ;;
  esac
fi
export RUN_TESTS_ACTIVE=1

# Prune the generated and vendored trees. `vendor/` is a cache that can hold a COPY of
# these very suites; running those would report on the cache, not on this repo.
#
# ⚠️ `workers/` IS PRUNED HERE AND DELIBERATELY NOT IN THE TIER-2 COPY. The same directory
# name means opposite things at the two tiers, so keeping the three runners in lockstep on
# this line would be the wrong kind of consistency:
#   · in a TIER-3 INSTANCE it is worker SCRATCH — `workers/<role>/<session>/` holding whole
#     copies of other machines' kits. Measured on a live instance 2026-08-31: 16 suites
#     discovered, 15 of them scratch, every one UNMEASURED, gate red and saying nothing about
#     the repo it was gating.
#   · in a TIER-2 ORG LAYER it is SOURCE — `dispatch.sh`, `profiles.json`, `mcp/`. Pruning it
#     there would hide the code, and any future test of the dispatcher with it.
#
# ⚠️ The template could never have shown this: a template has no scratch, so the condition
# only exists once the thing is USED. A gate proven against a fixture is proven against the
# one state that cannot exhibit the bug.
SUITES="$(find "$ROOT" \
  \( -name .git -o -name vendor -o -name workers -o -name node_modules -o -name .venv -o -name __pycache__ \) -prune \
  -o -type f -name 'test-*.sh' -print | LC_ALL=C sort)"

COUNT=0
[ -n "$SUITES" ] && COUNT=$(printf '%s\n' "$SUITES" | wc -l | tr -d ' ')

if [ "$COUNT" -eq 0 ]; then
  echo "run-tests: discovered 0 suites under $ROOT" >&2
  echo "run-tests: that is a broken checkout or a gate with nothing to run, not a pass." >&2
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
# it (guarantee 4). It is still not echoed on a pass — a green run stays one line per
# suite. On a failure the tail is shown, since discarding everything and printing `rc=1`
# made every failure cost a second command before you learned anything.
CAP="$(mktemp "${TMPDIR:-/tmp}/run-tests.XXXXXX")"
trap 'rm -f "$CAP"' EXIT

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

  # LAST match wins — a suite that drives sub-suites prints one line per child and its own
  # total is the last. `10#` forces base 10 so `ASSERTIONS: 08` is not an octal error
  # inside `[ … -eq … ]`, which would read as a runner bug rather than a suite typo.
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
    # Exited 0 and told us nothing. This is the state the contract exists for: it is
    # indistinguishable from a pass by exit status, so it must not be scored as one.
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
# 1 fails and suite 5 passes must not exit 0.
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
