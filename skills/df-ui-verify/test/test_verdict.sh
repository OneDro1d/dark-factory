#!/usr/bin/env bash
# Unit: verdict.sh — PASS / CONDITIONAL / FAIL from captured evidence.
# Entry point is test-df-ui-verify.sh, which sums the ASSERTIONS line below.
#
# The fourth case is the one that matters most: an empty evidence dir must be FAIL, not
# PASS. "Nothing went wrong" and "nothing was looked at" are the same bytes, and only one
# of them is a pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VERDICT="$HERE/../scripts/verdict.sh"

fail=0
n=0
eq() {
  n=$((n + 1))
  if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (got $1)"; fail=1; fi
}

d="$(mktemp -d)"; cp "$HERE/fixtures/network_pass.json" "$d/network.json"; : > "$d/console.txt"
eq "$(bash "$VERDICT" "$d" 2>/dev/null)" "PASS" "all 200 + clean console -> PASS"

d="$(mktemp -d)"; cp "$HERE/fixtures/network_fail.json" "$d/network.json"; : > "$d/console.txt"
eq "$(bash "$VERDICT" "$d" 2>/dev/null)" "FAIL" "a 500 -> FAIL"

d="$(mktemp -d)"; cp "$HERE/fixtures/network_pass.json" "$d/network.json"; cp "$HERE/fixtures/network_conditional_console.txt" "$d/console.txt"
eq "$(bash "$VERDICT" "$d" 2>/dev/null)" "CONDITIONAL" "200s + known-harmless console noise -> CONDITIONAL"

d="$(mktemp -d)"
eq "$(bash "$VERDICT" "$d" 2>/dev/null)" "FAIL" "no network.json -> FAIL (no evidence is not a pass)"

echo "ASSERTIONS: $n"
exit $fail
