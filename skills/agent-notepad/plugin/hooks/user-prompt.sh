#!/usr/bin/env bash
# hooks/user-prompt.sh — UserPromptSubmit live-Notes nudge (DESIGN §7.4).
# The soft half: each turn, remind the model to keep NOTES.md current. The hard
# backstop is the PreCompact floor (pre-compact.sh). Notepad-aware: names the
# concrete NOTES.md path when inside a notepad, otherwise a generic nudge.
# Contract: read stdin JSON, emit additionalContext-only JSON, EXIT 0 ALWAYS.
set -u
_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/notepad.sh
. "$_DIR/../lib/notepad.sh"

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

np="$(find_notepad "$cwd" 2>/dev/null || true)"
if [ -n "$np" ]; then
  ctx="$(printf '%s' \
"agent-notepad continuity: if meaningful work happened since your last update, rewrite $np/NOTES.md now — keep current goal, last decisions, next action, key refs (repo:file:line), blockers. Bound it to <=150 lines, redact secrets/PII, never compress away a caveat. Log durable decisions/findings to the session journal too. Skip if nothing material changed.")"
else
  ctx="$(printf '%s' \
"agent-notepad continuity: keep your working-memory NOTES.md fresh — if meaningful work happened, record current goal, last decisions, next action, key file paths, and blockers (redact secrets/PII). Skip if nothing material changed.")"
fi

jq -n --arg c "$ctx" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}' 2>/dev/null \
  || printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"keep NOTES.md fresh"}}\n'
exit 0
