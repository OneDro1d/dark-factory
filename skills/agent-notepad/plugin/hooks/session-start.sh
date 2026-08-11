#!/usr/bin/env bash
# hooks/session-start.sh — agent-notepad SessionStart restore + best-effort pull (U2).
#
# DESIGN §7.1: the READ end of the "actually used" triangle. When cwd is inside a
# notepad, best-effort `git -C <notepad> pull --ff-only` (bounded, non-blocking,
# failure ignored) then FILE-READS-ONLY inject NOTES.md + DIGEST.md (if present) +
# repos.manifest.json via the dual-field SessionStart JSON contract. Outside a
# notepad it emits {} and degrades to handoff-auto behavior.
#
# Hook recipe: read hook JSON on stdin, print {} (allow / no-op) or the injection
# JSON, EXIT 0 ALWAYS. File reads only — no live search, no heavy compute (~1-3s).
#
# Env overrides (tests + operators):
#   AGENT_NOTEPAD_NO_PULL=1          — skip the git pull entirely (hermetic tests)
#   AGENT_NOTEPAD_PULL_TIMEOUT=<sec> — bound the pull (default 3s)
set -u

_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/notepad.sh
. "$_DIR/../lib/notepad.sh"

# --- read cwd from hook stdin (fallback to $PWD) ---------------------------
input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

# --- resolve notepad; degrade to {} outside one ----------------------------
np="$(find_notepad "$cwd")" || np=""
if [ -z "$np" ]; then
  printf '{}\n'
  exit 0
fi

# --- best-effort, bounded, non-blocking git pull ---------------------------
# Never blocks the session: skipped when disabled, when not a git repo, or when
# no remote is configured; otherwise bounded by a timeout / portable watchdog.
# All failures are ignored (best-effort sync, DESIGN §7.1).
_bounded_pull() {
  local dir="$1" secs="${AGENT_NOTEPAD_PULL_TIMEOUT:-3}"
  [ "${AGENT_NOTEPAD_NO_PULL:-0}" = "1" ] && return 0
  [ -d "$dir/.git" ] || return 0
  case "$secs" in ''|*[!0-9]*) secs=3 ;; esac
  # only attempt a pull if at least one remote is configured
  git -C "$dir" remote 2>/dev/null | grep -q . || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" git -C "$dir" pull --ff-only >/dev/null 2>&1 || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" git -C "$dir" pull --ff-only >/dev/null 2>&1 || true
  else
    # portable watchdog: background the pull, kill it if it overruns the budget
    ( git -C "$dir" pull --ff-only >/dev/null 2>&1 ) &
    local pid=$! i=0 lim=$((secs * 10))
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -ge "$lim" ]; then kill "$pid" 2>/dev/null; break; fi
      sleep 0.1
    done
    wait "$pid" 2>/dev/null || true
  fi
  return 0
}
_bounded_pull "$np" || true

# --- build the combined context (file reads only) --------------------------
name="$(basename "$np")"
combined="$(
  printf '## agent-notepad — restored working memory (%s)\n' "$name"
  printf 'Objective-scoped working memory, auto-loaded on session start. Resume from '
  printf 'this instead of re-deriving state.\n'
  if [ -f "$np/NOTES.md" ]; then
    printf '\n### NOTES.md\n\n'
    cat "$np/NOTES.md"
  fi
  if [ -f "$np/DIGEST.md" ]; then
    printf '\n\n### DIGEST.md (cross-scope, derived)\n\n'
    cat "$np/DIGEST.md"
  fi
  if [ -f "$np/repos.manifest.json" ]; then
    printf '\n\n### repos.manifest.json (code repos in scope)\n\n'
    printf '```json\n'
    cat "$np/repos.manifest.json"
    printf '\n```\n'
  fi
)"

# --- emit the dual-field SessionStart JSON contract ------------------------
# jq safely encodes the payload (newlines, quotes, backticks).
jq -n --arg ctx "$combined" \
  '{systemMessage:$ctx, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}'

exit 0
