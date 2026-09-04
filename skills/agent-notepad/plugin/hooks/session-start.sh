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

# ---- the newest handoff, emitted FIRST -------------------------------------
# Lifted out of the command substitution 2026-09-04. Two reasons, both measured:
#
#  1. ORDER. The payload is truncated from the END, so the handoff had to move ahead of a
#     275 KB NOTES.md or it is cut. A function is how it gets emitted first without
#     duplicating the block.
#  2. The apostrophe hazard documented below applies INSIDE `$( )`, where bash tracks quote
#     state while scanning for the closing paren. A function body is parsed at definition
#     time, out here, so that trap no longer governs this code. It broke this file twice.
_emit_handoff() {
  local np="$1" newest _hb _cap
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
# ⛔ THE CONTENT, NOT THE NAME. CORRECTED 2026-09-04 AFTER THE POINTER FAILED IN PRODUCTION.
#
# This block used to emit a filename plus: "Read it IF NOTES.md above does not already cover
# where the work stands." MEASURED, on a real /clear: the session read a complete-looking
# NOTES.md, resolved that condition as "covered", never opened the handoff, and answered the
# operator with "session start auto-loads NOTES.md, not the handoff file." The restore looked
# perfectly healthy. THE CONDITIONAL WAS THE DEFECT: a cold reader cannot judge whether the
# Notes cover the work, because not knowing is the state it is in.
#
# ⚠️ THE TOKEN ARGUMENT THAT PRODUCED THE POINTER MEASURED THE WRONG FILE. It cited a 255 KB
# NOTES.md and applied that fear to handoffs. Handoffs on this estate top out around 17 KB
# (~4k tokens) - two orders of magnitude smaller, and the ONE document whose entire purpose is
# to orient a session that has lost its context. Trading it away to save 4k tokens, while
# still cat-ing a 275 KB NOTES.md three lines above, was the wrong economy.
#
# ⚠️ This is what the hook was ALWAYS meant to do: the design record for auto-handoff across
# compaction says "SessionStart hook ... injects the SAVED HANDOFF as additionalContext /
# systemMessage". The pointer was a regression against a written design, not a new tradeoff.
#
# Bounded, because an unbounded read is how the previous defect got in: capped, and the cap
# ANNOUNCES ITSELF when it bites, so a truncated handoff can never look like a whole one.
if [ -d "$np/handoffs" ]; then
  newest="$(ls -t "$np/handoffs"/*.md 2>/dev/null | head -1)"
  if [ -n "$newest" ]; then
    _hb="$(wc -c < "$newest" 2>/dev/null | tr -d ' ')"
    # 24 KB, not 64: this cap and AGENT_NOTEPAD_MAX_BYTES are spent from the SAME harness
    # budget (~67 KB), so two independently-reasonable limits must still sum below it.
    _cap="${AGENT_NOTEPAD_HANDOFF_MAX_BYTES:-24576}"
    printf '\n\n### ⛔ NEWEST HANDOFF — READ THIS FIRST\n\n'
    printf '  file: %s\n' "$newest"
    printf '  handoff written : %s\n' "$(date -u -r "$newest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    # ⚠️ WHICH IS NEWER IS A FACT, NOT A PREFERENCE — so state it rather than asserting a
    # blanket precedence. The first version of this block said the handoff always WINS. That
    # is right when it is the later document and WRONG when the Notes have moved on since:
    # it would trade the old misdirection (handoff never read) for a new one (a stale handoff
    # overriding current Notes). A rule that is correct only half the time is the shape this
    # whole fix exists to remove.
    if [ -f "$np/NOTES.md" ]; then
      printf '  NOTES.md written: %s\n' "$(date -u -r "$np/NOTES.md" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
      if [ "$newest" -nt "$np/NOTES.md" ]; then
        printf '\n  THE HANDOFF IS NEWER THAN THE NOTES. Where they disagree, the handoff wins.\n'
      else
        printf '\n  The NOTES above are NEWER than this handoff. Where they disagree, prefer the\n'
        printf '  Notes for current state — but this handoff still carries the mission framing,\n'
        printf '  the artefact links and the blocked list, which the Notes may not restate.\n'
      fi
    fi
    printf '\n  This is the deliberate checkpoint: where the work stands, the ONE next action,\n'
    printf '  and what is blocked and on whom. Resume from it — do not re-derive it.\n\n'
    printf -- '---8<--- handoff begins ---8<---\n'
    if [ "${_hb:-0}" -gt "$_cap" ]; then
      head -c "$_cap" "$newest"
      printf '\n---8<--- TRUNCATED at %s of %s bytes. THIS IS NOT THE WHOLE HANDOFF -\n' "$_cap" "$_hb"
      printf 'open %s to read the rest before acting. ---8<---\n' "$newest"
    else
      cat "$newest"
      printf '\n---8<--- handoff ends ---8<---\n'
    fi
  fi
fi
}

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
  # ⛔ ORDER IS THE MECHANISM. THE HANDOFF GOES FIRST. MEASURED 2026-09-04.
  #
  # The payload is TRUNCATED before it reaches the model, and truncation cuts from the END —
  # so position in this file IS priority. With a 275 KB NOTES.md emitted first, a cold session
  # received `NOTES: YES / DIGEST: NO / HANDOFF: NO` and ~17k tokens of a ~73k-token payload.
  # Everything after NOTES.md was silently dropped.
  #
  # ⚠️ TWO CORRECT FIXES HAD ALREADY FAILED BECAUSE OF THIS. Injecting the handoff body
  # (#102) and de-duplicating the two hooks (#103) were both right and both invisible: the
  # content was produced, appended last, and cut. A payload that is built correctly and
  # ordered wrongly is indistinguishable from one that was never built.
  #
  # ⚠️ AND THIS RECLASSIFIES THE NOTES.md BLOAT. It is not a token-cost inconvenience; a large
  # NOTES.md ACTIVELY DESTROYS CONTINUITY by crowding out everything behind it. Ordering
  # protects the handoff from that, but it does not fix it — the Notes still lose their own
  # tail. Graduation is still the real repair.
  _emit_handoff "$np"
  # ⛔ BUDGET THE REST, AND ANNOUNCE EVERY CUT. MEASURED 2026-09-05.
  #
  # The harness truncates the payload at a HARD CAP — `cache_read: 16841` tokens, IDENTICAL
  # across two probes with different payload orderings, which is what proves it is a cap and
  # not a coincidence. This hook was emitting 293 KB into it.
  #
  # ⚠️ SO THE HARNESS WAS DOING THE TRUNCATING, SILENTLY. That is the same defect this file
  # already fixes twice — an encoder with an undeclared ceiling — one level up, and it made
  # reordering look like a fix when it was only a TRADE: putting the handoff first bought
  # HANDOFF: YES and immediately cost NOTES: NO.
  #
  # Emitting less than the cap, deliberately, is the only way the reader learns what is
  # missing. A hook that overflows silently cannot tell a session what it did not receive.
  # ⚠️ THE TWO CAPS MUST ADD UP TO LESS THAN THE HARNESS CAP, or they overflow together and
  # neither notices. The handoff cap defaults to 24 KB (handoffs here top out near 17 KB) and
  # this budget to 36 KB: ~60 KB total against the ~67 KB the harness accepts. Two independent
  # limits that each look reasonable alone are how a budget gets blown — the same shape as a
  # glob that is not a superset of the name it derives from.
  _budget="${AGENT_NOTEPAD_MAX_BYTES:-36000}"
  _spent=0
  _emit_bounded() {   # <path> <heading> [fence]
    local f="$1" heading="$2" fence="${3:-}" sz left
    [ -f "$f" ] || return 0
    sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"; sz="${sz:-0}"
    left=$(( _budget - _spent ))
    if [ "$left" -le 512 ]; then
      printf '\n\n### %s — OMITTED, the context budget was already spent\n' "$heading"
      printf '  %s (%s bytes) was NOT injected. Read it yourself before assuming it is empty.\n' "$f" "$sz"
      return 0
    fi
    printf '\n\n### %s\n\n' "$heading"
    [ -n "$fence" ] && printf '```%s\n' "$fence"
    if [ "$sz" -gt "$left" ]; then
      head -c "$left" "$f"
      printf '\n[TRUNCATED at %s of %s bytes — the rest of %s was NOT injected. This is a\n' "$left" "$sz" "$f"
      printf 'PARTIAL document; open it before concluding anything is absent from it.]\n'
      _spent="$_budget"
    else
      cat "$f"
      _spent=$(( _spent + sz ))
    fi
    [ -n "$fence" ] && printf '```\n'
    return 0
  }
  # ⚠️ SMALL-AND-BOUNDED BEFORE LARGE-AND-UNBOUNDED. DIGEST.md and repos.manifest.json are a
  # few KB each and fixed in shape; NOTES.md is the one that grows without limit (286 KB here,
  # against its own declared budget of 150 lines). Emitting NOTES second-to-last would starve
  # both of them to save a tail nobody reads.
  #
  # ⚠️ NOTES.md is LAST on purpose and truncating it from the end is the right cut: its Current
  # goal and Next action live at the TOP, so the first N KB is the operationally useful part.
  # That is a property of the template, not a law — if that layout changes, this ordering has
  # to be revisited rather than trusted.
  _emit_bounded "$np/DIGEST.md"           "DIGEST.md (cross-scope, derived)"
  _emit_bounded "$np/repos.manifest.json" "repos.manifest.json (code repos in scope)" json
  _emit_bounded "$np/NOTES.md"            "NOTES.md"
)"

# --- emit the dual-field SessionStart JSON contract ------------------------
# jq safely encodes the payload (newlines, quotes, backticks).
#
# ⛔ NEVER PASS THE PAYLOAD AS AN ARGV ELEMENT. This line used to be
#     jq -n --arg ctx "$combined"
# and it is DEAD ON LINUX. Linux caps ONE argv element at 128 KB (MAX_ARG_STRLEN,
# 32 pages — a compile-time kernel constant, with no ulimit that raises it); macOS has
# no per-argument cap at all, only a ~1 MB total. So the same NOTES.md that restores
# fine on the maintainer's laptop kills jq on every Coder box and every Linux
# workstation in the fleet:
#
#   session-start.sh: line 147: /usr/bin/jq: Argument list too long
#   exit=0  bytes=109
#
# ⚠️ AND THE HOOK STILL EXITED 0. Measured on the Poland Coder 2026-09-04 against a
# 259 KB NOTES.md: every session on that machine had been starting with ZERO restored
# context, no error the operator would ever see, and a boot block that looked healthy
# because the STATIC context loaded normally. The PreCompact floor kept writing into
# NOTES.md while the injection half silently never delivered it. **A restore that emits
# nothing is indistinguishable from a notepad with nothing to say** — which is why this
# survived an unknown number of sessions until a validation run went looking for it.
#
# ⚠️ Capping the payload is NOT the fix and must not be mistaken for one. A 259 KB
# NOTES.md is a real and separate problem (this estate has a live ticket for it); the
# defect HERE is that the encoder had a hard ceiling it never declared, and crossed it
# in silence. Fixing the size would have hidden this, not repaired it.
#
# `-R` (raw input) + `-s` (slurp) reads the WHOLE of stdin as one JSON string. A pipe has
# no size limit, and `printf` is a bash builtin — so "$combined" never crosses an execve
# boundary at all, at any size.
_json="$(printf '%s' "$combined" | jq -Rs \
  '{systemMessage:., hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:.}}')"
_rc=$?

if [ "$_rc" -eq 0 ] && [ -n "$_json" ]; then
  printf '%s\n' "$_json"
else
  # ⛔ THE ENCODE FAILED — SAY SO IN THE PAYLOAD. DO NOT EMIT NOTHING.
  # This branch is the whole lesson of the bug above. The contract is "exit 0 always", so
  # the payload is the ONLY channel that reaches the session; anything written to stderr
  # is read by nobody. A silent empty restore trains the reader to conclude there was no
  # prior state. Naming the paths costs a few hundred bytes and turns an invisible
  # failure into a recoverable one.
  # This message is short and fixed-size, so --arg is safe HERE and nowhere above.
  jq -n --arg p "$np" '{
    systemMessage: ("⛔ agent-notepad: the SessionStart restore FAILED TO ENCODE and injected NOTHING. This is NOT an empty notepad. Read " + $p + "/NOTES.md and " + $p + "/DIGEST.md yourself before assuming there is no prior state."),
    hookSpecificOutput: {hookEventName:"SessionStart",
      additionalContext: ("⛔ agent-notepad restore FAILED to encode — nothing was injected. Read " + $p + "/NOTES.md manually; do not treat this session as one with no prior state.")}
  }' 2>/dev/null \
    || printf '{"systemMessage":"agent-notepad: SessionStart restore FAILED to encode and injected nothing. Read the notepad NOTES.md manually."}\n'
fi

exit 0
