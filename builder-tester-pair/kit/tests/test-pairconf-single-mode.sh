#!/usr/bin/env bash
# test-pairconf-single-mode.sh — CI entry for the single-workspace namespace check (review of #230).
# boot-kit/scripts/run-tests.sh discovers test-*.sh and requires a declared `ASSERTIONS: <n>` line; this runs the Python
# unittest file next to it and declares how many tests actually RAN (skips are not counted as assertions).
# The fixtures are JSON, so the suite behaves the same with and without PyYAML installed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(python3 -I "$HERE/test_pairconf_single_mode.py" -v 2>&1)"; RC=$?
printf '%s\n' "$OUT"
RAN="$(printf '%s\n' "$OUT" | sed -n 's/^Ran \([0-9]*\) test.*/\1/p' | tail -1)"
SKIPPED="$(printf '%s\n' "$OUT" | grep -c ' \.\.\. skipped')"
N=$(( ${RAN:-0} - SKIPPED ))
echo "ASSERTIONS: $N"
[ "$RC" -eq 0 ] || exit 1
[ "$N" -gt 0 ] || { echo "no test actually ran" >&2; exit 1; }
