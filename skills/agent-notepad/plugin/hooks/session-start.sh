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
  # ⚠️ BEST-EFFORT, BUT NOT SILENT. A failed pull leaves the session reading STALE Notes while the
  # restore banner looks perfectly healthy — the exact shape of the 2026-09-04 finding where a
  # /clear restored a document seven weeks old and nothing errored.
  #
  # ⛔ AND THE COMMON CAUSE IS MUNDANE: `--ff-only` REFUSES ON A DIRTY TREE, and this notepad's own
  # Stop hook writes sessions/index.json. Measured on a Coder box the same day: its pull had been
  # failing for a full round, so it installed a stale pin and reported success. A machine whose
  # journal has uncommitted entries fails this pull FOREVER, quietly.
  #
  # The failure is recorded and surfaced in the injected payload — where a reader can act on it —
  # rather than written to /dev/null. Still non-blocking, still time-boxed, still returns 0.
  PULL_NOTE=""
  if command -v timeout >/dev/null 2>&1; then
    PULL_ERR="$(timeout "$secs" git -C "$dir" pull --ff-only 2>&1)" || PULL_NOTE="$PULL_ERR"
  elif command -v gtimeout >/dev/null 2>&1; then
    PULL_ERR="$(gtimeout "$secs" git -C "$dir" pull --ff-only 2>&1)" || PULL_NOTE="$PULL_ERR"
  else
    # portable watchdog: background the pull, kill it if it overruns the budget.
    # ⚠️ THIS IS THE LIVE BRANCH ON macOS — neither `timeout` nor `gtimeout` ships there, so this
    # fallback is what actually runs on every Mac. An earlier fix surfaced pull failures in the
    # other two branches and left this one writing to /dev/null, which meant the fix was inert
    # exactly where it was being tested. Keep all three in step.
    _pull_err="$(mktemp)"
    ( git -C "$dir" pull --ff-only >"$_pull_err" 2>&1 ) &
    local pid=$! i=0 lim=$((secs * 10))
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -ge "$lim" ]; then kill "$pid" 2>/dev/null; break; fi
      sleep 0.1
    done
    if ! wait "$pid" 2>/dev/null; then
      PULL_NOTE="$(head -5 "$_pull_err" 2>/dev/null)"
      [ -n "$PULL_NOTE" ] || PULL_NOTE="pull did not complete within ${secs}s"
    fi
    rm -f "$_pull_err"
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
  # ⚠️ SAY SO BEFORE THE NOTES, not after. If the auto-pull failed, everything below may be stale
  # and the reader needs to know that BEFORE reading it as current state.
  if [ -n "${PULL_NOTE:-}" ]; then
    printf '\n### WARNING - the notepad auto-pull FAILED; what follows may be STALE\n\n'
    printf '%s\n' "$PULL_NOTE" | head -5
    printf '\nA common cause is a dirty tree: --ff-only refuses when the journal has uncommitted\n'
    printf 'entries, and this notepad writes sessions/index.json itself. Commit them, then pull.\n'
    printf 'Until then every session starts on whatever these Notes last said.\n'
  fi
  if [ -f "$np/NOTES.md" ]; then
    printf '\n### NOTES.md\n\n'
    cat "$np/NOTES.md"
  fi
  if [ -f "$np/DIGEST.md" ]; then
    printf '\n\n### DIGEST.md (cross-scope, derived)\n\n'
    cat "$np/DIGEST.md"
  fi
  # ⚠️ A POINTER TO THE NEWEST HANDOFF — never the document itself.
  # The deliberate tier was WRITE-ONLY: this hook injected NOTES.md, DIGEST.md and
  # repos.manifest.json and never looked at handoffs/, while skills/handoff/SKILL.md defines a
  # handoff as "the SINGLE ENTRY POINT for a cold session ... the only document a fresh session
  # has to read". Two halves of one skill disagreeing, and the failure is SILENT: the restore
  # fires, looks healthy, and orients the session to whatever NOTES.md last said. MEASURED
  # 2026-09-04 - a /clear restored Notes seven weeks stale while the handoff from that same
  # day went unread. NOTE: no apostrophes in these comments - this block is inside a
  # command substitution, where bash tracks quote state while scanning for the closing
  # paren, so a lone single-quote character in a COMMENT opens a quote that never closes.
  # (This warning is spelled out in words on purpose: the first version of it contained
  # the character it warns about, and broke the file a second time.)
  #
  # ⚠️ THE NAME, NOT THE CONTENT. This hook runs on every session start and already cats three
  # files; this estate has a live ticket about a 255 KB NOTES.md costing ~65k tokens of boot.
  # Injecting handoffs would recreate that cost in a new place. A filename and a date are enough
  # for the session to decide whether to open it.
  if [ -d "$np/handoffs" ]; then
    newest="$(ls -t "$np/handoffs"/*.md 2>/dev/null | head -1)"
    if [ -n "$newest" ]; then
      printf '\n\n### newest handoff (POINTER — not injected)\n\n'
      printf '  %s\n' "$newest"
      printf '  last modified: %s\n' "$(date -u -r "$newest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
      printf '\n  Read it if NOTES.md above does not already cover where the work stands.\n'
      printf '  WARNING - a handoff is NOT auto-read. If NOTES.md is older than this file,\n'
      printf '  the Notes were not refreshed with the handoff and THIS pointer is your only\n'
      printf '  route to the current state.\n'
    fi
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
