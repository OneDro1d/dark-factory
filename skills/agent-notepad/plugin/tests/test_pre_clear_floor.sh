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

# ⛔ THE BUDGET INVARIANT — AND WHY 444 GREEN TESTS DID NOT CATCH THE DEFECT THIS PINS.
#
# _scaffold above builds a notepad whose documents total a few hundred bytes. The cold budget is
# NEVER CONTENDED there, so every consumer gets everything it asks for and no overspend is
# possible. The suite was green on the exact code that shipped this bug. A case that cannot fail
# is not a case: this one contends the budget on purpose.
#
# MEASURED 2026-09-20 on the real notepad, first live /clear after this branch was wired: the
# floor emitter never added _fspend to _spent, so DIGEST.md recomputed its slice from _spent=0 and
# took 1,079 bytes the budget had already given away. Field = 10,818 against a cap measured at
# 10 KiB (Engram `9834b409`) ⇒ the harness replaced ALL of part 1 with a ~2 KB preview. The
# restore lost the handoff, the floor and the head of NOTES.md to save a DIGEST slice the verdict
# had already said to drop. ⚠️ AN OVERSPEND IN AN ORDERED BUDGET DOES NOT COST ITS OWN SIZE — it
# costs the whole payload.
_scaffold_contended() { # prints "<np>|<transcript>"
  local base np tp
  base="$(mktemp -d)"
  np="$base/proj-contended"
  mkdir -p "$np/sessions" "$np/handoffs"
  # Each document is far larger than its share, so every one of them must be cut or dropped.
  head -c 40000 /dev/zero | tr '\0' 'N' > "$np/NOTES.md"
  head -c 60000 /dev/zero | tr '\0' 'D' > "$np/DIGEST.md"
  head -c  8000 /dev/zero | tr '\0' 'H' > "$np/handoffs/2026-09-20-x.md"
  tp="$base/transcript.jsonl"
  # >900 bytes of intent so the floor is CAPPED, not merely present.
  {
    printf '{"type":"user","message":{"content":"USERINTENT_MARKER_QUETZAL %s"}}\n' "$(head -c 2000 /dev/zero | tr '\0' 'u')"
  } > "$tp"
  printf '%s|%s' "$np" "$tp"
}

test_cold_field_stays_within_the_harness_cap() {
  local s np tp raw field bytes announced delivered
  command -v jq >/dev/null 2>&1 || { assert_eq skip skip "jq absent — cold-field cap not measured"; return 0; }
  s="$(_scaffold_contended)"; np="${s%%|*}"; tp="${s##*|}"
  _fire SessionEnd '"reason":"clear",' "$np" "$tp"
  raw="$(printf '{"hook_event_name":"SessionStart","source":"clear","cwd":"%s"}' "$np" \
    | AGENT_NOTEPAD_NO_PULL=1 bash "$SS")"
  field="$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext // .additionalContext // empty')"
  bytes="$(printf '%s' "$field" | wc -c | tr -d ' ')"

  # ⛔ THE CONTROL, FIRST. If the scaffold ever stops contending the budget, every assertion below
  # passes for the wrong reason. Prove the squeeze is real before trusting the cap.
  case "$field" in
    *"NOTES.md — CUT"*) assert_eq contended contended "CONTROL: the budget IS contended (NOTES cut)" ;;
    *) assert_eq contended uncontended "CONTROL: scaffold no longer contends the budget — the cap assertion below is vacuous" ;;
  esac

  # 10,240 = the measured ceiling, inside (10,000, 10,500] — Engram `9834b409`, 2026-09-08.
  # It is on the additionalContext FIELD, not on stdout.
  if [ "$bytes" -le 10240 ]; then
    assert_eq within within "cold part 1 field is ${bytes} bytes, within the 10 KiB harness cap"
  else
    assert_eq within "over by $(( bytes - 10240 ))" \
      "cold part 1 field is ${bytes} bytes — OVER the 10 KiB cap, so the harness delivers a 2 KB preview instead"
  fi

  # ⛔ ANNOUNCEMENT AND EMISSION ARE ONE DECISION. The banner's NOTES figure comes from _pre
  # (which counts the floor); the emitter's comes from _spent. They agree only while every
  # emitter records what it spent — which is precisely what regressed. This assertion is
  # version-independent: it pins the invariant, not a byte count that will move.
  announced="$(printf '%s' "$field" | sed -n 's/.*first ~\([0-9]*\) of.*/\1/p' | head -1)"
  delivered="$(printf '%s' "$field" | awk '/TRUNCATED at/ && /NOTES\.md/ {print $3; exit}')"
  assert_eq "${announced:-none}" "${delivered:-none}" \
    "the banner's NOTES.md byte count equals what the emitter actually delivered"
}

# ⛔ THE FLOOR'S AGE IS PART OF THE CLAIM. The banner used to say the floor was "what the previous
# session was doing", which is true after a /clear and FALSE after a restart — `pre-compact.sh`
# writes only for reason=clear, so a restart writes no floor and the reader gets the last clear's.
# Measured 2026-09-20: served a floor two sessions and 44 minutes old under that wording.
# Both directions are asserted here: a fresh floor must NOT be flagged, an old one MUST be.
# A one-sided version of this test would pass on code that never warns at all.
test_stale_floor_is_announced_and_a_fresh_one_is_not() {
  local s np tp fresh aged
  s="$(_scaffold)"; np="${s%%|*}"; tp="${s##*|}"
  _fire SessionEnd '"reason":"clear",' "$np" "$tp"

  fresh="$(printf '{"hook_event_name":"SessionStart","source":"clear","cwd":"%s"}' "$np" \
    | AGENT_NOTEPAD_NO_PULL=1 bash "$SS")"
  case "$fresh" in
    *"WRITTEN "*" MINUTES AGO"*)
      assert_eq quiet flagged "a floor written seconds ago must NOT be called stale" ;;
    *) assert_eq quiet quiet "fresh floor is not flagged" ;;
  esac

  # Age it. `touch -d` is GNU and `touch -t` is portable, so use -t.
  touch -t "$(date -u -v-3H +%Y%m%d%H%M 2>/dev/null || date -u -d '3 hours ago' +%Y%m%d%H%M)" \
    "$np/PRECOMPACT.md" 2>/dev/null || { assert_eq skip skip "cannot age the file here"; return 0; }
  aged="$(printf '{"hook_event_name":"SessionStart","source":"clear","cwd":"%s"}' "$np" \
    | AGENT_NOTEPAD_NO_PULL=1 bash "$SS")"
  case "$aged" in
    *"NOT the session that just ended"*)
      assert_eq flagged flagged "a 3-hour-old floor IS announced as stale" ;;
    *"AGE could not be read"*)
      assert_eq flagged flagged "age unreadable here, and that is ANNOUNCED rather than assumed fresh" ;;
    *) assert_eq flagged quiet \
         "a 3-hour-old floor was served with no staleness notice — the warning cannot fire" ;;
  esac
}

run_tests
