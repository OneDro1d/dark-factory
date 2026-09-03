#!/usr/bin/env bash
# test-rehydrate-wires-hooks.sh — the restore leg must leave hooks RUNNING, not merely present.
#
# ⛔ WHY THIS EXISTS. rehydrate.sh section 3 copies hook files into $LIVE/hooks. Nothing ran
# them, because nothing named them in $LIVE/settings.json — that instruction lived as prose
# in an installer's MANUAL section. So a machine restored by this script came back with every
# declared hook present, executable, hash-clean and INERT.
#
# ⚠️ THAT IS THE WORST OF THE FOUR STATES, because L1–L8 all pass on it. Measured on
# coder-eso-aws--loom-neptune-arm after a workspace reset wiped ~/.claude: 15 declared,
# 8 wired. The restore leg is precisely where that gap is created.
#
# THE ASSERTION IS THE LIVE FILE, NOT THE MESSAGE. Case A reads settings.json back and demands
# the hook's path be in it. A change that printed "wiring hooks" and wired nothing would pass
# a message-only check and fail this one — the same discipline as
# test-rehydrate-preserves-real-dirs.sh, for the same reason.
#
# Engram is one of the memory stores whose hooks this restores. What it is and how to reach it
# is documented in exactly one place:
# [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
#
# RED BASELINE, measured against the pre-change engine via REHYDRATE=<old copy>: 6 of 10 fail,
# 4 pass VACUOUSLY. The four are over-correction guards — the hook file still lands, __HOME__
# is still substituted, the operator's key still survives, --dry-run still writes nothing —
# and an absent feature cannot violate them. They are named here so nobody reads 4/10 green on
# an unfixed tree as partial coverage.
#
# ⚠️ A FIFTH ASSERTION ALSO PASSED VACUOUSLY AT FIRST and that was a defect in this suite:
# case D matched `gate.sh`, which section 3 already prints when it copies the file. It now
# matches `dry run`, which only the wiring step emits. A vacuous check inside the suite
# written to catch vacuous checks.
#
# Usage: bash boot-kit/scripts/tests/test-rehydrate-wires-hooks.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
RH="${REHYDRATE:-$SCRIPTS/rehydrate.sh}"
[ -f "$RH" ] || { echo "missing $RH"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rhwire.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A kit with one local hook and a template that wires it. `--offline` so nothing is fetched.
kit() {
  K="$TMP/$1"
  mkdir -p "$K/boot-kit/hooks" "$K/boot-kit/config" "$K/live/hooks" "$K/vendor"
  printf '#!/bin/sh\nexit 0\n' > "$K/boot-kit/hooks/gate.sh"
  jq -n '{vendorDir:"vendor",upstreams:{},install:{
      skills:[],skillSources:{},
      hooks:["gate.sh"],hookSources:{"gate.sh":"local:boot-kit/hooks/gate.sh"}}}' \
    > "$K/loom.lock.json"
}
run() { ( cd "$TMP/$1" && LOOM_LIVE="$TMP/$1/live" bash "$RH" --offline 2>&1 ); }

echo "=== A: a restored hook is WIRED, not merely copied ==="
kit a
cat > "$TMP/a/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": { "Stop": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "__HOME__/.claude/hooks/gate.sh" } ] } ] } }
JSON
O="$(run a)"
# the file must land (section 3, unchanged behaviour)
if [ -f "$TMP/a/live/hooks/gate.sh" ]; then ok "A: the hook file is installed"
else bad "A: the hook file is installed" "section 3 regressed"; fi
# ...and the machine must actually run it (section 4, the new behaviour)
if [ -f "$TMP/a/live/settings.json" ]; then ok "A: settings.json now exists"
else bad "A: settings.json now exists" "restore left the machine with nothing wired"; fi
contains "A: the hook is wired in the live settings" "hooks/gate.sh" \
         "$(cat "$TMP/a/live/settings.json" 2>/dev/null)"
# ⚠️ RENDERED, not copied — a literal __HOME__ is a path that cannot exist.
absent   "A: __HOME__ was substituted" "__HOME__" \
         "$(cat "$TMP/a/live/settings.json" 2>/dev/null)"

echo "=== B: a kit with NO settings template is REPORTED, never silently skipped ==="
# ⚠️ A silent skip here would recreate the exact defect this section removes. The kit
# declares a hook and ships no recipe for wiring it — that is a real gap and must be said.
kit b
O="$(run b)"
contains "B: the absence is reported"        "no settings template" "$O"
contains "B: and says what it costs"         "inert"                "$O"

echo "=== C: an existing settings.json is merged, not replaced ==="
kit c
cat > "$TMP/c/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": { "Stop": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "__HOME__/.claude/hooks/gate.sh" } ] } ] } }
JSON
cat > "$TMP/c/live/settings.json" <<'JSON'
{ "model": "keep-me", "hooks": {} }
JSON
O="$(run c)"
contains "C: the operator's own key survives" "keep-me"        "$(cat "$TMP/c/live/settings.json")"
contains "C: and the hook was added"          "hooks/gate.sh"  "$(cat "$TMP/c/live/settings.json")"

echo "=== D: --dry-run wires nothing ==="
kit d
cat > "$TMP/d/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": { "Stop": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "__HOME__/.claude/hooks/gate.sh" } ] } ] } }
JSON
O="$( ( cd "$TMP/d" && LOOM_LIVE="$TMP/d/live" bash "$RH" --offline --dry-run 2>&1 ) )"
if [ -f "$TMP/d/live/settings.json" ]; then
  bad "D: --dry-run writes no settings.json" "it wrote to disk"
else ok "D: --dry-run writes no settings.json"; fi
# ⚠️ ASSERT THE WIRING PHRASE, NOT THE HOOK NAME. `gate.sh` also appears in section 3's copy
# line, so matching it here passed against the UNFIXED engine — a vacuous assertion inside the
# suite written to catch vacuous checks. `dry run` is printed only by the wiring step.
contains "D: but it still says what it would do" "dry run" "$O"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
