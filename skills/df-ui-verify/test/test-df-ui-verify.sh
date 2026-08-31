#!/usr/bin/env bash
# test-df-ui-verify.sh — the entry point run-tests.sh discovers.
#
# WHY THIS FILE EXISTS, AND WHY IT IS NAMED WITH A HYPHEN.
# The upstream suite this skill was promoted from used `run-tests.sh` over three
# `test_*.sh` units. Tier 1's runner discovers `test-*.sh` — hyphen — so copied verbatim
# this suite would have been discovered ZERO times and CI would have stayed green while
# running none of it. That is the same class of defect as a suite with no assertions:
# testing that reports nothing. The units keep their underscore names precisely so they
# are NOT double-discovered; this file is the single discovered entry point.
#
# ASSERTIONS. The runner treats a suite that exits 0 without printing `ASSERTIONS: <n>`
# as UNMEASURED, and `ASSERTIONS: 0` as VACUOUS. Both count as failures. So the total
# below is SUMMED FROM THE UNITS AT RUN TIME — each unit counts its own assertions and
# prints its own line. It is deliberately not a constant: a fixed count written in one
# place and asserted in another is how a suite silently stops testing what it claims,
# and this repo has already paid for that once.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

rc=0
total=0
units=0

for t in "$HERE"/test_*.sh; do
  [ -e "$t" ] || continue
  units=$((units + 1))
  echo "== $(basename "$t") =="
  out="$(bash "$t" 2>&1)" || rc=1
  printf '%s\n' "$out"
  n="$(printf '%s\n' "$out" \
       | grep -Eo '^[[:space:]]*ASSERTIONS:[[:space:]]*[0-9]+[[:space:]]*$' \
       | tail -1 | tr -dc '0-9')"
  if [ -z "$n" ]; then
    echo "FAIL: $(basename "$t") printed no ASSERTIONS line — unmeasured, not passing"
    rc=1
    continue
  fi
  total=$((total + 10#$n))
done

# Zero units is a moved or broken directory, not a pass — the same rule the repo runner
# applies to zero suites.
if [ "$units" -eq 0 ]; then
  echo "FAIL: discovered 0 units under $HERE — broken checkout, not a pass"
  rc=1
fi

echo "ASSERTIONS: $total"
if [ "$rc" -eq 0 ]; then echo "ALL TESTS PASS"; else echo "SOME TESTS FAILED"; fi
exit $rc
