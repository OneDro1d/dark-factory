#!/usr/bin/env bash
# test-rehydrate-declared-settings.sh — section 4c applies a record's install.settings, ADD-ONLY,
# and applies NOTHING for a record that declares none.
#
# WHY. Two settings cut a session's token spend: `autoCompactWindow` and the default subagent model
# (`env.CLAUDE_CODE_SUBAGENT_MODEL`). One kit declared them in its record and applied them with a
# kit-owned script; every other kit had no step that could. This moves the step into the engine.
# The failure directions pinned here:
#   * OPT-IN: a record with no install.settings must leave settings.json with none of these keys.
#     Moving a pin must never change a machine's behaviour on its own.
#   * ADD-ONLY: a value the operator already set is KEPT and reported, never overwritten.
#   * a `$comment` never reaches the live file; a dry run writes nothing; bad JSON is refused.
#
# THE ASSERTION IS THE LIVE FILE, NOT THE MESSAGE — the same discipline as
# test-rehydrate-wires-hooks.sh.
#
# RED BASELINE, measured against the pre-change rehydrate.sh via REHYDRATE=<old copy> (placed
# beside this engine's scripts): 7 of 16 fail. The 9 that pass there pass VACUOUSLY — "not set",
# "kept", "untouched", "wrote nothing" cannot be violated by a step that does not exist, and
# case D calls the script directly — so nobody should read 9/16 green on the old engine as
# partial coverage. They are over-correction guards on the new step.
#
# Usage: bash boot-kit/scripts/tests/test-rehydrate-declared-settings.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
RH="${REHYDRATE:-$SCRIPTS/rehydrate.sh}"
ADS="$SCRIPTS/apply-declared-settings.py"
[ -f "$RH" ] || { echo "missing $RH"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rhsettings.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A kit with no skills and no hooks; $2 is the install.settings object, or "null" for none.
# `--offline` so nothing is fetched.
kit() {
  K="$TMP/$1"
  mkdir -p "$K/live" "$K/vendor"
  jq -n --argjson s "$2" '{vendorDir:"vendor",upstreams:{},install:(
      {skills:[],skillSources:{},hooks:[],hookSources:{}} + (if $s == null then {} else {settings:$s} end))}' \
    > "$K/loom.lock.json"
}
run() { ( cd "$TMP/$1" && LOOM_LIVE="$TMP/$1/live" bash "$RH" --offline "${@:2}" 2>&1 ); }
live() { jq -c "$2" "$TMP/$1/live/settings.json" 2>/dev/null; }

DECL='{"$comment":"documentation only","autoCompactWindow":300000,"env":{"CLAUDE_CODE_SUBAGENT_MODEL":"sonnet"}}'

echo "=== A: a record that declares NO install.settings sets nothing ==="
kit a null
printf '{"outputStyle":"Loom Voice"}\n' > "$TMP/a/live/settings.json"
O="$(run a)"
contains "A: the no-op is stated" "declares no install.settings" "$O"
eq "A: autoCompactWindow NOT set" "$(live a '.autoCompactWindow')" "null"
eq "A: env NOT created" "$(live a '.env')" "null"
eq "A: the operator's file is untouched" "$(live a '.')" '{"outputStyle":"Loom Voice"}'

echo "=== B: declared keys are ADDED; a value the operator set is KEPT ==="
kit b "$DECL"
printf '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL":"haiku","OTHER":"1"}}\n' > "$TMP/b/live/settings.json"
O="$(run b)"
eq "B: autoCompactWindow added" "$(live b '.autoCompactWindow')" "300000"
eq "B: the operator's subagent model kept" "$(live b '.env.CLAUDE_CODE_SUBAGENT_MODEL')" '"haiku"'
eq "B: an unrelated env var survives" "$(live b '.env.OTHER')" '"1"'
eq "B: \$comment never written" "$(live b 'has("$comment")')" "false"
contains "B: the kept value is reported" "kept yours: env.CLAUDE_CODE_SUBAGENT_MODEL" "$O"
O="$(run b)"
contains "B: a second run changes nothing" "no change" "$O"

echo "=== C: a machine with no settings.json gets both; --dry-run writes nothing ==="
kit c "$DECL"
O="$(run c --dry-run)"
if [ -f "$TMP/c/live/settings.json" ]; then bad "C: --dry-run wrote nothing" "settings.json created"
else ok "C: --dry-run wrote nothing"; fi
contains "C: --dry-run reports what it would add" "+ autoCompactWindow = 300000" "$O"
O="$(run c)"
eq "C: autoCompactWindow set" "$(live c '.autoCompactWindow')" "300000"
eq "C: subagent model set" "$(live c '.env.CLAUDE_CODE_SUBAGENT_MODEL')" '"sonnet"'

echo "=== D: unparseable live JSON is refused and left alone ==="
if [ -f "$ADS" ]; then
  kit d "$DECL"
  printf '{not json' > "$TMP/d/live/settings.json"
  python3 "$ADS" --lock "$TMP/d/loom.lock.json" --live "$TMP/d/live/settings.json" >/dev/null 2>&1; RC=$?
  eq "D: exit 1" "$RC" "1"
  eq "D: the file is untouched" "$(cat "$TMP/d/live/settings.json")" "{not json"
else
  bad "D: apply-declared-settings.py exists" "missing $ADS"
fi

echo
echo "passed $PASS  failed $FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
