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

echo "ASSERTIONS: $n"
exit $rc
