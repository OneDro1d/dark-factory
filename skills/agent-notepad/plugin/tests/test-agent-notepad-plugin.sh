#!/usr/bin/env bash
# test-agent-notepad-plugin.sh — the entry point boot-kit/scripts/run-tests.sh discovers.
#
# WHY THIS FILE EXISTS.
# This directory holds nine `test_*.sh` files and a `run-tests.sh` orchestrator. The repo
# runner discovers `test-*.sh` — HYPHEN — so it matched none of them. 189 passing assertions,
# including the commit gate, packaging and the Stop hook, had never once run in CI, and CI was
# green the whole time. Same defect the df-ui-verify promotion hit on import, except these were
# already here.
#
# The units keep their underscore names deliberately: renaming them would make each one
# separately discovered, and they share fixtures and expect to be sequenced by the orchestrator.
# One discovered entry point, nine units beneath it.
#
# ASSERTIONS. The runner treats a suite that exits 0 without printing `ASSERTIONS: <n>` as
# UNMEASURED, and `ASSERTIONS: 0` as VACUOUS — both failures. The count below is PARSED from
# the orchestrator's own total at run time, never hardcoded. If the parse fails this suite
# fails loudly rather than reporting a number it did not measure: an unparsed total would print
# `ASSERTIONS: 0`, which the runner already rejects, but saying so here makes the reason legible.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

out="$(bash "$HERE/run-tests.sh" 2>&1)"
rc=$?
printf '%s\n' "$out"

# The orchestrator's own line: "RESULT: PASS  (189 passed, 0 failed)".
n="$(printf '%s\n' "$out" | sed -n 's/.*RESULT:.*(\([0-9][0-9]*\) passed.*/\1/p' | tail -1)"

if [ -z "$n" ]; then
  echo "FAIL: could not parse an assertion total from run-tests.sh output"
  echo "      the orchestrator's summary format changed — fix this parse, do not guess a count"
  exit 1
fi

# ⚠️ NAME THE FAILING UNIT LAST, WHERE TRUNCATION CANNOT REACH IT.
# The repo runner captures a suite's output and, on failure, prints only the TAIL. For a
# wrapper around nine units the tail is the orchestrator's grand summary — "188 passed, 1
# failed" — and the name of the unit that failed has already scrolled past. Measured in CI on
# 2026-08-31: the first time these nine ran anywhere but a laptop one of them failed, and the
# log said so without saying which. A failure report that does not identify the failure costs
# a whole CI round-trip to learn one word.
#
# So: re-scan the captured output and print the failing unit names AFTER the assertion count.
# The orchestrator delimits each unit with `----- <name> -----`, and every unit ends with a
# summary line carrying "<n> failed"; a non-zero one names its block.
if [ "$rc" -ne 0 ]; then
  echo
  echo "FAILING UNITS (named here because the parent runner prints only the tail):"
  printf '%s\n' "$out" | awk '
    /^----- /            { unit = $2; next }
    /^=+$/ || /^TOTAL:/  { unit = ""; next }   # the grand summary belongs to no unit
    {
      line = $0
      while (match(line, /[0-9]+ failed/)) {
        f = substr(line, RSTART, RLENGTH); sub(/ failed/, "", f)
        if (f + 0 > 0 && unit != "" && !seen[unit]++) print "  " unit "  (" f " failed)"
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
fi

echo "ASSERTIONS: $n"
exit $rc
