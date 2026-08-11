#!/usr/bin/env bash
# Unit 2 — SessionStart cwd/age-matched restore injector.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
HOOK="$ROOT/hooks/session-start.sh"
. "$HERE/assert.sh"
. "$ROOT/lib/restore.sh"

_seed() { # cwd marker
  mkdir -p "$1/.claude/handoff"
  printf '## Handoff snapshot\nnext action: %s\n' "$2" > "$1/.claude/handoff/handoff-latest.md"
}

test_emits_handoff_when_present() {
  local sb; sb="$(mktemp -d)"; _seed "$sb" "WIRE_THE_INJECTOR"
  local out; out="$(printf '{"source":"compact","cwd":"%s"}' "$sb" | bash "$HOOK")"
  local ctx; ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "$ctx" "WIRE_THE_INJECTOR" "handoff content injected"
  rm -rf "$sb"
}

test_emits_both_fields_and_event_name() {
  local sb; sb="$(mktemp -d)"; _seed "$sb" "BOTH_FIELDS"
  local out; out="$(printf '{"source":"compact","cwd":"%s"}' "$sb" | bash "$HOOK")"
  assert_contains "$(printf '%s' "$out" | jq -r '.systemMessage')" "BOTH_FIELDS" "systemMessage carries handoff"
  assert_eq "SessionStart" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "event name set"
  rm -rf "$sb"
}

test_has_resume_header() {
  local sb; sb="$(mktemp -d)"; _seed "$sb" "X"
  local out; out="$(printf '{"source":"clear","cwd":"%s"}' "$sb" | bash "$HOOK")"
  assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" "Restored handoff" "resume header present"
  rm -rf "$sb"
}

test_noop_when_absent() {
  local sb; sb="$(mktemp -d)"
  local out; out="$(printf '{"source":"compact","cwd":"%s"}' "$sb" | bash "$HOOK")"
  assert_not_contains "$out" "Restored handoff" "no injection when no handoff"
  rm -rf "$sb"
}

test_cwd_scoping() {
  local a b; a="$(mktemp -d)"; b="$(mktemp -d)"
  _seed "$a" "AAA_MARKER"; _seed "$b" "BBB_MARKER"
  local out; out="$(printf '{"source":"compact","cwd":"%s"}' "$a" | bash "$HOOK")"
  local ctx; ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "$ctx" "AAA_MARKER" "restores own cwd handoff"
  assert_not_contains "$ctx" "BBB_MARKER" "does not leak other cwd handoff"
  rm -rf "$a" "$b"
}

test_age_window_excludes_stale() {
  local sb; sb="$(mktemp -d)"; _seed "$sb" "STALE"
  touch -t 200001010000 "$sb/.claude/handoff/handoff-latest.md"
  local out; out="$(printf '{"source":"compact","cwd":"%s"}' "$sb" | HANDOFF_MAX_AGE=3600 bash "$HOOK")"
  assert_not_contains "$out" "STALE" "stale handoff excluded by age window"
  rm -rf "$sb"
}

test_age_window_unlimited_by_default() {
  local sb; sb="$(mktemp -d)"; _seed "$sb" "OLD_BUT_KEPT"
  touch -t 200001010000 "$sb/.claude/handoff/handoff-latest.md"
  local out; out="$(printf '{"source":"compact","cwd":"%s"}' "$sb" | bash "$HOOK")"
  assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" "OLD_BUT_KEPT" "default = unlimited age"
  rm -rf "$sb"
}

run_tests
