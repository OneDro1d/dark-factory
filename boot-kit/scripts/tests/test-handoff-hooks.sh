#!/usr/bin/env bash
# test-handoff-hooks.sh — the PreCompact/SessionStart pair that carries a session across
# compaction, and the pointer that makes the DELIBERATE handoff the entry point.
#
# WHAT THIS PAIR IS FOR. A session cannot clear its own window, and native compaction is
# lossy and unversioned. handoff-precompact.py writes a snapshot before compaction;
# handoff-sessionstart-load.py re-injects it after, keyed by session_id, consume-once.
#
# ⚠️ THE POINTER IS THE POINT, and it closes a gap measured 2026-09-01. The loader re-injects
# THIS snapshot -- the mechanical one: files touched, recent intent. The DELIBERATE handoff,
# written by Skill(handoff) into <notepad>/handoffs/ with where-the-work-stands and the one
# next action, was re-injected by NOTHING, and the notepad's own SessionStart hook never
# mentions handoffs/ at all. So "the handoff is the single entry point for a cold session"
# held on paper and not in the wiring: orientation survived compaction only because NOTES.md
# happened to be thorough, which is a property of a good session rather than of the mechanism.
#
# ⚠️ IT POINTS, IT DOES NOT COPY. Copying the handoff into the snapshot would create a second
# store of the same facts and the two would drift -- the failure the single-entry-point rule
# exists to prevent. Case A asserts the pointer NAMES A FILE THAT EXISTS; it deliberately does
# not assert the handoff's contents appear.
#
# ⚠️ THE ABSENT CASE IS ASSERTED AS LOUDLY AS THE PRESENT ONE (case B). A hook that silently
# omits the pointer reads identically to one that had nothing to point at -- the
# green-means-nobody-looked failure this estate keeps finding.
#
# Usage: bash boot-kit/scripts/tests/test-handoff-hooks.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T1="$(cd "$SELF/../../.." && pwd)"
PRE="$T1/hooks/handoff-precompact.py"
LOAD="$T1/hooks/handoff-sessionstart-load.py"
for f in "$PRE" "$LOAD"; do [ -f "$f" ] || { echo "missing $f"; exit 2; }; done
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

TMP="$(mktemp -d)"
# The hooks write under $HOME/.claude/handoffs. Point HOME at the scratch tree so the suite
# never touches the developer's real handoffs -- and so a failure here cannot delete one.
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/handoffs"
trap 'rm -rf "$TMP"' EXIT

# A fake notepad: NOTES.md marks the root, handoffs/ holds the deliberate handoff.
NP="$TMP/notepad"
mkdir -p "$NP/handoffs/nested"
: > "$NP/NOTES.md"
printf 'older\n'  > "$NP/handoffs/2026-01-01-old.md"
sleep 1
printf 'THE-DELIBERATE-HANDOFF-BODY\n' > "$NP/handoffs/2026-09-01-newest.md"

run_pre() {  # $1 = session id, $2 = cwd
  printf '{"session_id":"%s","cwd":"%s","transcript_path":""}' "$1" "$2" | python3 "$PRE" >/dev/null
}
run_load() { printf '{"session_id":"%s","source":"compact"}' "$1" | python3 "$LOAD"; }

echo "=== A: inside a notepad — the snapshot points at the NEWEST deliberate handoff ==="
SID=a1; run_pre "$SID" "$NP"
SNAP="$HOME/.claude/handoffs/$SID.md"
if [ -f "$SNAP" ]; then ok "A: snapshot written"; else bad "A: snapshot written" "no file"; fi
body="$(cat "$SNAP" 2>/dev/null)"
case "$body" in *"READ THIS FIRST"*) ok "A: leads with the pointer" ;;
  *) bad "A: leads with the pointer" "no pointer heading" ;; esac
case "$body" in *2026-09-01-newest.md*) ok "A: names the NEWEST handoff" ;;
  *) bad "A: names the NEWEST handoff" "wrong or missing file" ;; esac
case "$body" in *2026-01-01-old.md*) bad "A: does not name the older one" "older handoff named" ;;
  *) ok "A: does not name the older one" ;; esac
# The pointer must resolve. A path that names nothing is the archived-link failure again.
named="$(printf '%s' "$body" | grep -oE '/[^ ]*handoffs/[^ ]*\.md' | head -1)"
if [ -n "$named" ] && [ -f "$named" ]; then ok "A: the named path EXISTS"
else bad "A: the named path EXISTS" "named='$named'"; fi
# POINTS, does not COPY.
case "$body" in *THE-DELIBERATE-HANDOFF-BODY*)
  bad "A: points without copying" "the handoff BODY was inlined — that is a second store" ;;
  *) ok "A: points without copying" ;; esac

echo "=== B: outside any notepad — says so LOUDLY, never fakes a pointer ==="
SID=b1; run_pre "$SID" "$TMP"
b="$(cat "$HOME/.claude/handoffs/$SID.md" 2>/dev/null)"
case "$b" in *"No deliberate handoff found"*) ok "B: states the absence" ;;
  *) bad "B: states the absence" "silent omission reads like success" ;; esac
case "$b" in *GAP*|*gap*) ok "B: calls it a gap, not a clean state" ;;
  *) bad "B: calls it a gap" "absence reported neutrally" ;; esac
case "$b" in *"READ THIS FIRST"*) bad "B: no fake pointer" "claims a handoff it does not have" ;;
  *) ok "B: no fake pointer" ;; esac

echo "=== C: the loader re-injects it, once ==="
SID=c1; run_pre "$SID" "$NP"
first="$(run_load "$SID")"
case "$first" in *"READ THIS FIRST"*) ok "C: pointer survives into the injection" ;;
  *) bad "C: pointer survives" "not in loader output" ;; esac
case "$first" in *2026-09-01-newest.md*) ok "C: the filename reaches the new window" ;;
  *) bad "C: filename reaches the new window" "absent" ;; esac
second="$(run_load "$SID")"
# CONSUME-ONCE IS ABOUT THE SNAPSHOT, NOT ABOUT SILENCE.
#
# This assertion used to be [ -z "$second" ] -- "a second read is empty". That encoded the
# loader's OLD shape, in which a consumed snapshot left the hook with nothing else to say.
# Since 2026-09-02 the loader has a second, snapshot-independent source: it points at the
# newest <notepad>/handoffs/*.md so that /clear -- which fires no PreCompact and therefore
# writes no snapshot at all -- still orients the new window. A second read is CORRECTLY
# non-empty now: the snapshot is gone, the pointer remains.
#
# The property worth testing is that the SNAPSHOT is not delivered twice. "Files written" is
# snapshot-only; the deliberate-handoff filename appears on BOTH paths and is useless as a
# discriminator -- which is exactly why the old assertion looked right while testing a proxy.
case "$second" in *"Files written"*) bad "C: consume-once" "the snapshot was re-injected" ;;
  *) ok "C: consume-once -- the snapshot is not re-injected" ;; esac
case "$second" in *"READ THIS FIRST"*) ok "C: a consumed snapshot falls through to the pointer" ;;
  *) bad "C: fall-through to the pointer" "emitted nothing -- /clear would be blind" ;; esac

echo "=== D: never blocks compaction, whatever it is handed ==="
# A hook that raises would block compaction and lose the whole window. Both must exit 0 on
# malformed input rather than propagate.
printf 'not json at all' | python3 "$PRE" >/dev/null 2>&1
[ $? -eq 0 ] && ok "D: precompact survives malformed stdin" || bad "D: precompact survives" "non-zero exit"
printf 'not json at all' | python3 "$LOAD" >/dev/null 2>&1
[ $? -eq 0 ] && ok "D: loader survives malformed stdin" || bad "D: loader survives" "non-zero exit"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
