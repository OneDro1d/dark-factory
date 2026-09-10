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
  local cwd="$1" active="${2:-false}" sid="${3:-x}"
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s,"cwd":"%s"}' "$sid" "$active" "$cwd"
}

mk_owner() {
  local notepad="$1" id="$2" owner="$3"
  printf '%s\n' "$owner" > "$notepad/.df/missions/$id/owner"
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

echo "=== 9: owner file names THIS session (session_id=x) -> blocks exactly as an unowned mission ==="
N9="$T/np9"; mk_notepad "$N9"; mk_running "$N9" "M-TEST-9"
mk_owner "$N9" "M-TEST-9" "x"
O="$(event_json "$N9" false x | run)"
contains "9: still blocks — the owner IS this session" '"decision": "block"' "$O"

echo "=== 10: owner is another session -> {} plus a systemMessage naming the owner, once ==="
N10="$T/np10"; mk_notepad "$N10"; mk_running "$N10" "M-TEST-10"
mk_owner "$N10" "M-TEST-10" "the-other-session"
O="$(event_json "$N10" false x | run)"
absent   "10: no decision — never blocks a non-owner" '"decision"' "$O"
contains "10: systemMessage names the mission" "M-TEST-10" "$O"
contains "10: systemMessage names the owner" "the-other-session" "$O"
O2="$(event_json "$N10" false x | run)"
if [ "$O2" = "{}" ]; then ok "10: the SAME session's second Stop gets bare {} — told once"
else bad "10: second Stop from the same session is silent" "$O2"; fi

echo "=== 11: 'once per session' is per READER, not global — a different session still gets told ==="
N11="$T/np11"; mk_notepad "$N11"; mk_running "$N11" "M-TEST-11"
mk_owner "$N11" "M-TEST-11" "the-other-session"
O="$(event_json "$N11" false session-a | run)"
contains "11: session-a gets the notice" "the-other-session" "$O"
O2="$(event_json "$N11" false session-b | run)"
contains "11: session-b (a different reader) ALSO gets the notice" "the-other-session" "$O2"

echo "=== 12: no owner file at all -> unchanged: still blocks an incomplete handoff ==="
N12="$T/np12"; mk_notepad "$N12"; mk_running "$N12" "M-TEST-12"
O="$(event_json "$N12" false any-session | run)"
contains "12: unowned mission still blocks, regardless of who is asking" '"decision": "block"' "$O"

echo "=== 13: one mission owned ELSEWHERE, one owned by ME with no handoff -> still BLOCKS ==="
# A notice about somebody else's mission must never pre-empt the check on the mission this
# session does own. Sorted order puts the other-owned mission first, which is the shape that
# used to return the notice and skip the rest.
N13="$T/np13"; mk_notepad "$N13"; mk_running "$N13" "M-TEST-13A"; mk_running "$N13" "M-TEST-13B"
mk_owner "$N13" "M-TEST-13A" "the-other-session"
mk_owner "$N13" "M-TEST-13B" "me"
O="$(event_json "$N13" false me | run)"
contains "13: blocks on the mission this session owns" '"decision": "block"' "$O"
contains "13: the block names MY mission, not the other one" "M-TEST-13B" "$O"

echo "=== 14: a RUNNING mission gets an operator-todo.md; no mission, no page; never rewritten ==="
# Operator ruling 2026-09-10. This is the only hook that fires for EVERY attended mission on
# every estate — the plugin registers no SessionStart hook, and attended missions never call
# `df-mission start` — so it is where the page is guaranteed.
N14="$T/np14"; mk_notepad "$N14"; mk_running "$N14" "M-TEST-14"
event_json "$N14" false x | run >/dev/null
if [ -f "$N14/operator-todo.md" ]; then ok "14: the gate created operator-todo.md for a RUNNING mission"
else bad "14: the gate created operator-todo.md for a RUNNING mission" "absent"; fi
contains "14: and it is the tool's own page, rule included" "EVERY LINE HERE IS AN ACTION" "$(cat "$N14/operator-todo.md" 2>/dev/null)"
N14B="$T/np14b"; mk_notepad "$N14B"
event_json "$N14B" false x | run >/dev/null
if [ ! -e "$N14B/operator-todo.md" ]; then ok "14: a notepad with NO running mission is left alone"
else bad "14: a notepad with NO running mission is left alone" "page created"; fi
printf 'hand-edited\n' > "$N14/operator-todo.md"
event_json "$N14" false x | run >/dev/null
contains "14: an existing page is never rewritten" "hand-edited" "$(cat "$N14/operator-todo.md")"
# Headless sessions return before it, on purpose — which is exactly why df-mission start
# creates the page too. Asserted so nobody "fixes" the early return and double-writes.
N14C="$T/np14c"; mk_notepad "$N14C"; mk_running "$N14C" "M-TEST-14C"
event_json "$N14C" false x | ENTRYPOINT=sdk-cli run >/dev/null
if [ ! -e "$N14C/operator-todo.md" ]; then ok "14: headless (sdk-cli) returns first — df-mission start owns that case"
else bad "14: headless (sdk-cli) returns first" "page created"; fi

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
