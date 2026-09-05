#!/usr/bin/env bash
# test-handoff-completeness-gate.sh — the Stop gate must BLOCK an incomplete handoff for a
# RUNNING mission, and must never loop or trap a headless worker doing it.
#
# This hook is a promotion of `mission-completeness-gate.py`'s proven shape (advice ->
# decision), so this suite pins the same two loop guards that hook shipped with, plus the
# new PROBE 3 shape from D1 (§2 objective 3): a decision, not just additionalContext.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SELF/../hooks/handoff-completeness-gate.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output: $3" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

run() { CLAUDE_CODE_ENTRYPOINT="${ENTRYPOINT:-}" python3 "$HOOK"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/hcg.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# --- fixture builders --------------------------------------------------------------------
mk_notepad() {
  local dir="$1"
  mkdir -p "$dir" "$dir/.df/missions" "$dir/handoffs"
  printf 'notes\n' > "$dir/NOTES.md"
}

mk_running() {
  local notepad="$1" id="$2"
  mkdir -p "$notepad/.df/missions/$id"
  printf 'RUNNING\n' > "$notepad/.df/missions/$id/state"
}

# A complete handoff for mission $2, written under $notepad/handoffs/$3
mk_complete_handoff() {
  local notepad="$1" id="$2" name="$3"
  cat > "$notepad/handoffs/$name" <<EOF
# Handoff for mission $id

## Next action
Pick up ticket B6 next.

## Blocked on
Nothing — path is clear.

## Evidence
- tests/test-foo.sh passed, exit 0
EOF
}

event_json() {
  local cwd="$1" active="${2:-false}"
  printf '{"session_id":"x","hook_event_name":"Stop","stop_hook_active":%s,"cwd":"%s"}' "$active" "$cwd"
}

echo "=== 1: PROBE 3 shape — RUNNING mission, NO handoff at all -> decision:block ==="
N1="$T/np1"; mk_notepad "$N1"; mk_running "$N1" "M-TEST-1"
O="$(event_json "$N1" | run)"; rc=$?
if printf '%s' "$O" | grep -q '"decision"'; then ok "1: carries a decision key"
else bad "1: carries a decision key" "$O"; fi
contains "1: decision is block" '"decision": "block"' "$O"
contains "1: reason names the mission id" "M-TEST-1" "$O"
contains "1: reason names the handoff as none" "none" "$O"
contains "1: reason points at the handoff skill" "Skill: handoff" "$O"
if [ "$rc" -eq 0 ]; then ok "1: hook itself exits 0 (a Stop hook must never error)"
else bad "1: hook exits 0" "exit $rc"; fi

echo "=== 2: a complete handoff (3 headings, no placeholders, newer than MAP.md) -> {} ==="
N2="$T/np2"; mk_notepad "$N2"; mk_running "$N2" "M-TEST-2"
printf '# map\n' > "$N2/MAP.md"
sleep 1
mk_complete_handoff "$N2" "M-TEST-2" "2026-09-05-complete.md"
O="$(event_json "$N2" | run)"
if [ "$O" = "{}" ]; then ok "2: emits exactly {}"
else bad "2: emits exactly {}" "$O"; fi

echo "=== 3: TODO under Next action -> block, reason names the check ==="
N3="$T/np3"; mk_notepad "$N3"; mk_running "$N3" "M-TEST-3"
cat > "$N3/handoffs/h.md" <<'EOF'
# Handoff for mission M-TEST-3

## Next action
TODO: figure out what's next.

## Blocked on
Nothing.

## Evidence
- exit 0
EOF
O="$(event_json "$N3" | run)"
contains "3: blocks" '"decision": "block"' "$O"
contains "3: names the placeholder" "TODO" "$O"
contains "3: names the heading it was found under" "next action" "$O"

echo "=== 4: MAP.md newer than the handoff -> block ==="
N4="$T/np4"; mk_notepad "$N4"; mk_running "$N4" "M-TEST-4"
mk_complete_handoff "$N4" "M-TEST-4" "h.md"
sleep 1
printf '# map moved\n' > "$N4/MAP.md"
O="$(event_json "$N4" | run)"
contains "4: blocks"                      '"decision": "block"' "$O"
contains "4: names the map/handoff drift" "MAP.md" "$O"

echo "=== 5: stop_hook_active:true -> {} (never block twice in a row) ==="
N5="$T/np5"; mk_notepad "$N5"; mk_running "$N5" "M-TEST-5"
O="$(event_json "$N5" true | run)"
if [ "$O" = "{}" ]; then ok "5: emits exactly {} on re-entry"
else bad "5: emits exactly {} on re-entry" "$O"; fi

echo "=== 6: CLAUDE_CODE_ENTRYPOINT=sdk-cli -> {} (headless workers don't author handoffs) ==="
N6="$T/np6"; mk_notepad "$N6"; mk_running "$N6" "M-TEST-6"
O="$(event_json "$N6" | ENTRYPOINT=sdk-cli run)"
if [ "$O" = "{}" ]; then ok "6: emits exactly {} under sdk-cli"
else bad "6: emits exactly {} under sdk-cli" "$O"; fi

echo "=== 7: abstains outside a RUNNING mission, and outside a notepad ==="
N7="$T/np7"; mk_notepad "$N7"
mkdir -p "$N7/.df/missions/M-DONE"
printf 'DONE\n' > "$N7/.df/missions/M-DONE/state"
O="$(event_json "$N7" | run)"
if [ "$O" = "{}" ]; then ok "7: state=DONE -> {}"; else bad "7: state=DONE -> {}" "$O"; fi

N7B="$T/np7b"; mk_notepad "$N7B"
O="$(event_json "$N7B" | run)"
if [ "$O" = "{}" ]; then ok "7: no .df at all -> {}"; else bad "7: no .df at all -> {}" "$O"; fi

O="$(event_json "$T/nowhere-no-notepad" | run)"
if [ "$O" = "{}" ]; then ok "7: no notepad found from cwd -> {}"
else bad "7: no notepad found from cwd -> {}" "$O"; fi

echo "=== 8: malformed stdin -> {} plus systemMessage naming an internal error ==="
O="$(printf 'not json' | run)"; rc=$?
contains "8: systemMessage names an internal error" "internal error" "$O"
absent   "8: no decision is asserted over a parse failure" '"decision"' "$O"
if [ "$rc" -eq 0 ]; then ok "8: hook still exits 0"; else bad "8: hook still exits 0" "exit $rc"; fi

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
