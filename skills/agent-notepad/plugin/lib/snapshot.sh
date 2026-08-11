#!/usr/bin/env bash
# lib/snapshot.sh — deterministic transcript snapshot for the PreCompact floor.
# Sourced by hooks/pre-compact.sh. Depends on lib/redact.sh (same dir).
# Pure read of the transcript JSONL; no model, no side effects.

_SNAP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./redact.sh
. "$_SNAP_LIB_DIR/redact.sh"

# extract_snapshot TRANSCRIPT_PATH -> markdown resume-minimum on stdout.
# Deterministic: recent user intent, files touched, recent commands.
# Piped through redaction + a line bound. Empty/absent transcript => header only.
extract_snapshot() {
  local tp="$1" users files cmds
  if [ -n "$tp" ] && [ -f "$tp" ]; then
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
  fi
  {
    printf '### Recent user intent\n'
    printf '%s\n' "$users" | sed 's/^/- /'
    printf '\n### Files touched\n'
    printf '%s\n' "$files" | sed 's/^/- /'
    printf '\n### Recent commands\n'
    printf '%s\n' "$cmds" | sed 's/^/- /'
  } | redact_secrets | bound_lines 80
}

# should_flush TARGET_FILE TRANSCRIPT_PATH
# exit 0 (flush) if TARGET is missing/empty OR the transcript is newer than it.
should_flush() {
  local f="$1" tp="$2"
  [ ! -s "$f" ] && return 0
  [ -n "$tp" ] && [ -f "$tp" ] && [ "$tp" -nt "$f" ] && return 0
  return 1
}
