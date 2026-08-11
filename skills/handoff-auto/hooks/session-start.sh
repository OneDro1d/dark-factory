#!/usr/bin/env bash
# hooks/session-start.sh — restore the handoff after compaction / clear (VR-5,6,7).
# Reads hook JSON on stdin; O(1) file read, no compute (latency budget). If a
# cwd-scoped handoff exists within the age window, injects it via the dual-field
# JSON contract. Otherwise no-ops silently.
set -u
_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/restore.sh
. "$_DIR/../lib/restore.sh"

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

hf="$(find_handoff "$cwd")"
[ -z "$hf" ] && exit 0
within_age "$hf" "${HANDOFF_MAX_AGE:-0}" || exit 0

emit_session_start_json "$(build_restore_payload "$hf")"
exit 0
