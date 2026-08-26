#!/usr/bin/env bash
# test-start-terminal-state.sh — `df-mission start` must REFUSE on a terminal state.
#
# WHY THIS EXISTS. `start` on a BLOCKED mission was a FALSE START. It printed
# "started mission ... state CONTINUE", forked a supervisor, and the supervisor exited
# after ZERO iterations — because df-supervisor.sh seeds CONTINUE only when the state file
# is EMPTY, so a BLOCKED file survived and the loop broke on its first read. Every line of
# output said running. Observed 2026-08-25 on a real mission and caught only because a log
# monitor happened to be armed.
#
# EACH TERMINAL STATE IS ASSERTED SEPARATELY. Refusing "a terminal state" as one batch
# would pass if only BLOCKED were handled and DONE and STOP fell through — a joint green
# proves the batch, not each member. Same reason --resume is exercised per state.
#
# The forking path is deliberately NOT exercised: this suite must never launch a supervisor
# or spend a token. Every case here asserts on exit code and stderr BEFORE the fork.
#
# Run:  bash boot-kit/scripts/tests/test-start-terminal-state.sh
# Exit: 0 all pass · 1 at least one failed. Prints a literal count, because a suite that
# says "ok" without saying how many assertions ran cannot be told from one that ran none.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../df-mission"
[ -x "$CLI" ] || { echo "FAIL: $CLI not executable"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export NOTEPAD="$TMP/notepad"
MID="M-TESTGUARD"
D="$NOTEPAD/.df/missions/$MID"
mkdir -p "$D"
printf '# test mission\n' > "$D/MISSION.md"
# A manifest so find_notepad cannot walk past our scratch into a real notepad.
printf '{}\n' > "$NOTEPAD/repos.manifest.json"

run_start() {   # run_start <state> [extra args...] ; echoes rc, stderr into $ERR
  local st="$1"; shift
  printf '%s\n' "$st" > "$D/state"
  ERR="$("$CLI" start "$MID" --profile default --max-iter 1 "$@" 2>&1 >/dev/null)"
  RC=$?
}

# ── each terminal state refuses, asserted one at a time ───────────────────────
for st in BLOCKED DONE STOP; do
  run_start "$st"
  if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -q "REFUSING TO START"; then
    ok "start on $st refuses (rc=$RC)"
  else
    bad "start on $st did NOT refuse" "rc=$RC err=${ERR:0:120}"
  fi
  # The refusal must NAME the state — "it failed" is not an explanation an operator can act on.
  if printf '%s' "$ERR" | grep -q "terminal state $st"; then
    ok "refusal names the state $st"
  else
    bad "refusal did not name $st" "${ERR:0:120}"
  fi
  # ...and must leave the state UNCHANGED. Silently clearing it would erase the one signal
  # that says a human has to decide something.
  #
  # ASSERTED AS A CONJUNCTION, deliberately. Written as a bare "state is still $st" this
  # passed during the RED run too: the BUGGY version also left the state alone, because it
  # forked and died rather than mutating anything. An assertion satisfied by the defect it
  # exists to catch is not evidence — it has to require what the defect LACKS, which here
  # is the refusal, not the absence of a write.
  if [ "$RC" -ne 0 ] && [ "$(cat "$D/state")" = "$st" ]; then
    ok "$st is refused AND left intact"
  else
    bad "$st not both refused and intact" "rc=$RC state=$(cat "$D/state")"
  fi
done

# ── the refusal must point at the way forward ────────────────────────────────
run_start BLOCKED
if printf '%s' "$ERR" | grep -q -- "--resume"; then
  ok "refusal names --resume as the way forward"
else
  bad "refusal offers no way forward" "${ERR:0:160}"
fi

# ── CONTINUE must still start: the guard must not block healthy missions ─────
# Asserted by the ABSENCE of a refusal. This one case is what proves the guard is a guard
# and not a wall; without it, a script that refused everything would score 100%.
printf 'CONTINUE\n' > "$D/state"
ERR="$("$CLI" start "$MID" --profile default --max-iter 1 2>&1 >/dev/null)"
if printf '%s' "$ERR" | grep -q "REFUSING TO START"; then
  bad "guard refused a CONTINUE mission — it is a wall, not a guard"
else
  ok "CONTINUE is not refused"
fi
# Clean up whatever that start forked, so the suite leaves nothing running.
if [ -s "$D/pid" ]; then kill "$(cat "$D/pid")" 2>/dev/null || true; fi

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
