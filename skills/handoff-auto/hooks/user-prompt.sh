#!/usr/bin/env bash
# hooks/user-prompt.sh — UserPromptSubmit live-update nudge (Option B soft half).
# Injects a terse directive (additionalContext only, silent) each turn so the
# model keeps the handoff fresh. The PreCompact net (Unit 1) is the hard backstop.
set -u
_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/directive.sh
. "$_DIR/../lib/directive.sh"

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

emit_user_prompt_json "$(build_update_directive "$cwd")"
exit 0
