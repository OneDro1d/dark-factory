#!/usr/bin/env bash
# test-mission-engram.sh — a mission's durable record: the anchor at start, the result at close.
#
# ⛔ WHY THIS SUITE EXISTS AT ALL. The `df-mission start` anchor shipped in T1 #220 with NO test —
# a wiring nothing exercised, which is the same "declared but never run" shape this repo keeps
# finding elsewhere. And `stop` wrote nothing, so a mission that ended left no durable trace of
# having ended: the anchor said a mission began and the store never said how it finished.
#
# ⛔ THE BRAKE MUST STAY A BRAKE. `df-mission stop` is how a runaway loop is halted, and the
# whole reason it is a CLI rather than a skill is that it has to work when nothing else does. So
# the record it writes must be fired and forgotten: it may never block, never hang on a hub, and
# never fail the stop. This suite pins that with a transport that HANGS.
#
# Engram itself — what it is and how a machine reaches it — is documented in one place:
# [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
MISSION="$SELF/../df-mission"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/missionengram.XXXXXX")"
trap 'rm -rf "$T"' EXIT

NP="$T/np"; mkdir -p "$NP/.df/missions/M-TEST-9"
printf '# NOTES\n' > "$NP/NOTES.md"
printf '{}\n'      > "$NP/repos.manifest.json"
printf '# mission\n' > "$NP/.df/missions/M-TEST-9/MISSION.md"
printf 'CONTINUE\n'  > "$NP/.df/missions/M-TEST-9/state"
mkdir -p "$NP/.df/missions/M-TEST-9/iterations"
printf '{}\n' > "$NP/.df/missions/M-TEST-9/iterations/1.json"
printf '{}\n' > "$NP/.df/missions/M-TEST-9/iterations/2.json"

LOG="$T/engram-calls.log"
STUB="$T/df-engram-stub"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$LOG" > "$STUB"
chmod +x "$STUB"

echo "=== A: stop writes a RESULT record, and it is FACTUAL ==="
: > "$LOG"
OUT="$(cd "$NP" && NOTEPAD="$NP" DF_ENGRAM_BIN="$STUB" bash "$MISSION" stop M-TEST-9 2>&1)"
eq "A: stop exits 0" "$?" "0"
# the record is fired in the background, so give it a moment to land
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$LOG" ] && break; done
CALLED="$(cat "$LOG" 2>/dev/null)"
contains "A: df-engram was asked to write" "write" "$CALLED"
contains "A: the mission id is in it" "M-TEST-9" "$CALLED"
contains "A: it is linked to the mission anchor" "--mission" "$CALLED"
contains "A: and the state file still says STOP" "STOP" "$(cat "$NP/.df/missions/M-TEST-9/state")"

echo "=== B: ⛔ THE BRAKE NEVER BLOCKS — a hub that hangs must not hold up a stop ==="
# ⛔ MEASURED CONCERN, NOT A HYPOTHETICAL: df-engram's own hub call allows up to 120 s. Two minutes
# on the control that halts a runaway loop is not a brake. The record is therefore detached, and
# this asserts the stop RETURNS while the writer is still hanging.
printf 'CONTINUE\n' > "$NP/.df/missions/M-TEST-9/state"
HANG="$T/df-engram-hang"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$HANG"
chmod +x "$HANG"
START=$(date +%s)
(cd "$NP" && NOTEPAD="$NP" DF_ENGRAM_BIN="$HANG" bash "$MISSION" stop M-TEST-9 >/dev/null 2>&1)
END=$(date +%s)
ELAPSED=$((END-START))
if [ "$ELAPSED" -le 5 ]; then ok "B: stop returned in ${ELAPSED}s while the writer hung"
else bad "B: stop returned promptly" "took ${ELAPSED}s — the brake is waiting on the hub"; fi
contains "B: and it still stopped the mission" "STOP" "$(cat "$NP/.df/missions/M-TEST-9/state")"

echo "=== C: a missing df-engram is not a failed stop ==="
printf 'CONTINUE\n' > "$NP/.df/missions/M-TEST-9/state"
OUT="$(cd "$NP" && NOTEPAD="$NP" DF_ENGRAM_BIN="$T/does-not-exist" bash "$MISSION" stop M-TEST-9 2>&1)"
eq "C: stop still exits 0" "$?" "0"
contains "C: and still stopped it" "STOP" "$(cat "$NP/.df/missions/M-TEST-9/state")"

echo "=== D: start mints the mission anchor — the #220 wiring nothing exercised ==="
: > "$LOG"
printf 'CONTINUE\n' > "$NP/.df/missions/M-TEST-9/state"
(cd "$NP" && NOTEPAD="$NP" DF_ENGRAM_BIN="$STUB" bash "$MISSION" start M-TEST-9 --max-iter 1 >/dev/null 2>&1)
CALLED="$(cat "$LOG" 2>/dev/null)"
contains "D: df-engram anchor was called" "anchor" "$CALLED"
contains "D: for this mission" "M-TEST-9" "$CALLED"

printf 'passed %s  failed %s\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
