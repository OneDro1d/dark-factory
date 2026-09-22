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

echo "=== I: the CONVERGE half — done-tests, prior answers, and the open-item count ==="
# The gate's original question is "what did you NOT finish". These three cover the failures
# that question cannot see: work handed OVER as done that nobody can reach, a decision handed
# BACK that was already answered, and a session that ends by surveying rather than closing.
# All three were measured on 2026-09-14, in the session that added them.
I1="$(printf '{"session_id":"converge-%s"}' "$$" | scrub_dispatch_env python3 "$HOOK" 2>/dev/null)"

case "$I1" in
  *"CHALLENGE WHAT YOU CALLED DONE"*) ok "I: challenges what was called done, not only what was deferred" ;;
  *) bad "I: challenges what was called done, not only what was deferred" "absent from the gate text" ;;
esac

# The exact false done-tests, quoted, so an edit that softens them fails here rather than
# passing quietly — same rule the excuse list above follows.
#
# ⚠️ DECODE THE JSON FIRST. The hook emits its text inside a JSON string, so a quoted phrase
# arrives on the wire as \"merged\" and a case pattern for "merged" matches nothing: three
# assertions went red against a gate that contained every phrase they were looking for. That
# is measuring the ENCODING instead of the message. Decoding also tests the string the model
# is actually handed, which is the thing that has to be right.
I1_TEXT="$(printf '%s' "$I1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["systemMessage"])' 2>/dev/null)"
if [ -n "$I1_TEXT" ]; then ok "I: the gate text decodes out of the JSON envelope"
else bad "I: the gate text decodes out of the JSON envelope" "could not read systemMessage"; fi

for phrase in merged pushed shipped; do
  case "$I1_TEXT" in
    *"\"$phrase\""*) ok "I: names '$phrase' as a non-done-test" ;;
    *) bad "I: names '$phrase' as a non-done-test" "the phrase is not rebutted in the gate text" ;;
  esac
done

case "$I1" in
  *"SEARCH for one already made"*) ok "I: demands a search for a prior ruling before handing a decision back" ;;
  *) bad "I: demands a search for a prior ruling before handing a decision back" "absent" ;;
esac

# ── the MEASURED half: the open-item count ────────────────────────────────────────────────
# Absent is not zero. A session outside a notepad must get NO count rather than a wrong one,
# so the line is omitted entirely when there is no operator-todo.md above cwd.
NOTODO="$TMPDIR/no-todo"; mkdir -p "$NOTODO"
I2="$( cd "$NOTODO" && printf '{"session_id":"count-absent-%s"}' "$$" \
        | scrub_dispatch_env python3 "$HOOK" 2>/dev/null )"
case "$I2" in
  *"open item(s)"*) bad "I: no count when there is no operator-todo.md" "emitted a count anyway" ;;
  *) ok "I: no count when there is no operator-todo.md above cwd" ;;
esac

# With a page present the count must be exact, and must count ONLY unchecked items: a checked
# one is done and awaiting deletion, so counting it would make closing an item look like no
# progress at all.
TODO="$TMPDIR/withtodo"; mkdir -p "$TODO/nested/deeper"
{ printf '# Operator TODO\n\n'
  printf -- '- [ ] one — open\n'
  printf -- '- [x] two — done, awaiting deletion\n'
  printf -- '- [ ] three — open\n'
  printf 'not an item at all\n'
} > "$TODO/operator-todo.md"
I3="$( cd "$TODO" && printf '{"session_id":"count-two-%s"}' "$$" \
        | scrub_dispatch_env python3 "$HOOK" 2>/dev/null )"
case "$I3" in
  *"has 2 open item(s)"*) ok "I: counts only unchecked items (2 of 3)" ;;
  *) bad "I: counts only unchecked items (2 of 3)" "expected 'has 2 open item(s)'" ;;
esac

# It must walk UP, the same way the notepad itself is resolved — a session usually runs in a
# subdirectory, not at the notepad root.
I4="$( cd "$TODO/nested/deeper" && printf '{"session_id":"count-walkup-%s"}' "$$" \
        | scrub_dispatch_env python3 "$HOOK" 2>/dev/null )"
case "$I4" in
  *"has 2 open item(s)"*) ok "I: finds the page by walking up from a nested cwd" ;;
  *) bad "I: finds the page by walking up from a nested cwd" "did not resolve the page" ;;
esac

# The count rides on the BRIEF form too. The prose is identical on a repeat firing; the number
# is the one part that can have changed since, so suppressing it there would drop the only
# fresh signal the later firings carry.
SID="brief-count-$$"
printf '{"session_id":"%s"}' "$SID" | ( cd "$TODO" && scrub_dispatch_env python3 "$HOOK" ) >/dev/null 2>&1
I5="$( cd "$TODO" && printf '{"session_id":"%s"}' "$SID" \
        | scrub_dispatch_env python3 "$HOOK" 2>/dev/null )"
case "$I5" in
  *"already run this session"*) ok "I: second firing is the brief form" ;;
  *) bad "I: second firing is the brief form" "expected the brief text" ;;
esac
case "$I5" in
  *"has 2 open item(s)"*) ok "I: the brief form still carries the count" ;;
  *) bad "I: the brief form still carries the count" "the count was dropped on repeat" ;;
esac

# Never at the cost of the turn: an unreadable page must degrade to no count, not to a crash.
BADTODO="$TMPDIR/badtodo"; mkdir -p "$BADTODO"
printf '\x80\x81 not utf-8 \xff\n- [ ] one\n' > "$BADTODO/operator-todo.md"
if ( cd "$BADTODO" && printf '{"session_id":"badpage-%s"}' "$$" \
       | scrub_dispatch_env python3 "$HOOK" >/dev/null 2>&1 ); then
  ok "I: a non-UTF-8 page still exits 0 — the turn is never blocked by the count"
else
  bad "I: a non-UTF-8 page still exits 0" "non-zero exit would block the turn"
fi

echo "=== J: COST — never force a turn after a turn that did no work ==="
# ⛔ MEASURED 2026-09-18 (2.1.276): additionalContext on Stop makes the model take another turn,
# like decision:block. Fleet-wide that day this gate forced 1,355 turns (~807M cache-read tokens,
# ~$390), mostly "nothing has changed" after a reply that made no tool calls. These cases pin
# the quiet path, and that the nudge still reaches a turn with real deferred work.
TX="$TMPDIR/tx"; mkdir -p "$TX"
# transcripts: a real prompt, then the assistant's turn
mk_text_only() { printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"status?"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Nothing has changed; all blocked on the operator."}]}}' > "$1"; }
mk_work() { # <file> <final text>
  printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"fix it"}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/x"}}]}}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}' > "$1"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$2" >> "$1"; }
fire() { printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2" | scrub_dispatch_env python3 "$HOOK" 2>/dev/null; }

mk_text_only "$TX/text.jsonl"
J1="$(fire "cost-$$" "$TX/text.jsonl")"
[ "$J1" = "{}" ] && ok "J: a text-only turn forces NO turn, even the session's first" \
                 || bad "J: a text-only turn forces NO turn" "emitted: $(printf '%s' "$J1" | head -c 120)"

mk_work "$TX/work1.jsonl" "Done: edited the file and the test passes."
J2="$(fire "cost-$$" "$TX/work1.jsonl")"
case "$J2" in *"OPERATOR-ONLY blocker"*) ok "J: the first turn that DID work gets the full gate";;
  *) bad "J: the first working turn gets the full gate" "$J2";; esac

mk_work "$TX/work2.jsonl" "Edited the second file and the suite is green."
J3="$(fire "cost-$$" "$TX/work2.jsonl")"
[ "$J3" = "{}" ] && ok "J: a later working turn with no deferral and no new todo forces NO turn" \
                 || bad "J: later working turn without deferral stays quiet" "$(printf '%s' "$J3" | head -c 120)"

mk_work "$TX/work3.jsonl" "Fixed the parser. Next step: the migration is left for a separate PR."
J4="$(fire "cost-$$" "$TX/work3.jsonl")"
case "$J4" in *"already run this session"*) ok "J: a working turn that DEFERS work still gets the reminder";;
  *) bad "J: deferral still nudged" "$J4";; esac

J5="$(fire "cost-$$" "$TX/text.jsonl")"
[ "$J5" = "{}" ] && ok "J: a text-only turn after firings stays quiet" || bad "J: text-only after firings" "$J5"

# the operator page growing is the MEASURED signal, and it outranks the wording of the reply
PG="$TMPDIR/pg"; mkdir -p "$PG"; printf -- '- [ ] one\n' > "$PG/operator-todo.md"
( cd "$PG" && fire "grow-$$" "$TX/work1.jsonl" >/dev/null )            # first firing: baseline 1
printf -- '- [ ] one\n- [ ] two\n' > "$PG/operator-todo.md"
J6="$( cd "$PG" && fire "grow-$$" "$TX/work2.jsonl" )"
case "$J6" in *"2 open item(s)"*) ok "J: a working turn that GREW the operator page is nudged, whatever it says";;
  *) bad "J: page growth nudges" "$J6";; esac

# fail toward prompting: an unreadable transcript cannot prove the turn was text-only
J7="$(fire "noread-$$" "$TX/does-not-exist.jsonl")"
case "$J7" in *"OPERATOR-ONLY"*) ok "J: an unreadable transcript still fires (absent evidence is not text-only)";;
  *) bad "J: unreadable transcript fires" "$J7";; esac

echo "=== K: THROTTLE — at most one brief reminder per 30 minutes per session ==="
# ⛔ MEASURED 2026-09-18: after J's change the fleet fell 2.8 → 0.5 forced turns per 100 replies,
# but one session ROSE 1.1 → 1.7 — its status replies named the blocker ("waiting on the merge"),
# which the deferral regex matches, so every working turn drew the brief form. ifelapsed-style fix.
KS="throttle-$$"
fire "$KS" "$TX/work1.jsonl" >/dev/null                                  # full gate
K1="$(fire "$KS" "$TX/work3.jsonl")"
case "$K1" in *"already run this session"*) ok "K: the first deferring turn after the gate gets the brief";;
  *) bad "K: first brief fires" "$K1";; esac
K2="$(fire "$KS" "$TX/work3.jsonl")"
[ "$K2" = "{}" ] && ok "K: a second deferring turn inside 30 minutes forces NO turn" \
                 || bad "K: brief throttled inside the window" "$(printf '%s' "$K2" | head -c 120)"
# the page growing does NOT bypass the budget: the approved rule is one brief per 30 min, full stop
PK="throttle-page-$$"; mkdir -p "$TMPDIR/pk"; printf -- '- [ ] one\n' > "$TMPDIR/pk/operator-todo.md"
( cd "$TMPDIR/pk" && fire "$PK" "$TX/work1.jsonl" >/dev/null )
( cd "$TMPDIR/pk" && fire "$PK" "$TX/work3.jsonl" >/dev/null )
printf -- '- [ ] one\n- [ ] two\n' > "$TMPDIR/pk/operator-todo.md"
K3="$( cd "$TMPDIR/pk" && fire "$PK" "$TX/work2.jsonl" )"
[ "$K3" = "{}" ] && ok "K: page growth inside the window is throttled too" || bad "K: page growth throttled" "$K3"
# after the interval it is due again: backdate the stamp 31 minutes
STAMP="$TMPDIR/claude-completeness-gate/$KS.brief"
if [ -f "$STAMP" ]; then ok "K: the throttle stamp is keyed by session under TMPDIR"
else bad "K: throttle stamp location" "no $STAMP"; fi
python3 -c 'import sys,time; open(sys.argv[1],"w").write(str(time.time()-31*60))' "$STAMP"
K4="$(fire "$KS" "$TX/work3.jsonl")"
case "$K4" in *"already run this session"*) ok "K: after 30 minutes the brief is due again";;
  *) bad "K: brief due after the interval" "$K4";; esac
# another session has its own budget
K5="$( fire "throttle-other-$$" "$TX/work1.jsonl" >/dev/null; fire "throttle-other-$$" "$TX/work3.jsonl" )"
case "$K5" in *"already run this session"*) ok "K: the budget is per session";;
  *) bad "K: per-session budget" "$K5";; esac
# fail toward prompting: an unreadable stamp means the brief fires
printf 'garbage' > "$STAMP"
K6="$(fire "$KS" "$TX/work3.jsonl")"
case "$K6" in *"already run this session"*) ok "K: a corrupt stamp fails toward prompting";;
  *) bad "K: corrupt stamp fires" "$K6";; esac
# the full gate is never throttled: a new session's first working turn always gets it
K7="$(fire "throttle-fresh-$$" "$TX/work3.jsonl")"
case "$K7" in *"OPERATOR-ONLY blocker"*) ok "K: the full gate ignores the throttle";;
  *) bad "K: full gate unthrottled" "$K7";; esac

echo "=== L: STALL GUARD — a turn that ENDS on an announced action it did not take ==="
# ⛔ The gap is this file's own: "no work, no firing" (J) returns {} on every text-only turn, and
# "Now I'll build X" + end of turn IS a text-only turn. The operator reported sessions stopping
# mid-mission exactly so. The negatives below are the REAL false-positive shapes the backtest on
# this estate's transcripts found (sanitised); a future edit that reintroduces one fails here.
# mkt <file> <final text> [work]  — a real prompt, optionally a tool call, then the final text
mkt() { python3 - "$@" <<'PY'
import json, sys
path, text = sys.argv[1], sys.argv[2]
work = len(sys.argv) > 3
rows = [{"type": "user", "message": {"role": "user", "content": "go"}}]
if work:
    rows += [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Edit", "input": {}}]}},
             {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}]
rows.append({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}})
open(path, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
}
# chain <file> <first text> <second text> <work-after-nudge:0|1> — announce, get nudged, continue
chain() { python3 - "$@" <<'PY'
import json, sys
path, a, b, work = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
rows = [{"type": "user", "message": {"role": "user", "content": "go"}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": a}]}},
        {"type": "user", "message": {"role": "user", "content": "Stop hook feedback:\nSTALLED ON AN ANNOUNCEMENT"}}]
if work:
    rows += [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t2", "name": "Bash", "input": {}}]}},
             {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t2", "content": "ok"}]}}]
rows.append({"type": "assistant", "message": {"content": [{"type": "text", "text": b}]}})
open(path, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
}
stall() { # stall <session> <transcript> [stop_hook_active] [extra env...]
  local s="$1" t="$2" a="${3:-false}"; shift 3 2>/dev/null || shift $#
  printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' "$s" "$t" "$a" \
    | scrub_dispatch_env env HOME="$TMPDIR/home" "$@" python3 "$HOOK" 2>/dev/null; }
is_stall() { case "$1" in *"STALLED ON AN ANNOUNCEMENT"*) return 0;; *) return 1;; esac; }
mkdir -p "$TMPDIR/home"

# L1 — THE OPERATOR'S CASE, verbatim shape: announce, make no tool call, stop. Text-only, so it
# is exactly what J's "no work, no firing" lets through — this must fire anyway.
mkt "$TX/l1.jsonl" "The design is settled. Now I will build the parser."
L1="$(stall "l1-$$" "$TX/l1.jsonl" false)"
is_stall "$L1" && ok "L1: 'Now I will build X' + stop, NO tool calls — the stall is caught" \
               || bad "L1: the operator's case is caught" "$(printf '%s' "$L1" | head -c 160)"
case "$L1" in *'"decision": "block"'*) ok "L1: it BLOCKS the stop (decision=block), not a side note";;
  *) bad "L1: blocks the stop" "$(printf '%s' "$L1" | head -c 160)";; esac
case "$L1" in *"will build the parser"*) ok "L1: it quotes the announcement back";;
  *) bad "L1: quotes the phrase" "$(printf '%s' "$L1" | head -c 160)";; esac
printf '%s' "$L1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && ok "L1: the block is valid JSON" || bad "L1: valid JSON" "$L1"

# L2 — a turn that DID work, then ends on the next announcement ("I'll" is not DEFERRAL language,
# and the brief form is throttled, so before this it slipped too)
mkt "$TX/l2.jsonl" "Edited the config and the tests pass. Next I'll add the migration." work
is_stall "$(stall "l2-$$" "$TX/l2.jsonl" false)" && ok "L2: a working turn ending on 'Next I'll add X' is caught" \
                                                 || bad "L2: working turn + announcement caught" "silent"

# L3 — the strongest tell: the raw text ends on a colon, introducing a tool call that never came
mkt "$TX/l3.jsonl" "Both branches changed the file. Combining the two versions of the file:"
is_stall "$(stall "l3-$$" "$TX/l3.jsonl" false)" && ok "L3: a message ending on a colon is caught" \
                                                 || bad "L3: colon ending caught" "silent"

# L4 — NEGATIVES. Each is a real legitimate-stop shape the backtest surfaced. None may fire.
n=0
while IFS= read -r neg; do
  n=$((n+1)); mkt "$TX/l4-$n.jsonl" "$(printf '%b' "$neg")"
  if is_stall "$(stall "l4-$n-$$" "$TX/l4-$n.jsonl" false)"; then
    bad "L4: not a stall — $(printf '%b' "$neg" | head -c 60)" "it fired"
  else ok "L4: not a stall — $(printf '%b' "$neg" | tr '\n' ' ' | head -c 60)"; fi
done <<'NEGS'
The setup steps depend on the bridge, so I'll write them once the developer returns.
The watchdog tick is due at :23, a few minutes out. I'll run it when it fires.
Pool 8 is idle, so absence is not confirmation. I'll confirm it on the first monitor pass that catches a withdrawal.
It needs a policy change, so I'll add it to the hourly update by hand.
I'll wait for the 21:46 timer.
The docs file I swept in is still there. Say the word and I'll drop it.
Everything else needs your decisions. I'll run it once you say go.
Should I build the parser now?
If the helper fails like this again, I'll keep running the reads myself.
Your test:\n```bash\nbash run-tests.sh\n```
Everything is merged and verified.
NEGS

# ⛔ L5 — THE LOOP BOUND. Nudged, then the continuation did NO work and ended on an announcement
# again: release. Without this a model that only ever announces is blocked until the harness's
# 9-consecutive cap force-ends it — the exact failure the G cases record for this hook.
chain "$TX/l5.jsonl" "Now I'll build the parser." "Now I'll build the parser, starting with the lexer." 0
L5="$(stall "l5-$$" "$TX/l5.jsonl" true)"
is_stall "$L5" && bad "L5: nudged + no progress -> RELEASE" "it blocked again" \
               || ok "L5: LOOP BOUND — nudged, no progress since: the stop is released"

# L6 — progress IS allowed to keep going: nudged, the continuation made tool calls, and ended on
# a NEW announcement. That is a session moving through a mission, so it is nudged again.
chain "$TX/l6.jsonl" "Now I'll build the parser." "Built the parser, tests green. Now I'll wire it into the CLI." 1
is_stall "$(stall "l6-$$" "$TX/l6.jsonl" true)" && ok "L6: nudged, WORKED, new announcement — nudged again (progress)" \
                                                || bad "L6: progress re-nudges" "silent"

# L7 — once per distinct text: the same announcement at a fresh stop is not re-nudged
mkt "$TX/l7.jsonl" "Now I'll build the parser."
stall "l7-$$" "$TX/l7.jsonl" false >/dev/null
is_stall "$(stall "l7-$$" "$TX/l7.jsonl" false)" && bad "L7: same text is nudged once" "nudged twice" \
                                                 || ok "L7: the same text is nudged ONCE per session"

# L8 — autoclear ARMED for this session owns the stop: its /clear would discard a nudged turn's
# work, and its resume prompt continues the mission anyway. The guard steps aside.
mkdir -p "$TMPDIR/home/.claude/state/context-budget"; : > "$TMPDIR/home/.claude/state/context-budget/l8-$$.e0"
mkt "$TX/l8.jsonl" "Now I'll build the parser."
is_stall "$(stall "l8-$$" "$TX/l8.jsonl" false DF_CONTEXT_GATE_MODE=autoclear)" \
  && bad "L8: armed autoclear owns the stop" "the stall guard fired anyway" \
  || ok "L8: autoclear ARMED for the session — the stall guard steps aside"
# CONTROL for L8: the SAME session, once that arm has been spent (.cleared) — the guard is back.
# Without this, L8 would also pass for a guard that is simply switched off under autoclear.
: > "$TMPDIR/home/.claude/state/context-budget/l8-$$.e0.cleared"
is_stall "$(stall "l8-$$" "$TX/l8.jsonl" false DF_CONTEXT_GATE_MODE=autoclear)" \
  && ok "L8: CONTROL — same session, arm spent (.cleared): the guard fires again" \
  || bad "L8: CONTROL — guard fires once the arm is spent" "silent"

# L9 — headless workers are released before anything, as every other path here (see G/H):
# a Stop block in `claude -p` replaces the worker's RESULT with prose, which dispatch reads.
L9="$(printf '{"session_id":"l9-%s","transcript_path":"%s"}' "$$" "$TX/l1.jsonl" \
      | scrub_dispatch_env env HOME="$TMPDIR/home" CLAUDE_CODE_ENTRYPOINT=sdk-cli python3 "$HOOK" 2>/dev/null)"
is_stall "$L9" && bad "L9: headless -p is released" "it blocked a worker" \
               || ok "L9: a headless (sdk-cli) worker is never blocked"

# L10 — the off switch is real. Fresh session, the operator's exact case, guard disabled: silent.
# (L1 is the control: the same transcript with the switch absent DOES block.)
mkt "$TX/l10.jsonl" "The design is settled. Now I will build the parser."
is_stall "$(stall "l10-$$" "$TX/l10.jsonl" false DF_STALL_GUARD=off)" \
  && bad "L10: DF_STALL_GUARD=off disables it" "it fired anyway" \
  || ok "L10: DF_STALL_GUARD=off turns the stall guard off"

echo "=== M: EVERY session keeps operator-todo.md, and keeps it in shape (operator ruling 2026-09-22) ==="
TOOL="$T1/plugins/df-governed/bin/df-operator-todo"
MP="$TMPDIR/mnp"; mkdir -p "$MP/sub"; printf '# NOTES\n' > "$MP/NOTES.md"
pfire() { # pfire <session> <transcript> <cwd> [extra env...]
  local s="$1" t="$2" c="$3"; shift 3
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$s" "$t" "$c" \
    | scrub_dispatch_env DF_OPERATOR_TODO_BIN="$TOOL" "$@" python3 "$HOOK" 2>/dev/null; }
notshape() { case "$1" in *"NOT IN SHAPE"*) return 0;; *) return 1;; esac; }

M1="$(pfire "page1-$$" "$TX/work1.jsonl" "$MP/sub")"
[ -f "$MP/operator-todo.md" ] && ok "M1: a notepad session with no page gets one created" \
                              || bad "M1: page created" "no page at $MP/operator-todo.md"
notshape "$M1" && bad "M1: a fresh page is clean — no block" "$M1" || ok "M1: a fresh page is clean — no block"

printf '\nI did a lot of work today and here is the story.\n' >> "$MP/operator-todo.md"
M2="$(pfire "page2-$$" "$TX/work1.jsonl" "$MP")"
notshape "$M2" && ok "M2: narration on the page BLOCKS the stop" || bad "M2: narration blocks" "$M2"
case "$M2" in *'"decision": "block"'*) ok "M2: and it is a block, not a hint";; *) bad "M2: is a block" "$M2";; esac
case "$M2" in *"outside any item"*) ok "M2: the reason carries the lint finding";; *) bad "M2: carries lint" "$M2";; esac

M3="$(pfire "page2-$$" "$TX/work2.jsonl" "$MP")"
notshape "$M3" && bad "M3: the SAME page version is not re-nagged" "$M3" || ok "M3: the same page version is not re-nagged"

"$TOOL" --file "$MP/operator-todo.md" add --id m4 --category credential --task "Sign in" --why "only you" --step "Run: claude auth login" --do "claude auth login" >/dev/null 2>&1
M4="$(pfire "page2-$$" "$TX/work1.jsonl" "$MP")"
notshape "$M4" && bad "M4: a rewritten, clean page passes" "$M4" || ok "M4: once the page is rewritten clean, no block"

printf '\nmore narration\n' >> "$MP/operator-todo.md"
M5="$(pfire "page5-$$" "$TX/text.jsonl" "$MP")"
notshape "$M5" && bad "M5: a text-only turn never forces a page fix" "$M5" || ok "M5: a text-only turn never forces a page fix (cost)"
M6="$(pfire "page6-$$" "$TX/work1.jsonl" "$MP" DF_OPERATOR_PAGE_CHECK=off)"
notshape "$M6" && bad "M6: DF_OPERATOR_PAGE_CHECK=off" "$M6" || ok "M6: DF_OPERATOR_PAGE_CHECK=off turns it off"
printf '#!/bin/sh\nexit 2\n' > "$TMPDIR/oldtool"; chmod +x "$TMPDIR/oldtool"
M7="$(printf '{"session_id":"page7-%s","transcript_path":"%s","cwd":"%s"}' "$$" "$TX/work1.jsonl" "$MP" \
      | scrub_dispatch_env DF_OPERATOR_TODO_BIN="$TMPDIR/oldtool" python3 "$HOOK" 2>/dev/null)"
notshape "$M7" && bad "M7: an old tool with no lint fails OPEN" "$M7" || ok "M7: an installed tool with no lint fails OPEN — never a forced turn"
# ⛔ CONTROL for M7: the same page with the real tool MUST block, or M7 proves nothing.
M8="$(pfire "page8-$$" "$TX/work1.jsonl" "$MP")"
notshape "$M8" && ok "M8: CONTROL — the same page with the real tool does block" || bad "M8: control blocks" "$M8"
M9="$(pfire "page9-$$" "$TX/work1.jsonl" "$TMPDIR")"
notshape "$M9" && bad "M9: outside a notepad, nothing" "$M9" || ok "M9: outside a notepad there is no page check"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
