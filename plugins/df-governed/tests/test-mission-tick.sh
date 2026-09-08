#!/usr/bin/env bash
# test-mission-tick.sh — objective 5: a cron tick reminds the agent a mission is
# unfinished. Style follows boot-kit/scripts/tests/test-identify.sh: PASS/FAIL
# counters, ok/bad/contains/absent helpers, mktemp fixtures, non-zero on failure.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$SELF/.." && pwd)"
SCRIPT="$PLUGIN/bin/mission-tick.sh"
MONITORS="$PLUGIN/monitors/monitors.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mtick.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mknotepad() { mkdir -p "$1"; : > "$1/NOTES.md"; }
mkstate() {
  # $1 dir  $2 mission id  $3 first-line state
  mkdir -p "$1/.df/missions/$2"
  printf '%s\n' "$3" > "$1/.df/missions/$2/state"
}

echo "=== PROBE 5: monitors.json names the command ==="
CMD="$(jq -e -r '.[0].command' "$MONITORS" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$CMD" ]; then ok "PROBE 5: jq -e -r .[0].command exits 0, non-empty"
else bad "PROBE 5: jq -e -r .[0].command exits 0, non-empty" "rc=$rc out='$CMD'"; fi

echo "=== A: DF_TICK_ONCE=1, one RUNNING mission — exactly one line naming it ==="
NP="$T/np-a"; mknotepad "$NP"; mkstate "$NP" "M-PROBE-1" "RUNNING"
OUT="$(cd "$NP" && DF_TICK_ONCE=1 bash "$SCRIPT" 2>&1)"; rc=$?
LINES="$(printf '%s\n' "$OUT" | grep -c 'mission-tick:')"
if [ "$LINES" = "1" ]; then ok "A: exactly one mission-tick line"
else bad "A: exactly one mission-tick line" "got $LINES lines: $OUT"; fi
contains "A: line names the mission id" "M-PROBE-1" "$OUT"
contains "A: line says RUNNING"         "is RUNNING" "$OUT"
if [ "$rc" -eq 0 ]; then ok "A: exits 0"; else bad "A: exits 0" "exit $rc"; fi

echo "=== B: state is DONE — no output ==="
NP="$T/np-b"; mknotepad "$NP"; mkstate "$NP" "M-PROBE-2" "DONE"
OUT="$(cd "$NP" && DF_TICK_ONCE=1 bash "$SCRIPT" 2>&1)"
if [ -z "$OUT" ]; then ok "B: no output for a DONE state"
else bad "B: no output for a DONE state" "got: $OUT"; fi

echo "=== C: notepad found but no .df at all — no output ==="
NP="$T/np-c"; mknotepad "$NP"
OUT="$(cd "$NP" && DF_TICK_ONCE=1 bash "$SCRIPT" 2>&1)"
if [ -z "$OUT" ]; then ok "C: no output with no .df/missions"
else bad "C: no output with no .df/missions" "got: $OUT"; fi

echo "=== D: no notepad above cwd — no output, exit 0 ==="
NP="$T/no-notepad-here"; mkdir -p "$NP"
OUT="$(cd "$NP" && DF_TICK_ONCE=1 bash "$SCRIPT" 2>&1)"; rc=$?
if [ -z "$OUT" ]; then ok "D: no output with no notepad above cwd"
else bad "D: no output with no notepad above cwd" "got: $OUT"; fi
if [ "$rc" -eq 0 ]; then ok "D: exits 0"; else bad "D: exits 0" "exit $rc"; fi

mkowner() {
  # $1 dir  $2 mission id  $3 owner session id
  printf '%s\n' "$3" > "$1/.df/missions/$2/owner"
}
mksession() {
  # $1 dir  $2 filename-fragment (the owner id, so the glob in mission-tick.sh matches)
  mkdir -p "$1/sessions"
  : > "$1/sessions/2026-09-08T000000Z_$2.jsonl"
}

echo "=== H: owner file names THIS session -> fires exactly as an unowned mission would ==="
NP="$T/np-h"; mknotepad "$NP"; mkstate "$NP" "M-PROBE-H" "RUNNING"
mkowner "$NP" "M-PROBE-H" "sess-me"
OUT="$(cd "$NP" && DF_TICK_ONCE=1 CLAUDE_CODE_SESSION_ID=sess-me bash "$SCRIPT" 2>&1)"
contains "H: nudge fires for the owning session" "is RUNNING" "$OUT"
absent   "H: no 'owned by' line for the owner itself" "owned by" "$OUT"

echo "=== I: owner is another session, recently active -> abstain, no nudge ==="
NP="$T/np-i"; mknotepad "$NP"; mkstate "$NP" "M-PROBE-I" "RUNNING"
mkowner "$NP" "M-PROBE-I" "sess-other-1"
mksession "$NP" "sess-other-1"
# ⚠️ STDOUT AND STDERR APART. This script runs as a Monitor: every STDOUT line is a wake-up
# for the session that armed it, and a live owner elsewhere is exactly the case that must
# NOT wake this session. The "owned by" line goes to STDERR (the log), stdout stays EMPTY.
ERR_I="$T/err-i"
OUT="$(cd "$NP" && DF_TICK_ONCE=1 CLAUDE_CODE_SESSION_ID=sess-me bash "$SCRIPT" 2>"$ERR_I")"
[ -z "$OUT" ] && ok "I: STDOUT is empty — no wake-up event for a live owner elsewhere" \
  || bad "I: STDOUT is empty" "stdout: $OUT"
contains "I: stderr names the other session as owner" "owned by" "$(cat "$ERR_I")"
contains "I: stderr names this mission" "M-PROBE-I" "$(cat "$ERR_I")"
absent   "I: no nudge — abstains, does not tell this session to take it" "is RUNNING" "$OUT$(cat "$ERR_I")"

echo "=== J: owner is another session, no session file at all -> stale, fires anyway ==="
NP="$T/np-j"; mknotepad "$NP"; mkstate "$NP" "M-PROBE-J" "RUNNING"
mkowner "$NP" "M-PROBE-J" "sess-other-2"
OUT="$(cd "$NP" && DF_TICK_ONCE=1 CLAUDE_CODE_SESSION_ID=sess-me bash "$SCRIPT" 2>&1)"
contains "J: fires despite an owner, marked stale" "is RUNNING" "$OUT"
contains "J: names the staleness explicitly" "owner may be gone" "$OUT"

echo "=== K: owner is another session, session file present but older than the TTL -> stale ==="
NP="$T/np-k"; mknotepad "$NP"; mkstate "$NP" "M-PROBE-K" "RUNNING"
mkowner "$NP" "M-PROBE-K" "sess-other-3"
mksession "$NP" "sess-other-3"
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$NP/sessions/2026-09-08T000000Z_sess-other-3.jsonl"
OUT="$(cd "$NP" && DF_TICK_ONCE=1 CLAUDE_CODE_SESSION_ID=sess-me DF_OWNER_STALE_HOURS=1 bash "$SCRIPT" 2>&1)"
contains "K: fires once the owner's last write exceeds the TTL" "owner may be gone" "$OUT"

echo "=== E: static read-only assertion — no write outside comments ==="
# Strip full comment lines (first non-space char is #) before scanning for a write:
# a shell redirection ('>' not preceded by '<' and not '>&' — a duplicated file descriptor,
# such as the '>&2' that routes the owned-by line to stderr, writes no file), or
# tee/touch/mkdir/mv/rm/sed -i.
CODE="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
if printf '%s\n' "$CODE" | grep -E '(^|[^<])>([^&]|$)|tee |touch |mkdir |mv |rm |sed -i' >/dev/null; then
  bad "E: mission-tick.sh contains no write" "a forbidden write pattern was found in code"
else
  ok "E: mission-tick.sh contains no write outside comments"
fi

echo "=== F: monitors.json is valid JSON ==="
if jq -e . "$MONITORS" >/dev/null 2>&1; then ok "F: jq -e . monitors.json exits 0"
else bad "F: jq -e . monitors.json exits 0" "jq -e . failed"; fi

echo "=== G: claude plugin validate passes ==="
if command -v claude >/dev/null 2>&1; then
  VOUT="$(claude plugin validate "$PLUGIN" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "G: claude plugin validate exits 0"
  else bad "G: claude plugin validate exits 0" "exit $rc: $VOUT"; fi
else
  printf '  SKIP %s -- %s\n' "G: claude plugin validate" "SKIP (visible, not a pass): claude CLI not on PATH here - the validator runs where the CLI is installed (the invariants suite carries the same check)"
fi

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
