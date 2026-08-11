#!/usr/bin/env bash
# lib/directive.sh — UserPromptSubmit live-update nudge (Unit 4).
# The soft half of Option B: each turn, remind the model to keep the handoff
# fresh. Backed by the hard PreCompact net (Unit 1) so the guarantee is mechanical.

# build_update_directive CWD -> terse directive text (bounded token tax).
build_update_directive() {
  local hf="$1/.claude/handoff/handoff-latest.md"
  printf 'Handoff continuity: if meaningful work happened since your last handoff update, '
  printf 'rewrite %s now.\n' "$hf"
  printf 'Keep the resume-minimum current: current goal; last decisions; next action; '
  printf 'key file paths; blockers.\n'
  printf 'Bound it to <=120 lines and redact any secrets/keys/PII. Skip if nothing material changed.\n'
}

# emit_user_prompt_json TEXT -> hook JSON (additionalContext only; silent, no systemMessage).
emit_user_prompt_json() {
  jq -n --arg ctx "$1" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$ctx}}'
}
