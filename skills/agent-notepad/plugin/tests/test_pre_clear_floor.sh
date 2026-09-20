#!/usr/bin/env bash
# U8 — the PRE-CLEAR FLOOR: hooks/pre-compact.sh on SessionEnd, and session-start.sh reading the
# floor back on a COLD restore.
#
# ⛔ WHY THIS FILE EXISTS AT ALL. Until now pre-compact.sh had NO behavioural test — only
# test_install.sh asserting it was wired. The floor mechanism itself was unverified, which is why
# "this header says compacted/cleared but nothing is wired on clear" survived for months: every
# check that looked for the FILE passed.
#
# TEMP-ONLY: mktemp -d notepads. Never touches a real notepad or ~/.claude.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PRE="$ROOT/hooks/pre-compact.sh"
SS="$ROOT/hooks/session-start.sh"
. "$HERE/assert.sh"

# A notepad plus a transcript carrying distinctive markers.
_scaffold() { # prints "<np>|<transcript>"
  local base np tp
  base="$(mktemp -d)"
  np="$base/proj-floor"
  mkdir -p "$np/sessions" "$np/handoffs"
  printf '# NOTES\n## Current goal\nNOTES_SENTINEL_FLOOR\n' > "$np/NOTES.md"
  printf '# handoff\nHANDOFF_SENTINEL_FLOOR\n' > "$np/handoffs/2026-09-20-x.md"
  tp="$base/transcript.jsonl"
  {
    printf '{"type":"user","message":{"content":"USERINTENT_MARKER_QUETZAL fix the adapter"}}\n'
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/abs/FILEMARKER_QUETZAL.py"}}]}}\n'
  } > "$tp"
  printf '%s|%s' "$np" "$tp"
}

_fire() { # <event> <extra-json-pair-with-trailing-comma> <np> <tp>
  printf '{"hook_event_name":"%s",%s"cwd":"%s","session_id":"s1","transcript_path":"%s"}' \
    "$1" "$2" "$3" "$4" | bash "$PRE" >/dev/null 2>&1
}

test_sessionend_clear_writes_the_floor() {
  local s np tp
  s="$(_scaffold)"; np="${s%%|*}"; tp="${s##*|}"
  _fire SessionEnd '"reason":"clear",' "$np" "$tp"
  assert_file_exists "$np/PRECOMPACT.md" "SessionEnd(clear) writes the floor"
  assert_contains "$(cat "$np/PRECOMPACT.md")" "USERINTENT_MARKER_QUETZAL" \
    "the floor carries the user intent from the transcript"
  assert_contains "$(cat "$np/PRECOMPACT.md")" "DISCARDED" \
    "the floor says the context was DISCARDED, not summarised"
}

# ⛔ THE GUARD. This is the case that destroys the floor if it regresses: the post-clear session's
# own end fires reason=other against a near-empty transcript, ~900 ms after the good floor was
# written, and the floor is overwrite-in-place.
test_sessionend_other_must_not_touch_the_floor() {
  local s np tp before empty control
  s="$(_scaffold)"; np="${s%%|*}"; tp="${s##*|}"
  _fire SessionEnd '"reason":"clear",' "$np" "$tp"
  before="$(cat "$np/PRECOMPACT.md")"
  empty="$(mktemp)"; : > "$empty"
  _fire SessionEnd '"reason":"other",' "$np" "$empty"
  assert_eq "$before" "$(cat "$np/PRECOMPACT.md")" "SessionEnd(other) leaves the floor byte-identical"
  _fire SessionEnd '"reason":"logout",' "$np" "$empty"
  assert_eq "$before" "$(cat "$np/PRECOMPACT.md")" "SessionEnd(logout) leaves the floor byte-identical"

  # NEGATIVE CONTROL — prove those assertions CAN fail. A guard never observed rejecting anything
  # is indistinguishable from an absent guard. PreCompact is not filtered by reason, so on the
  # SAME empty transcript it MUST overwrite. If it does not, the two assertions above prove
  # nothing at all and this case says so.
  _fire PreCompact '"trigger":"auto",' "$np" "$empty"
  control="$(cat "$np/PRECOMPACT.md")"
  if [ "$control" = "$before" ]; then
    assert_eq "overwritten" "unchanged" \
      "CONTROL: PreCompact on an empty transcript must overwrite — the guard test is vacuous"
  else
    assert_eq "overwritten" "overwritten" \
      "CONTROL fired: the floor IS writable here, so the guard assertions are meaningful"
  fi
}

test_cold_restore_reads_the_floor_back() {
  local s np tp out
  s="$(_scaffold)"; np="${s%%|*}"; tp="${s##*|}"
  _fire SessionEnd '"reason":"clear",' "$np" "$tp"
  out="$(printf '{"hook_event_name":"SessionStart","source":"clear","cwd":"%s"}' "$np" \
    | AGENT_NOTEPAD_NO_PULL=1 bash "$SS")"
  assert_contains "$out" "SESSION FLOOR" "cold restore emits the floor section"
  assert_contains "$out" "USERINTENT_MARKER_QUETZAL" "cold restore carries the floor CONTENT"
  assert_contains "$out" "NOTES_SENTINEL_FLOOR" "cold restore still carries NOTES.md"
}

# ⛔ THE INVARIANT. Cold part 2 begins at the GUARANTEED floor (_reserve_notes), which does not
# depend on the budget or on anything part 1 spent. If a future change makes part 2 start at part
# 1's ACTUAL cut, a stretch of NOTES.md is delivered by NEITHER hook and nothing announces it.
# Overlap is cheap; a gap is silent loss.
test_floor_does_not_move_cold_part2() {
  local s np tp with without
  s="$(_scaffold)"; np="${s%%|*}"; tp="${s##*|}"
  _fire SessionEnd '"reason":"clear",' "$np" "$tp"
  with="$(printf '{"hook_event_name":"SessionStart","source":"clear","cwd":"%s"}' "$np" \
    | AGENT_NOTEPAD_NO_PULL=1 bash "$SS" --part cold-notes)"
  rm -f "$np/PRECOMPACT.md"
  without="$(printf '{"hook_event_name":"SessionStart","source":"clear","cwd":"%s"}' "$np" \
    | AGENT_NOTEPAD_NO_PULL=1 bash "$SS" --part cold-notes)"
  assert_eq "$with" "$without" \
    "cold part 2 is BYTE-IDENTICAL with and without a floor — no gap can open"
}

run_tests
