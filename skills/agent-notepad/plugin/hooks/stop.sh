#!/usr/bin/env bash
# hooks/stop.sh — agent-notepad U3: Stop hook, the WRITE end (DESIGN §7.2).
#
# Reads hook JSON on stdin ({transcript_path, cwd, session_id}). If cwd is inside
# a notepad (nearest ancestor with NOTES.md), it:
#   1. resolves/creates this session's append-only journal (one .jsonl per session),
#   2. parses the transcript (jq) for files-touched + commands *since the last stop*
#      (a per-session cursor over transcript line count prevents re-journaling),
#   3. appends deterministic journal entries + a `milestone` stop marker,
#   4. upserts sessions/index.json (turns++, lastInteractionAt, cursor, journalFile),
#   5. best-effort `git -C <notepad> push` (non-blocking, never fails the hook).
#
# Outside a notepad it degrades to a no-op (handoff-auto-style). ALWAYS exits 0
# and prints {} (allow) so it can never block the Stop event.
#
# The former step 5 (mirror into a local memory index) was DELETED 2026-08-03 — see
# the note further down. Durable memory is Engram via deliberate engram_write.
# Engram is a memory store, and it is explained once for this whole repo — see
# starter-kit/instance/AUTHENTICATION.md#engram. Nothing here requires it.
set -u

_DIR="$(cd "$(dirname "$0")" && pwd)"
_ROOT="$(dirname "$_DIR")"
# shellcheck source=../lib/notepad.sh
. "$_ROOT/lib/notepad.sh" 2>/dev/null || true
# shellcheck source=../lib/redact.sh
. "$_ROOT/lib/redact.sh" 2>/dev/null || true

# emit allow + leave, guaranteeing exit 0.
_allow() { printf '{}\n'; exit 0; }

input="$(cat)"
tp="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"
[ -z "$sid" ] && sid="unknown"

# Not in a notepad -> degrade to no-op.
np="$(find_notepad "$cwd" 2>/dev/null)" || np=""
[ -z "$np" ] && _allow

index="$np/sessions/index.json"
[ -f "$index" ] || printf '[]\n' > "$index"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- resolve this session's journal + cursor from the index -----------------
prev_jf="$(jq -r --arg s "$sid" 'map(select(.sessionId==$s))[0].journalFile // empty' "$index" 2>/dev/null)"
prev_cur="$(jq -r --arg s "$sid" 'map(select(.sessionId==$s))[0].cursor // 0' "$index" 2>/dev/null)"
case "$prev_cur" in ''|*[!0-9]*) prev_cur=0 ;; esac

if [ -n "$prev_jf" ] && [ -f "$np/sessions/$prev_jf" ]; then
  jf="$np/sessions/$prev_jf"
else
  jf="$(new_journal_file "$np" "$sid")"
  prev_cur=0
fi
jf_base="$(basename "$jf")"

# --- parse the transcript slice since the last stop -------------------------
total=0
slice=""
if [ -n "$tp" ] && [ -f "$tp" ]; then
  total="$(wc -l < "$tp" 2>/dev/null | tr -d ' ')"
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  if [ "$total" -gt "$prev_cur" ]; then
    slice="$(tail -n +"$((prev_cur + 1))" "$tp" 2>/dev/null)"
  fi
fi

# ⛔ EVERY ENTRY'S TEXT IS REDACTED HERE, before it can reach the journal. The journal is
# committed and pushed, so a credential typed into a command used to land in git verbatim (it
# reached a committed journal, 2026-09). Redacting in the one function every entry passes through
# means a future entry kind cannot forget to.
# ⚠️ FAILS CLOSED: if the redactor did not load, the text is withheld, never written raw.
_emit_entry() { # kind text
  local text
  if command -v redact_secrets >/dev/null 2>&1; then
    text="$(printf '%s' "$2" | redact_secrets)"
  else
    text="[withheld: redactor unavailable]"
  fi
  jq -cn --arg ts "$ts" --arg kind "$1" --arg text "$text" --arg session "$sid" \
    '{ts:$ts, kind:$kind, text:$text, refs:[], commit:null, session:$session}'
}

# files touched (Edit/Write/NotebookEdit) — deduped, in order
if [ -n "$slice" ]; then
  printf '%s\n' "$slice" \
    | jq -r 'select(.type=="assistant") | .message.content
             | (if type=="array" then .[] else empty end)
             | select(.type=="tool_use")
             | select(.name=="Edit" or .name=="Write" or .name=="NotebookEdit")
             | .input.file_path // empty' 2>/dev/null \
    | awk '!seen[$0]++' \
    | while IFS= read -r f; do
        [ -n "$f" ] && append_journal "$jf" "$(_emit_entry file-touch "$f")"
      done

  # bash commands — in order, ONE ENTRY PER COMMAND. Each command travels as a JSON string on one
  # line and is decoded whole, so a multi-line command (a heredoc, a pasted key block) reaches the
  # redactor intact. Split into lines first, the body of a private key would be journaled line by
  # line with nothing around it for a rule to recognise.
  printf '%s\n' "$slice" \
    | jq -c 'select(.type=="assistant") | .message.content
             | (if type=="array" then .[] else empty end)
             | select(.type=="tool_use") | select(.name=="Bash")
             | .input.command // empty' 2>/dev/null \
    | while IFS= read -r cj; do
        c="$(printf '%s' "$cj" | jq -r . 2>/dev/null)"
        [ -n "$c" ] && append_journal "$jf" "$(_emit_entry command "$c")"
      done
fi

# deterministic stop marker — guarantees >=1 new line each cycle
append_journal "$jf" "$(_emit_entry milestone stop)"

# --- upsert sessions/index.json ---------------------------------------------
new_index="$(jq --arg s "$sid" --arg ts "$ts" --arg jf "$jf_base" --argjson cur "${total:-0}" '
  if any(.[]; .sessionId==$s) then
    map(if .sessionId==$s
        then .lastInteractionAt=$ts | .turns=((.turns // 0)+1) | .cursor=$cur | .journalFile=$jf
        else . end)
  else
    . + [{sessionId:$s, startedAt:$ts, lastInteractionAt:$ts, journalFile:$jf, turns:1, cursor:$cur}]
  end' "$index" 2>/dev/null)"
[ -n "$new_index" ] && printf '%s\n' "$new_index" > "$index"

# --- write-mirror: REMOVED 2026-08-03 --------------------------------------
# This used to mirror the journal into a local memory index via bin/mp-adapter.py.
# That memory component was removed 2026-07-29 (it leaked memory), and the mirror had
# already been neutered by env vars (AGENT_NOTEPAD_MEM_STUB=1 +
# AGENT_NOTEPAD_MEMPALACE_BIN=/bin/true) rather than deleted, because the plugin was
# owned by another repo and any file patch would be undone by a reinstall.
#
# The skill now lives in a repo we own, so the dead subsystem is DELETED rather than
# disabled: mp-adapter.py, mirror-guarded.sh and their two tests are gone. Keeping a
# neutered call to a tool that no longer exists is how a reinstall silently
# resurrects it — the same resurrection path a leftover symlink into a
# machine-local checkout represented, in a carry-over hydrate script.
#
# Durable memory now goes to Engram by deliberate engram_write; session continuity
# lives in NOTES.md + this journal.

# --- best-effort, non-blocking git push -------------------------------------
# GIT_TERMINAL_PROMPT=0 (2026-07-26): a push that needs credentials must FAIL FAST,
# never sit at an interactive auth prompt inside a Stop hook (another hang class).
{ GIT_TERMINAL_PROMPT=0 git -C "$np" push >/dev/null 2>&1 </dev/null || true; } &

_allow
