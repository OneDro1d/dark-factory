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

echo "=== E: static read-only assertion — no write outside comments ==="
# Strip full comment lines (first non-space char is #) before scanning for a write:
# a shell redirection ('>' not preceded by '<'), or tee/touch/mkdir/mv/rm/sed -i.
CODE="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
if printf '%s\n' "$CODE" | grep -E '(^|[^<])>|tee |touch |mkdir |mv |rm |sed -i' >/dev/null; then
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
  bad "G: claude plugin validate exits 0" "claude CLI not found on PATH"
fi

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
