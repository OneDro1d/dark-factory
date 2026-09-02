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

# ⚠️ HERMETIC OR IT IS NOT A TEST. The hook remembers, per session, that it has already fired
# — via a marker under TMPDIR. Without an isolated TMPDIR that marker OUTLIVES THE TEST RUN,
# so the second execution of this suite reads the brief form where it expects the full one and
# cases C/D/E fail for a reason that has nothing to do with the code. Caught on the first
# re-run; it is the same ambient-state defect this repo hit twice today, once in a suite that
# resolved its subject from cwd and once in a discovery pass that counted only tracked files.
TMPDIR="$(mktemp -d)"
export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== A: present, and safe on the critical path ==="
if [ -f "$HOOK" ]; then ok "A: hook exists"; else bad "A: hook exists" "not found"; fi

if printf '{"session_id":"t","cwd":"/tmp"}' | python3 "$HOOK" >/dev/null 2>&1; then
  ok "A: exits 0 on a well-formed event"
else bad "A: exits 0 on a well-formed event" "non-zero exit would block the turn"; fi

if printf 'not json' | python3 "$HOOK" >/dev/null 2>&1; then
  ok "A: exits 0 on malformed stdin"
else bad "A: exits 0 on malformed stdin" "a Stop hook that errors blocks the turn"; fi

# ⚠️ A FRESH SESSION ID, because case A above already spent session "t"'s first firing and
# the hook is quiet on repeats. Reusing an id across cases makes every later assertion read
# the brief form and fail for a reason unrelated to what it is testing.
OUT="$(printf '{"session_id":"full-form-case"}' | python3 "$HOOK" 2>/dev/null)"

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

echo "=== F: full text once per session, brief reminder after ==="
# ⚠️ A gate that repeats a full screen of rules over an unchanged answer is the
# seven-no-change-tick failure arriving through a Stop hook. Measured on the day it shipped:
# five firings, the last three re-deriving an identical settled list. The guard must survive;
# the wall of text must not.
SID="gatetest-$$"
F1="$(printf '{"session_id":"%s"}' "$SID" | python3 "$HOOK" 2>/dev/null)"
F2="$(printf '{"session_id":"%s"}' "$SID" | python3 "$HOOK" 2>/dev/null)"

case "$F1" in *"OPERATOR-ONLY"*) ok "F: first firing carries the full gate" ;;
  *) bad "F: first firing carries the full gate" "the full rules must appear once" ;; esac

if [ "${#F2}" -lt "${#F1}" ]; then ok "F: second firing is shorter"
else bad "F: second firing is shorter" "repeating the wall of text trains skimming"; fi

# ...but it must still DEMAND the check, or going quiet becomes going away.
case "$F2" in *"OPERATOR-ONLY"*) ok "F: the brief form still demands a blocker" ;;
  *) bad "F: the brief form still demands a blocker" "quiet must not mean silent" ;; esac
case "$F2" in *"yours"*) ok "F: the brief form keeps the ownership rule" ;;
  *) bad "F: the brief form keeps the ownership rule" "the one sentence that decides" ;; esac

# A DIFFERENT session is a different mission and gets the full text again.
F3="$(printf '{"session_id":"other-%s"}' "$SID" | python3 "$HOOK" 2>/dev/null)"
case "$F3" in *"OPERATOR-ONLY blocker"*) ok "F: a new session gets the full gate" ;;
  *) bad "F: a new session gets the full gate" "the marker leaked across sessions" ;; esac

# ⚠️ FAIL TOWARD PROMPTING. A missing session_id means the hook cannot tell whether it has
# fired, and a missed reminder is worse than a repeated one.
F5="$(printf '{}' | python3 "$HOOK" 2>/dev/null)"
case "$F5" in *"OPERATOR-ONLY blocker"*) ok "F: no session_id still gets the full gate" ;;
  *) bad "F: no session_id still gets the full gate" "an absent id must not mean already-fired" ;; esac

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
