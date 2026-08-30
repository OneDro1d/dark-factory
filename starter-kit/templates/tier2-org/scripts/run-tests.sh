#!/usr/bin/env bash
# run-tests.sh — run EVERY test suite in this org layer, discovered by existence.
#
# WHY THIS EXISTS. This repo is the Tier 2 org layer: `org.lock.json` is the single
# register that decides what every minted OneDroid Tier 3 instance installs, and
# `scripts/new-instance.sh` stamps `templates/tier3-instance/` out verbatim. A defect
# landed here reaches the whole fleet on the next mint. Until now the repo had no
# `.github/` at all — no workflow, no runner, nothing. Its correctness was maintained by
# a human remembering to run a script, which is the same silent-decay defect this
# estate keeps finding at every other tier.
#
# WHY THIS IS NOT A BYTE-COPY OF TIER 1's RUNNER, and that difference is load-bearing.
# Tier 1 ships the same three guarantees in `boot-kit/scripts/run-tests.sh`, and the
# estate's convention is to promote a working tool rather than reinvent it. Two things
# make a byte-identical copy WRONG here, and both fail silently:
#
#   1. DEPTH. Tier 1's runner sits at `boot-kit/scripts/` and computes
#      `ROOT="$HERE/../.."`. This one sits at `scripts/`, one level shallower. Copied
#      verbatim, ROOT would be the PARENT of this checkout — discovery would sweep
#      whatever else lives beside the repo and report on it with a confident verdict.
#   2. There is no `boot-kit/` in an org layer at all, so the path a copy would be
#      fetched from does not exist here.
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
# ⚠️ GUARANTEE 4 ARRIVED LATE, AND HOW IT ARRIVED IS THE POINT. Tier 1 added it in its own
# runner (PR #35) and this template was not updated — so every org layer minted in the
# interval was born one guarantee behind its parent, unable to tell a dead suite from a
# passing one, and the live reference layer was still in that state on 2026-08-30. The
# prose above used to read "the three guarantees", a fixed count in a comment, which is
# the same rot as the hand-maintained suite list guarantee 1 exists to abolish: nothing
# connected Tier 1 gaining a fourth to this file needing it. If you add a fifth upstream,
# it belongs here in the same change — a generator that lags its parent ships the lag to
# every consumer it stamps out.
#
# Usage:
#   bash scripts/run-tests.sh              # run every suite under the repo root
#   bash scripts/run-tests.sh --root DIR   # run every suite under DIR
#   bash scripts/run-tests.sh --root=DIR   # same, `=` form
#   bash scripts/run-tests.sh --list       # print what WOULD run, run nothing
#
# Exit: 0 = every discovered suite passed AND declared a positive assertion count.
# 1 = at least one suite failed, was UNMEASURED, or was VACUOUS. 2 = usage error, or no
# suites discovered.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
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
SUITES="$(find "$ROOT" \
  \( -name .git -o -name vendor -o -name node_modules -o -name .venv -o -name __pycache__ \) -prune \
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
