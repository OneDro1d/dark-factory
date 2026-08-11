#!/usr/bin/env bash
# lib/handoff.sh — deterministic snapshot extraction + flush decision (Unit 1).
# Sourced by hooks/pre-compact.sh. Depends on lib/redact.sh.

_HANDOFF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./redact.sh
. "$_HANDOFF_LIB_DIR/redact.sh"

# extract_snapshot TRANSCRIPT_PATH -> markdown resume-minimum on stdout.
# Deterministic (no model): recent user messages, files touched, recent commands.
# Piped through redaction (VR-4) and the line bound (VR-3).
extract_snapshot() {
  local tp="$1" users files cmds
  users="$(jq -r 'select(.type=="user") | .message.content
                  | if type=="string" then .
                    elif type=="array" then (.[] | select(.type=="text") | .text)
                    else empty end' "$tp" 2>/dev/null | tail -5)"
  files="$(jq -r 'select(.type=="assistant") | .message.content[]?
                  | select(.type=="tool_use")
                  | select(.name=="Edit" or .name=="Write" or .name=="Read" or .name=="NotebookEdit")
                  | .input.file_path // empty' "$tp" 2>/dev/null | awk '!seen[$0]++' | tail -20)"
  cmds="$(jq -r 'select(.type=="assistant") | .message.content[]?
                  | select(.type=="tool_use") | select(.name=="Bash")
                  | .input.command // empty' "$tp" 2>/dev/null | tail -10)"
  {
    printf '## Handoff snapshot (deterministic floor)\n\n'
    printf '### Recent user intent\n'
    printf '%s\n' "$users" | sed 's/^/- /'
    printf '\n### Files touched\n'
    printf '%s\n' "$files" | sed 's/^/- /'
    printf '\n### Recent commands\n'
    printf '%s\n' "$cmds" | sed 's/^/- /'
  } | redact_secrets | bound_lines 120
}

# should_flush HANDOFF_FILE TRANSCRIPT_PATH
# exit 0 (flush) if the live handoff is missing/empty OR the transcript is newer
# (work happened since the last write); exit 1 (skip) if the handoff is fresh.
should_flush() {
  local hf="$1" tp="$2"
  [ ! -s "$hf" ] && return 0
  [ -n "$tp" ] && [ "$tp" -nt "$hf" ] && return 0
  return 1
}
