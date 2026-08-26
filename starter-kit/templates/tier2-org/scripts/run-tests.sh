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
# The three guarantees ARE carried over verbatim, because each one exists to stop a
# specific way a runner reports a false pass:
#
#   1. Enrolment is by the file EXISTING, never by a hand-written list. A list is the
#      thing that rots: Tier 1's workflow once named ONE suite while the repo shipped 22.
#   2. A naive `for f in …; do bash "$f"; done` exits with the LAST child's status, so a
#      suite failing early followed by a passing one exits 0. The status here is derived
#      from the TALLY.
#   3. A glob that matches nothing exits 0. Discovering zero suites is a HARD FAILURE,
#      not a pass — it means a broken checkout, a moved directory, or a gate wired up
#      before anything was written for it to run.
#
# Usage:
#   bash scripts/run-tests.sh              # run every suite under the repo root
#   bash scripts/run-tests.sh --root DIR   # run every suite under DIR
#   bash scripts/run-tests.sh --root=DIR   # same, `=` form
#   bash scripts/run-tests.sh --list       # print what WOULD run, run nothing
#
# Exit: 0 = every discovered suite passed. 1 = at least one failed. 2 = usage error, or
# no suites discovered.
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
FAILED_NAMES=""

while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  rel="${suite#$ROOT/}"
  start=$(date +%s)
  if bash "$suite" >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  elapsed=$(( $(date +%s) - start ))
  if [ "$rc" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    printf 'PASS  %3ss  %s\n' "$elapsed" "$rel"
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES="$FAILED_NAMES$rel (rc=$rc)
"
    printf 'FAIL  %3ss  %s  rc=%s\n' "$elapsed" "$rel" "$rc"
  fi
done <<EOF
$SUITES
EOF

echo
echo "=== $PASSED passed, $FAILED failed, of $COUNT discovered ==="

# The exit status is derived from the tally, never from the last child. A run where suite
# 1 fails and suite 5 passes must not exit 0.
if [ "$FAILED" -gt 0 ]; then
  echo
  echo "Failing suites:"
  printf '%s' "$FAILED_NAMES"
  exit 1
fi
exit 0
