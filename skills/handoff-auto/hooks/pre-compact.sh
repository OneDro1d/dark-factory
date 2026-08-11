#!/usr/bin/env bash
# hooks/pre-compact.sh — PreCompact safety-net (Option B floor).
# Reads hook JSON on stdin. If the live (model-maintained) handoff is missing or
# stale, writes a deterministic snapshot so a handoff ALWAYS exists before
# compaction proceeds (VR-1). Never blocks compaction; always exits 0.
set -u
_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/handoff.sh
. "$_DIR/../lib/handoff.sh"

input="$(cat)"
tp="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
trig="$(printf '%s' "$input" | jq -r '.trigger // "auto"' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

hdir="$cwd/.claude/handoff"
hf="$hdir/handoff-latest.md"
mkdir -p "$hdir" 2>/dev/null || true

if should_flush "$hf" "$tp"; then
  tmp="$hf.tmp.$$"
  {
    printf '<!-- handoff session=%s trigger=%s source=deterministic -->\n' "$sid" "$trig"
    extract_snapshot "$tp"
  } > "$tmp" 2>/dev/null
  mv "$tmp" "$hf" 2>/dev/null || true
fi
exit 0
