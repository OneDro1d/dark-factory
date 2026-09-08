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

# HERMETIC TO THE DISPATCH ENVIRONMENT. See lib/dispatch-env-scrub.sh: this hook reads
# CLAUDE_CODE_ENTRYPOINT directly (it releases the turn under "sdk-cli", the value a headless
# df-worker run carries), and every call below routes through scrub_dispatch_env so that a
# df-dispatched worker running THIS suite does not hand its own entrypoint to the hook under
# test.
# shellcheck source=boot-kit/scripts/tests/lib/dispatch-env-scrub.sh
source "$SELF/lib/dispatch-env-scrub.sh"

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

if printf '{"session_id":"t","cwd":"/tmp"}' | scrub_dispatch_env python3 "$HOOK" >/dev/null 2>&1; then
  ok "A: exits 0 on a well-formed event"
else bad "A: exits 0 on a well-formed event" "non-zero exit would block the turn"; fi

if printf 'not json' | scrub_dispatch_env python3 "$HOOK" >/dev/null 2>&1; then
  ok "A: exits 0 on malformed stdin"
else bad "A: exits 0 on malformed stdin" "a Stop hook that errors blocks the turn"; fi

# ⚠️ A FRESH SESSION ID, because case A above already spent session "t"'s first firing and
# the hook is quiet on repeats. Reusing an id across cases makes every later assertion read
# the brief form and fail for a reason unrelated to what it is testing.
OUT="$(printf '{"session_id":"full-form-case"}' | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"

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
F1="$(printf '{"session_id":"%s"}' "$SID" | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"
F2="$(printf '{"session_id":"%s"}' "$SID" | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"

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
F3="$(printf '{"session_id":"other-%s"}' "$SID" | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"
case "$F3" in *"OPERATOR-ONLY blocker"*) ok "F: a new session gets the full gate" ;;
  *) bad "F: a new session gets the full gate" "the marker leaked across sessions" ;; esac

# ⚠️ FAIL TOWARD PROMPTING. A missing session_id means the hook cannot tell whether it has
# fired, and a missed reminder is worse than a repeated one.
F5="$(printf '{}' | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"
case "$F5" in *"OPERATOR-ONLY blocker"*) ok "F: no session_id still gets the full gate" ;;
  *) bad "F: no session_id still gets the full gate" "an absent id must not mean already-fired" ;; esac

echo "=== G: it RELEASES the turn on re-entry ==="
# ⛔ THE DEFECT THIS HOOK SHIPPED WITH. Emitting anything from a Stop hook tells the harness
# the turn is not finished, so the model runs again -- and fires this hook again. Unbounded,
# until Claude Code force-ends it: "A hook blocked the turn from ending 9 consecutive times".
# It happened to this hook on the day it shipped.
#
# ⚠️ AND THE EARLIER "GO QUIET" CHANGE DID NOT FIX IT. That made the message SHORTER while it
# still BLOCKED. Verbosity was the symptom; never releasing the turn was the cause. Fixing the
# visible half of a defect is how the real half survives a fix that looks like it worked.
G1="$(printf '{"session_id":"reentry","stop_hook_active":true}' | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"
if [ -z "$G1" ]; then ok "G: emits NOTHING when stop_hook_active is true"
else bad "G: emits NOTHING when stop_hook_active is true" \
        "any output re-blocks the turn and loops to the harness cap"; fi

if printf '{"session_id":"reentry","stop_hook_active":true}' | scrub_dispatch_env python3 "$HOOK" >/dev/null 2>&1
then ok "G: still exits 0 on re-entry"
else bad "G: still exits 0 on re-entry" "a non-zero Stop hook blocks the turn"; fi

# ...and a normal firing must be unaffected, or the release swallowed the gate.
G2="$(printf '{"session_id":"normal-fire"}' | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"
case "$G2" in *"OPERATOR-ONLY"*) ok "G: a normal firing still carries the gate" ;;
  *) bad "G: a normal firing still carries the gate" "the release silenced the hook entirely" ;; esac

# an explicit false must behave like a normal firing, not like re-entry
G3="$(printf '{"session_id":"explicit-false","stop_hook_active":false}' \
        | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"
case "$G3" in *"OPERATOR-ONLY"*) ok "G: stop_hook_active=false fires normally" ;;
  *) bad "G: stop_hook_active=false fires normally" "treated an explicit false as re-entry" ;; esac

echo ""
echo "=== H: hermetic to the dispatch environment ==="
# ⛔ THE BUG THIS GUARDS. This hook reads CLAUDE_CODE_ENTRYPOINT directly and releases the turn
# (emits nothing) when it equals "sdk-cli" — the value a headless df-worker run carries (see
# the CLAUDE_CODE_ENTRYPOINT check above). A df-dispatched worker's OWN process therefore has
# CLAUDE_CODE_ENTRYPOINT=sdk-cli exported already, plus DF_TICKET/DF_SCRATCH/DF_MISSION/DF_ROLE/
# DF_MCP_MODE/DF_CLAIM_* from df-worker and WORKER_* from dispatch.sh. Before scrub_dispatch_env,
# every `python3 "$HOOK"` call above inherited that ambient CLAUDE_CODE_ENTRYPOINT verbatim, and
# since sdk-cli means "release", the hook emitted NOTHING for every case in this file — sections
# B through G all failed together, for a reason that has nothing to do with the gate itself. A
# maintainer running this suite by hand is always CLAUDE_CODE_ENTRYPOINT=cli (or unset) and
# never saw it; two workers independently called this "pre-existing, reproduces in isolation".
export CLAUDE_CODE_ENTRYPOINT=sdk-cli
export DF_TICKET=POISON DF_SCRATCH=/nonexistent/poison DF_MISSION=POISON DF_ROLE=POISON \
       DF_MCP_MODE=POISON DF_CLAIM_COLUMNS='{"poison":"poison"}' WORKER_REPO=/nonexistent/poison \
       WORKER_MODEL=POISON

H1="$(printf '{"session_id":"hermetic-%s"}' "$$" | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"
case "$H1" in
  *"OPERATOR-ONLY"*) ok "H: the gate still fires despite a poisoned ambient CLAUDE_CODE_ENTRYPOINT/DF_*/WORKER_* environment" ;;
  *) bad "H: the gate still fires despite a poisoned ambient CLAUDE_CODE_ENTRYPOINT/DF_*/WORKER_* environment" \
        "empty/short output -- the dispatch env's entrypoint reached the hook" ;;
esac

# stop_hook_active re-entry must still release, unaffected by the same ambient poison -- the
# scrub must not accidentally un-release a genuine re-entry either.
H2="$(printf '{"session_id":"hermetic-reentry-%s","stop_hook_active":true}' "$$" \
        | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"
if [ -z "$H2" ]; then ok "H: re-entry still releases despite the same poisoned ambient environment"
else bad "H: re-entry still releases despite the same poisoned ambient environment" "emitted: $H2"; fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
