#!/usr/bin/env bash
# Unit 1 — PreCompact deterministic flush net.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
FIX="$ROOT/fixtures/transcript.jsonl"
. "$HERE/assert.sh"
. "$ROOT/lib/handoff.sh"

test_extract_includes_recent_user_message() {
  local out; out="$(extract_snapshot "$FIX")"
  assert_contains "$out" "session start restore" "recent user msg surfaced"
}

test_extract_includes_touched_files() {
  local out; out="$(extract_snapshot "$FIX")"
  assert_contains "$out" "lib/redact.sh" "edited file surfaced"
  assert_contains "$out" "hooks/pre-compact.sh" "written file surfaced"
}

test_extract_includes_recent_command() {
  local out; out="$(extract_snapshot "$FIX")"
  assert_contains "$out" "go test" "bash command surfaced"
}

test_extract_redacts_secret_in_command() {
  local out; out="$(extract_snapshot "$FIX")"
  assert_not_contains "$out" "sk-secret123ABCdef456GHIjkl789MNOpqr012" "secret in command redacted"
}

test_extract_is_bounded() {
  local out n; out="$(extract_snapshot "$FIX")"
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  assert_le "$n" "120" "snapshot bounded"
}

test_should_flush_when_missing() {
  local f="$HERE/.tmp_missing_$$.md"
  rm -f "$f"
  if should_flush "$f" "$FIX"; then assert_eq "flush" "flush" "missing -> flush"
  else assert_eq "flush" "skip" "missing -> flush"; fi
}

test_should_skip_when_handoff_fresher_than_transcript() {
  local f="$HERE/.tmp_fresh_$$.md"
  printf 'model-written handoff\n' > "$f"
  # make handoff strictly newer than transcript
  touch "$FIX"; sleep 1; touch "$f"
  if should_flush "$f" "$FIX"; then assert_eq "skip" "flush" "fresh -> skip"
  else assert_eq "skip" "skip" "fresh -> skip"; fi
  rm -f "$f"
}

test_should_flush_when_transcript_newer() {
  local f="$HERE/.tmp_stale_$$.md"
  printf 'old handoff\n' > "$f"
  sleep 1; touch "$FIX"
  if should_flush "$f" "$FIX"; then assert_eq "flush" "flush" "stale -> flush"
  else assert_eq "flush" "skip" "stale -> flush"; fi
  rm -f "$f"
}

test_hook_writes_handoff_in_cwd() {
  local sandbox; sandbox="$(mktemp -d)"
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-abc","trigger":"auto"}' "$FIX" "$sandbox" \
    | bash "$ROOT/hooks/pre-compact.sh"
  local hf="$sandbox/.claude/handoff/handoff-latest.md"
  if [ -f "$hf" ]; then assert_eq "exists" "exists" "hook wrote handoff file"
  else assert_eq "exists" "missing" "hook wrote handoff file"; fi
  assert_contains "$(cat "$hf" 2>/dev/null)" "sess-abc" "handoff carries session id"
  rm -rf "$sandbox"
}

test_hook_output_file_bounded() {
  local sb; sb="$(mktemp -d)"; local tx="$sb/t.jsonl"
  awk 'BEGIN{for(i=0;i<500;i++) printf "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"message number %d\"}}\n", i}' > "$tx"
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"s","trigger":"auto"}' "$tx" "$sb" \
    | bash "$ROOT/hooks/pre-compact.sh"
  local n; n="$(wc -l < "$sb/.claude/handoff/handoff-latest.md" | tr -d ' ')"
  assert_le "$n" "120" "on-disk handoff (incl header) bounded to 120 (VR-3)"
  rm -rf "$sb"
}

run_tests
