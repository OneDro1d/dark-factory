#!/usr/bin/env bash
# test-mission-completeness-gate.sh — the Stop gate must fire, name the rule, and never
# block a turn.
#
# ⚠️ WHAT THIS SUITE CANNOT DO, said plainly so nobody reads a green run as more than it is:
# it cannot prove the model OBEYS the gate. It proves the prompt reaches the model and the
# hook is safe on the critical path. Obedience is measured in transcripts, not in tests —
# the same limit `test-binding-invokes-generics.sh` states about naming a skill versus
# loading it.
#
# The rule this guards was earned on 2026-09-02: four stop-shorts in one session, each
# defended with a TRUE statement. The rebuttals below are the exact excuses used, so a future
# edit that softens them fails here rather than passing quietly.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
T1="$(cd "$SELF/../../.." && pwd)"
HOOK="$T1/hooks/mission-completeness-gate.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

echo "=== A: present, and safe on the critical path ==="
if [ -f "$HOOK" ]; then ok "A: hook exists"; else bad "A: hook exists" "not found"; fi

if printf '{"session_id":"t","cwd":"/tmp"}' | python3 "$HOOK" >/dev/null 2>&1; then
  ok "A: exits 0 on a well-formed event"
else bad "A: exits 0 on a well-formed event" "non-zero exit would block the turn"; fi

if printf 'not json' | python3 "$HOOK" >/dev/null 2>&1; then
  ok "A: exits 0 on malformed stdin"
else bad "A: exits 0 on malformed stdin" "a Stop hook that errors blocks the turn"; fi

OUT="$(printf '{"session_id":"t"}' | python3 "$HOOK" 2>/dev/null)"

echo "=== B: stdout is a single valid JSON object the harness can read ==="
if printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ok "B: emits valid JSON"
else bad "B: emits valid JSON" "unparseable stdout breaks the turn"; fi

if printf '%s' "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d.get("systemMessage") and d["hookSpecificOutput"]["additionalContext"] else 1)
' 2>/dev/null; then
  ok "B: carries both systemMessage and additionalContext"
else bad "B: carries both output fields" "one channel may not reach the model"; fi

echo "=== C: the gate states the TEST, not a sentiment ==="
# "try harder" is not a gate. The operator-only categories are what make it decidable.
for needle in "OPERATOR-ONLY" "decision they have not made" "irreversible" \
              "credential" "blocked from" "dead end"; do
  case "$OUT" in *"$needle"*) ok "C: names '$needle'" ;;
    *) bad "C: names '$needle'" "the gate is not decidable without it" ;; esac
done

echo "=== D: the four excuses that earned this hook are rebutted BY NAME ==="
# ⚠️ Each of these is a TRUE statement that was used as a boundary. A future edit that drops
# one silently re-opens that exact door, which is why they are pinned individually.
for excuse in "separate repo" "deliberate decision" "pre-existing" "false positive" \
              "out of scope" "context is tight"; do
  case "$OUT" in *"$excuse"*) ok "D: rebuts '$excuse'" ;;
    *) bad "D: rebuts '$excuse'" "this excuse was used and is no longer named" ;; esac
done

case "$OUT" in
  *"true observation about scope is not a scope boundary"*)
    ok "D: states the rule itself" ;;
  *) bad "D: states the rule itself" "the one sentence the hook exists to carry" ;;
esac

echo "=== E: a fully-blocked mission has a clean ending ==="
# Without this the gate reads as 'never stop', which is paralysis wearing a rule's clothes.
case "$OUT" in *"That is a complete report"*) ok "E: names the legitimate stop" ;;
  *) bad "E: names the legitimate stop" "a gate with no exit teaches people to ignore it" ;;
esac

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
