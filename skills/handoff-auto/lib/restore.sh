#!/usr/bin/env bash
# lib/restore.sh — SessionStart restore helpers (Unit 2).
# Find the cwd-scoped handoff, gate by age, build the resume payload, emit the
# dual-field JSON contract (systemMessage + hookSpecificOutput.additionalContext)
# that the installed SessionStart hook in this environment is known to honor.

# find_handoff CWD -> prints the handoff path if it exists and is non-empty.
find_handoff() {
  local f="$1/.claude/handoff/handoff-latest.md"
  [ -s "$f" ] && printf '%s' "$f"
}

# within_age FILE MAX_AGE_SECONDS -> 0 if within window (or MAX<=0 = unlimited), else 1.
within_age() {
  local f="$1" max="$2" age now mtime
  case "$max" in ''|*[!0-9-]*) max=0 ;; esac
  [ "$max" -le 0 ] && return 0
  now="$(date +%s)"
  mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)"
  [ -z "$mtime" ] && return 0
  age=$(( now - mtime ))
  [ "$age" -le "$max" ]
}

# build_restore_payload FILE -> resume-framed markdown on stdout.
build_restore_payload() {
  printf '## Restored handoff (session continuity)\n'
  printf 'The previous context was compacted or cleared. Resume work from this handoff '
  printf 'instead of re-deriving state:\n\n'
  cat "$1"
}

# emit_session_start_json TEXT -> the hook JSON, with TEXT safely encoded by jq.
emit_session_start_json() {
  jq -n --arg ctx "$1" \
    '{systemMessage:$ctx, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}'
}
