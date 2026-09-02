#!/bin/bash
# loom-recall-pretool.sh — TIER 1. Promoted 2026-09-02 from two instance repos that each kept their own copy.
#
# WHY THIS IS GENERIC, and it is measured rather than argued: `token-boss/loom-storage` and
# `Michal-Bacia_eso/loom_storage` both carried this file as `local:` content, on different
# estates, with different hubs and different git identities — and the two copies were
# BYTE-IDENTICAL, apart from one reflowed comment line — divergence that is itself evidence of hand-copying rather than of a real difference. Two independent estates converging on the same bytes is what
# "generic" looks like from the outside.
#
# ⚠️ THE ONE BINDING IS THE TEXT, NOT THE MECHANISM. The mechanism — emit a systemMessage on
# this event — is domain-neutral. The store and collection named in the message body are an
# estate's choice. Both estates in the reference fleet name Engram, so the default stays; a
# consumer that uses a different store edits the message in its own layer rather than
# expecting configuration that no one has needed yet.
#
# ⚠️ Never add an endpoint, a token or a hub name to this file. It lives in a PUBLIC repo.
# The hooks promoted here were checked for all three before the move.
# PreToolUse hook: advisory recall reminder before output-side actions.
#
# Fires on Edit / Write / TaskCreate. These are mechanical proxies for the
# cognitive triggers in the loom-recall skill (planning, implementing).
#
# Behavior:
#   - Reads the session transcript path from the hook input (cwd-derived).
#   - Scans the last N turns for any prior memory-search tool call.
#   - If found → silent (exit 0, allow).
#   - If not found → emits a non-blocking system reminder that nudges
#     toward loom-recall before completing the action.
#
# Non-blocking by design: skill enforcement is the cognitive layer; this
# hook is a checkpoint, not a gate. Returning {} allows the action.
#
# The reminder is "additionalContext" appended to the tool call result so
# the model sees it in the next turn iteration, not a block.

INPUT=$(cat)

# Extract session id and tool name. If transcript_path is supplied, use it
# to scan recent turns; otherwise fall back to a session-id-based guess.
eval $(echo "$INPUT" | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
sid = data.get('session_id', '')
tn  = data.get('tool_name', '')
tp  = data.get('transcript_path', '')
safe = lambda s: re.sub(r'[^a-zA-Z0-9_/.\-~]', '', str(s))
print(f'SESSION_ID=\"{safe(sid)}\"')
print(f'TOOL_NAME=\"{safe(tn)}\"')
print(f'TRANSCRIPT_PATH=\"{safe(tp)}\"')
" 2>/dev/null)

TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"

# If we cannot inspect the transcript, fail open (silent allow).
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    echo "{}"
    exit 0
fi

# Scan last 40 lines of the transcript for any memory-search tool name.
# Patterns matched (substring on the JSON line):
#   - engram_search
#   (mempalace_* patterns REMOVED 2026-07-29 — see below)
#   - engram_global_search
#   - engram_neighbors / engram_traverse (graph recall counts)
#
# MemPalace REMOVED 2026-07-29 (Michal: it leaks memory). The mempalace_* patterns are gone
# from this grep on purpose. Leaving them would be worse than cosmetic: a transcript
# mentioning a now-nonexistent tool would satisfy the recall check and suppress the
# reminder, so the gate would silently pass on evidence of a call that cannot happen.
RECENT_RECALL=$(tail -n 40 "$TRANSCRIPT_PATH" 2>/dev/null | grep -cE 'engram_search|engram_global_search|engram_neighbors|engram_traverse')

# grep -c exits 1 when zero matches; output is still "0". Treat empty as 0.
RECENT_RECALL="${RECENT_RECALL:-0}"

if [ "$RECENT_RECALL" -gt 0 ] 2>/dev/null; then
    # Recall happened in this turn or the immediately prior one — silent.
    echo "{}"
    exit 0
fi

# No recent recall. Emit advisory reminder. JSON shape:
#   {"hookSpecificOutput": {"hookEventName": "PreToolUse",
#                           "additionalContext": "..."}}
# This adds a system message visible to the model on the next iteration
# without blocking the current tool call.

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Loom recall checkpoint: about to use ${TOOL_NAME} (output-side action) and no memory search has run in the last ~40 turns. Per the loom-recall skill, the DEFAULT is to search before acting. There is NO general 'mechanical step' or 'user directed it' escape hatch — those rationalizations are explicitly listed in the skill as invalid. Skipping is allowed ONLY for: (1) greetings/acknowledgements, (2) pure language-trivia questions, (3) single-bash-command directives with zero surrounding context. If this turn matches one of those three, you may proceed AND must write ONE SENTENCE in your visible response naming which case applies. If it does NOT match one of the three, run engram_search before continuing — even a coarse query with empty results satisfies the discipline. The search is the discipline, not the result. (Engram is the only memory tier: MemPalace was removed 2026-07-29, so do not call any mempalace_* tool.)"
  }
}
EOF
exit 0
