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
#   5. commits sessions/ at most once every AGENT_NOTEPAD_SYNC_MIN minutes (default 120),
#   6. best-effort `git -C <notepad> push` (non-blocking, never fails the hook).
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

# --- time-gated journal commit ----------------------------------------------
# ⛔ THE TRAP THIS CLOSES, AND IT WAS THIS HOOK THAT ARMED IT. Until 2026-09-20 this hook
# PUSHED but never COMMITTED. So the journal it writes on EVERY stop stayed uncommitted
# forever, and `git pull --ff-only` (session-start.sh:249) REFUSES on a dirty tree.
# session-start.sh has always said so in its own comment, and even prints "Commit them,
# then pull" to the model — a fix delegated to a reader who never performs it. Meanwhile
# the push had nothing to push and therefore always "succeeded", so the hook looked
# healthy while the machine silently restored STALE Notes on every cold start.
# Measured in the wild: a notepad 20 commits behind for 17 days (Engram `0fd44202`).
#
# ⚠️ THE SCOPE IS DELIBERATELY NARROW: `sessions/` ONLY — the files THIS hook writes.
# It never commits NOTES.md or the model's work in progress. A hook that commits behind
# the model is a surprise commit, and by the dispatch rules the model commits its own work.
# ⛔ SO THIS DOES NOT PROMISE A CLEAN TREE, and must not be described as if it did. It
# removes the one source of dirt that nothing else ever cleans; dirt from in-flight edits
# is still the model's to resolve.
#
# ⚠️ MEASURED 2026-09-20, AND THE WHOLE DESIGN RESTS ON IT: `git commit -- <pathspec>`
# commits the working-tree content of those paths ONLY, and leaves anything else the model
# has staged STILL STAGED (probed: NOTES.md staged before, staged after, absent from the
# commit). It also works on an unborn HEAD. ⛔ Do NOT "simplify" this to a bare `git commit`
# — that would sweep the model's staged work into a hook-authored commit.
#
# ⚠️ THE INTERVAL IS MEASURED FROM THE LAST COMMIT THAT TOUCHED sessions/, not from the
# last commit on the branch. The model commits its own work often, so a bare `git log -1`
# would keep reading those, believe the journal was just synced, and starve it forever.
#
# ⚠️ RESIDUAL, ON A NOTEPAD SHARED BY TWO MACHINES: both sides
# append to sessions/index.json, so committing it means the two histories can genuinely
# DIVERGE, and --ff-only refuses on divergence too. That is still strictly better than
# today (a dirty tree refuses unconditionally, and the tree is dirty every single stop),
# and the tree being clean is what makes the documented union-merge remedy possible at all.
# It is NOT a full fix for shared notepads. Engram `0fd44202` carries the reconcile recipe.
#
#   AGENT_NOTEPAD_SYNC_MIN=<n>  minutes between journal commits (default 120; 0 = every stop)
#   AGENT_NOTEPAD_NO_SYNC=1     disable the commit entirely (the push is unaffected)
_sync_min="${AGENT_NOTEPAD_SYNC_MIN:-120}"
case "$_sync_min" in ''|*[!0-9]*) _sync_min=120 ;; esac

_sync_due=0
if [ "${AGENT_NOTEPAD_NO_SYNC:-0}" != "1" ] \
   && git -C "$np" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ "$_sync_min" -eq 0 ]; then
    _sync_due=1
  else
    # empty on an unborn HEAD or when sessions/ has never been committed -> due now.
    _last="$(git -C "$np" log -1 --format=%ct -- sessions/ 2>/dev/null | tr -d ' ')"
    case "$_last" in
      ''|*[!0-9]*) _sync_due=1 ;;
      *) if [ "$(( $(date +%s) - _last ))" -ge "$(( _sync_min * 60 ))" ]; then _sync_due=1; fi ;;
    esac
  fi
fi

# Foreground, because it is purely local and takes milliseconds — and because a backgrounded
# commit is a race a test cannot assert on. Only the network call below is backgrounded.
# --no-verify: a notepad with its own pre-commit hook must not be able to hang a Stop hook.
# -c commit.gpgsign=false: a signing prompt inside a Stop hook is the same hang class as the
# interactive auth prompt that GIT_TERMINAL_PROMPT=0 exists to prevent.
if [ "$_sync_due" = "1" ]; then
  git -C "$np" add -- sessions/ >/dev/null 2>&1 || true
  git -C "$np" -c commit.gpgsign=false commit -q --no-verify \
      -m "notepad: journal sync ($ts)" -- sessions/ >/dev/null 2>&1 || true
fi

# --- best-effort, non-blocking git push -------------------------------------
# GIT_TERMINAL_PROMPT=0 (2026-07-26): a push that needs credentials must FAIL FAST,
# never sit at an interactive auth prompt inside a Stop hook (another hang class).
# Skip the round trip when there is demonstrably nothing to push. ⚠️ A FAILED count is not
# a zero count: no upstream configured returns rc!=0 and empty, and that must still push.
{
  _ahead="$(git -C "$np" rev-list --count '@{u}..HEAD' 2>/dev/null)"
  if [ "$_ahead" != "0" ]; then
    GIT_TERMINAL_PROMPT=0 git -C "$np" push >/dev/null 2>&1 </dev/null || true
  fi
} &

_allow
