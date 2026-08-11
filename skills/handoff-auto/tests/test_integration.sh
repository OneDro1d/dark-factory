#!/usr/bin/env bash
# Integration — the Option B spine end-to-end (TS-1/TS-2/TS-5).
# transcript -> PreCompact writes handoff -> SessionStart restores it; secrets
# never survive the round trip.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

test_round_trip_precompact_to_sessionstart() {
  local sb tx; sb="$(mktemp -d)"; tx="$sb/transcript.jsonl"
  {
    printf '{"type":"user","message":{"role":"user","content":"continue RESUME_TOKEN_42 work"}}\n'
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"echo password=LEAKED_SECRET_XYZ"}}]}}\n'
  } > "$tx"

  # PreCompact (auto) writes the deterministic floor handoff into the sandbox cwd.
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"s1","trigger":"auto"}' "$tx" "$sb" \
    | bash "$ROOT/hooks/pre-compact.sh"

  local hf="$sb/.claude/handoff/handoff-latest.md"
  assert_contains "$(cat "$hf" 2>/dev/null)" "RESUME_TOKEN_42" "handoff captured user intent"
  assert_not_contains "$(cat "$hf" 2>/dev/null)" "LEAKED_SECRET_XYZ" "secret redacted in handoff (VR-4)"

  # SessionStart restores it post-compaction.
  local out ctx
  out="$(printf '{"source":"compact","cwd":"%s"}' "$sb" | bash "$ROOT/hooks/session-start.sh")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "$ctx" "RESUME_TOKEN_42" "restored context carries user intent"
  assert_contains "$ctx" "Restored handoff" "restored context has resume header"
  assert_not_contains "$ctx" "LEAKED_SECRET_XYZ" "secret absent end-to-end"
  rm -rf "$sb"
}

test_model_written_handoff_is_preserved_over_floor() {
  # If a fresh model-written handoff exists, PreCompact must NOT clobber it with the floor.
  local sb tx; sb="$(mktemp -d)"; tx="$sb/transcript.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"deterministic only"}}\n' > "$tx"
  mkdir -p "$sb/.claude/handoff"
  printf '## model handoff\nRICH_MODEL_CONTENT\n' > "$sb/.claude/handoff/handoff-latest.md"
  sleep 1; touch "$sb/.claude/handoff/handoff-latest.md"  # make handoff newer than transcript
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"s2","trigger":"auto"}' "$tx" "$sb" \
    | bash "$ROOT/hooks/pre-compact.sh"
  assert_contains "$(cat "$sb/.claude/handoff/handoff-latest.md")" "RICH_MODEL_CONTENT" "fresh model handoff preserved"
  rm -rf "$sb"
}

run_tests
