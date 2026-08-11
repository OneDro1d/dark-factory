#!/usr/bin/env bash
# Unit 4 — UserPromptSubmit live-update directive (soft nudge).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
HOOK="$ROOT/hooks/user-prompt.sh"
. "$HERE/assert.sh"
. "$ROOT/lib/directive.sh"

_run() { # cwd
  printf '{"cwd":"%s","prompt":"do the thing"}' "$1" | bash "$HOOK"
}

test_emits_valid_json_for_user_prompt_event() {
  local out; out="$(_run /tmp/projX)"
  assert_eq "UserPromptSubmit" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "event name set"
}

test_no_system_message_for_silent_per_turn() {
  local out; out="$(_run /tmp/projX)"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.systemMessage // "null"')" "no systemMessage (silent)"
}

test_directive_targets_cwd_path() {
  local out ctx; out="$(_run /tmp/projX)"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "$ctx" "/tmp/projX/.claude/handoff/handoff-latest.md" "directive targets cwd-scoped path"
}

test_directive_names_resume_minimum() {
  local ctx; ctx="$(build_update_directive /tmp/projX)"
  assert_contains "$ctx" "next action" "resume-minimum: next action"
  assert_contains "$ctx" "blockers" "resume-minimum: blockers"
}

test_directive_states_cap_and_redaction() {
  local ctx; ctx="$(build_update_directive /tmp/projX)"
  assert_contains "$ctx" "120" "states line cap"
  assert_contains "$ctx" "redact" "states redaction"
}

test_directive_is_terse() {
  local ctx n; ctx="$(build_update_directive /tmp/projX)"
  n="$(printf '%s\n' "$ctx" | wc -l | tr -d ' ')"
  assert_le "$n" "12" "directive bounded (token tax)"
}

run_tests
