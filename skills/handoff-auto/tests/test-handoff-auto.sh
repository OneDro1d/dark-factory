#!/usr/bin/env bash
# test-handoff-auto.sh — the entry point boot-kit/scripts/run-tests.sh discovers.
#
# WHY THIS FILE EXISTS. Same reason as the agent-notepad one beside it: this directory held
# five `test_*.sh` units behind a `run.sh` orchestrator, and the repo runner discovers
# `test-*.sh`. None of it had ever run in CI. Among the units is `test_redact.sh`, which is the
# only executable check on a hardened secret redactor that exists in TWO forked copies in this
# repo — so the one test that would notice the redactor breaking was itself unreachable.
#
# ⚠️ This skill is SUPERSEDED by agent-notepad and its installer unwires it. It is still
# shipped so existing installs do not break, so its tests still have to run: a superseded skill
# that is still installed is still a skill, and "we are removing it eventually" has never once
# stopped a defect from shipping.
#
# ASSERTIONS parsed at run time from the orchestrator's own per-file "N cases:" lines, never
# hardcoded. A failed parse fails the suite rather than reporting an unmeasured number.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

out="$(bash "$HERE/run.sh" 2>&1)"
rc=$?
printf '%s\n' "$out"

total=0
found=0
while read -r n; do
  [ -n "$n" ] || continue
  found=1
  total=$((total + n))
done <<EOF
$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) cases:.*/\1/p')
EOF

if [ "$found" -eq 0 ]; then
  echo "FAIL: could not parse any 'N cases:' line from run.sh output"
  echo "      the orchestrator's summary format changed — fix this parse, do not guess a count"
  exit 1
fi

echo "ASSERTIONS: $total"
exit $rc
