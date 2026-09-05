#!/usr/bin/env bash
# test-dispatch-gate.sh — dispatch-gate.py must DENY a sub-agent dispatch that carries no
# PROMISE / EVIDENCE / BOUND, and abstain ({}) on everything else so other gates still run.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
GATE="$SELF/../hooks/dispatch-gate.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }

run() { printf '%s' "$1" | python3 "$GATE"; }

echo "=== PROBE 1: a promise-less dispatch is DENIED, not merely advised ==="
O="$(printf '{"session_id":"probe","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"fix","prompt":"go fix the bug"}}' | python3 "$GATE")"; rc=$?
contains "PROBE1: carries permissionDecision" '"permissionDecision"' "$O"
contains "PROBE1: the decision is deny"        '"permissionDecision": "deny"' "$O"
if [ "$rc" -eq 0 ]; then ok "PROBE1: exits 0 (JSON communicates the decision)"
else bad "PROBE1: exits 0" "exit was $rc"; fi

echo "=== well-formed brief: all three clauses present -> abstain ==="
WELLFORMED='{"session_id":"p","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"fix","prompt":"## PROMISE\nFix the failing test and make it pass.\n\n## UNFORGEABLE EVIDENCE\nReturn the pytest exit code and the file plugins/df-governed/tests/test-dispatch-gate.sh.\n\n## Bounds\nOnly under plugins/df-governed/. Do NOT touch other files. max-turns 10.\n"}}'
O="$(run "$WELLFORMED")"
if [ "$O" = "{}" ]; then ok "well-formed: output is exactly {}"
else bad "well-formed: output is exactly {}" "got: $O"; fi

echo "=== each clause missing alone -> deny, reason names that clause ==="
NO_PROMISE='{"tool_name":"Task","tool_input":{"prompt":"## UNFORGEABLE EVIDENCE\nReturn the exit code and path plugins/x/y.py\n\n## Bounds\nBudget: 5 tool calls.\n"}}'
O="$(run "$NO_PROMISE")"
contains "no PROMISE: denies"           '"permissionDecision": "deny"' "$O"
contains "no PROMISE: names PROMISE"    "PROMISE" "$O"

NO_EVIDENCE='{"tool_name":"Task","tool_input":{"prompt":"## PROMISE\nFix the bug and return the result.\n\n## Bounds\nBudget: 5 tool calls.\n"}}'
O="$(run "$NO_EVIDENCE")"
contains "no EVIDENCE: denies"          '"permissionDecision": "deny"' "$O"
contains "no EVIDENCE: names EVIDENCE"  "EVIDENCE" "$O"

NO_ARTIFACT='{"tool_name":"Task","tool_input":{"prompt":"## PROMISE\nFix the bug and return the result.\n\n## UNFORGEABLE EVIDENCE\nJust tell me it works.\n\n## Bounds\nBudget: 5 tool calls.\n"}}'
O="$(run "$NO_ARTIFACT")"
contains "EVIDENCE with no artifact ref: denies"        '"permissionDecision": "deny"' "$O"
contains "EVIDENCE with no artifact ref: names EVIDENCE" "EVIDENCE" "$O"

NO_BOUND='{"tool_name":"Task","tool_input":{"prompt":"## PROMISE\nFix the bug and return the result.\n\n## UNFORGEABLE EVIDENCE\nReturn the exit code and path plugins/x/y.py\n"}}'
O="$(run "$NO_BOUND")"
contains "no BOUND: denies"             '"permissionDecision": "deny"' "$O"
contains "no BOUND: names Bound"        "BOUND" "$O"

echo "=== malformed JSON on stdin -> deny with internal error ==="
O="$(printf 'not json at all' | python3 "$GATE")"; rc=$?
contains "malformed JSON: denies"        '"permissionDecision": "deny"' "$O"
contains "malformed JSON: names internal error" "internal error" "$O"
if [ "$rc" -eq 0 ]; then ok "malformed JSON: exits 0"; else bad "malformed JSON: exits 0" "exit was $rc"; fi

echo "=== missing tool_input on an Agent dispatch -> deny with internal error ==="
O="$(printf '{"tool_name":"Agent"}' | python3 "$GATE")"
contains "missing tool_input: denies"           '"permissionDecision": "deny"' "$O"
contains "missing tool_input: names internal error" "internal error" "$O"

echo "=== tool_name Bash -> abstain, this gate is not for it ==="
O="$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | python3 "$GATE")"
if [ "$O" = "{}" ]; then ok "Bash: output is exactly {}"
else bad "Bash: output is exactly {}" "got: $O"; fi

echo "=== tool_name entirely absent -> deny with internal error (fails CLOSED) ==="
O="$(printf '{"tool_input":{"prompt":"x"}}' | python3 "$GATE")"
contains "no tool_name: denies"           '"permissionDecision": "deny"' "$O"
contains "no tool_name: names internal error" "internal error" "$O"

echo ""
echo "=== inline PROMISE: label (research-brief shape) -> abstain, not a false deny ==="
INLINE='{"session_id":"p","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"r","prompt":"Research ticket. PROMISE: return the doc URL and a verbatim quote for each claim.\nEvidence: URLs and quotes, verbatim, plus the exit code of each probe.\nScope: read-only, write nothing outside your scratch dir."}}'
O="$(run "$INLINE")"
if [ "$O" = "{}" ]; then ok "inline PROMISE: abstains"; else bad "inline PROMISE: abstains" "got: $O"; fi

echo "=== the word promise mid-sentence with no label -> still denied ==="
MID='{"session_id":"p","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"r","prompt":"I promise this is fine. Evidence: exit code. Scope: anything."}}'
O="$(run "$MID")"
contains "mid-sentence promise without label: deny" '"permissionDecision": "deny"' "$O"

printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
