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
#   AGENT_NOTEPAD_DRY_RUN=1          — no git pull/fetch and no writes of any kind; the full
#                                      payload (including the NOTEPAD RESOLVED / OTHER NOTEPADS
#                                      block below) is still emitted. Implies AGENT_NOTEPAD_NO_PULL.
#   AGENT_NOTEPAD_ROOTS=a:b:c        — extra roots (colon-separated) to scan, one level deep,
#                                      for sibling notepads. The resolved notepad's PARENT
#                                      directory is always scanned too.
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
  # ⛔ SILENCE WAS THE DEFECT, NOT THE `{}`. Resolution is walk-up only, by design: a session is
  # in a notepad or it is not. But a session started in a CODE REPO that some notepad DRIVES
  # (listed in its repos.manifest.json) got `{}` and nothing else -- and the operator's real
  # /clear on 2026-09-08 restored nothing and said nothing, in a repo whose notepad sat one
  # directory over. The kit's own rule ("drive repos via git -C, never cd") means that cwd was
  # wrong by the template's own standard, and the hook was the one thing that could have said so.
  #
  # This does NOT restore from the notepad -- restoring into a session that is not in it would
  # make a wrong cwd look right. It names the notepad and says where to start, in the visible
  # systemMessage, and still emits no context. The scan is the same one the resolved branch
  # uses for OTHER NOTEPADS (AGENT_NOTEPAD_ROOTS + the parents of cwd, two levels deep), and a
  # repo matches by its ORIGIN REMOTE first -- this estate resolves identity by remote, never by
  # directory name -- with the manifest's `path` as the fallback for entries that carry one.
  _hint=""
  _cwd_remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
  _cwd_top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  _roots="$(dirname "$cwd")"$'\n'"$(dirname "$(dirname "$cwd")")"$'\n'"${AGENT_NOTEPAD_ROOTS:-}"
  _roots="$(printf '%s\n' "$_roots" | tr ':' '\n')"
  while IFS= read -r _root; do
    [ -n "$_root" ] && [ -d "$_root" ] || continue
    while IFS= read -r _hit; do
      [ -n "$_hit" ] || continue
      _cand="$(cd "$(dirname "$_hit")" 2>/dev/null && pwd)"
      [ -f "$_cand/repos.manifest.json" ] || continue
      if command -v jq >/dev/null 2>&1; then
        if [ -n "$_cwd_remote" ] && jq -e --arg r "$_cwd_remote" \
             '(.repos // [])[] | select(.remote != null) | select(.remote == $r or (.remote | rtrimstr(".git")) == ($r | rtrimstr(".git")))' \
             "$_cand/repos.manifest.json" >/dev/null 2>&1; then
          _hint="$_cand"; break
        fi
        if jq -e --arg p "${_cwd_top:-$cwd}" \
             '(.repos // [])[] | select(.path != null) | select(.path == $p)' \
             "$_cand/repos.manifest.json" >/dev/null 2>&1; then
          _hint="$_cand"; break
        fi
      fi
    done < <(find "$_root" -maxdepth 2 -name NOTES.md 2>/dev/null)
    [ -n "$_hint" ] && break
  done <<< "$_roots"
  if [ -n "$_hint" ]; then
    jq -n --arg m "agent-notepad: no notepad above $cwd — nothing restored. This directory is a code repo that the notepad $_hint DRIVES (it is in that notepad's repos.manifest.json). Start the session THERE to get its working memory; from here, drive this repo with git -C, never cd." \
      '{systemMessage: $m}'
    exit 0
  fi
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
  # ⛔ DRY RUN MEANS NO NETWORK AND NO WRITES, FULL STOP. This is the single call site in
  # this file that ever touches the network or writes to the notepad's working tree (the
  # three `git ... pull --ff-only` invocations below, across the timeout / gtimeout /
  # portable-watchdog branches). Returning here before any of them run is the entire guard;
  # nothing past this line executes under AGENT_NOTEPAD_DRY_RUN=1.
  [ "${AGENT_NOTEPAD_DRY_RUN:-0}" = "1" ] && return 0
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
    # 3 KB. NOT 24, and not 64 either — both earlier numbers were sized against a budget that
    # does not exist. MEASURED 2026-09-05: the harness externalises the whole payload past a few
    # KB and injects a ~2 KB preview, so a 24 KB handoff is not "mostly delivered", it is
    # delivered as far as the preview and no further. The head of a handoff is its state and its
    # one next action, which is what the cap buys; the WHAT-IS-BELOW block above says whether it is whole, and carries the
    # path to the rest.
    # ⚠️ 3072 was sized when the payload was 28 KB and externalised regardless. Measured 2026-09-05
    # after the right-sizing: the whole 4,486-byte handoff fits at 9,187 bytes total, 4.5 KB under
    # the cliff. A cap that cut the handoff INSIDE its next-action section, mid-word, was the cap
    # doing damage rather than preventing it.
    # MUST equal the _hcap default in the announcements block, or the header says one number
    # and the emission does another -- the exact defect the 2026-09-08 audit measured on the
    # NOTES.md line. Both read the same variable; both default to 4096.
    _cap="${AGENT_NOTEPAD_HANDOFF_MAX_BYTES:-4096}"
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

# ---- other notepads on this machine: DISCLOSURE, not a gate ---------------
# DESIGN §2 Objective 7: SessionStart hooks cannot block a session, and this does not try to
# be one — it never fails, never exits nonzero, and never limits which notepad gets used. It
# only names, in the transcript, which notepad `find_notepad` resolved and whether any other
# notepad sits nearby, so an operator with two notepads on one laptop is not left to guess
# which one a `/clear` restored into.
#
# Scans the resolved notepad's PARENT directory one level deep, plus every root named in
# AGENT_NOTEPAD_ROOTS (colon-separated) if set — never the whole home directory, never a
# hardcoded path.
#
# Defined at top level, like _emit_handoff above, so its comments sit outside the command
# substitution below and the apostrophe/backtick hazard documented there does not apply here.
_scan_other_notepads() {
  local resolved="$1" parent roots root hit dir out seen
  parent="$(dirname "$resolved")"
  out=""
  seen="|$resolved|"
  # ${VAR//…} on an UNSET variable is an unbound-variable error under set -u on bash 5
  # (Linux); bash 3.2 on macOS lets it through. Measured in CI 2026-09-05: the whole boot
  # payload died on the Linux runner while every macOS run was green. Default first.
  local extra="${AGENT_NOTEPAD_ROOTS:-}"
  roots="$parent"$'\n'"${extra//:/$'\n'}"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ -d "$root" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      dir="$(cd "$(dirname "$hit")" 2>/dev/null && pwd)"
      [ -n "$dir" ] || continue
      case "$seen" in *"|$dir|"*) continue ;; esac
      seen="${seen}${dir}|"
      out="${out}  ${dir}   — not chosen: cwd is not under it"$'\n'
    done < <(find "$root" -maxdepth 2 -name NOTES.md 2>/dev/null)
  done <<< "$roots"
  printf '%s' "$out"
}

# --- build the combined context (file reads only) --------------------------
name="$(basename "$np")"
combined="$(
  printf '## agent-notepad — restored working memory (%s)\n' "$name"
  printf 'Objective-scoped working memory, auto-loaded on session start. Resume from '
  printf 'this instead of re-deriving state.\n'
  # DISCLOSURE, NOT A GATE (DESIGN Objective 7). SessionStart cannot block a session and this
  # block does not try to: it always emits, is unconditional, and never changes which notepad
  # is used. It only names the ambiguity in the transcript when it exists, right at the top,
  # before anything else in this payload.
  printf '\n### NOTEPAD RESOLVED\n'
  printf '  %s   (walked up from %s)\n' "$np" "$cwd"
  printf '\n### OTHER NOTEPADS ON THIS MACHINE\n'
  _other_notepads="$(_scan_other_notepads "$np")"
  if [ -n "$_other_notepads" ]; then
    printf '%s' "$_other_notepads"
  else
    printf '  (none found among the scanned roots)\n'
  fi
  # ⛔ THE PAYLOAD MUST FIT, OR NONE OF IT ARRIVES. MEASURED 2026-09-05 on a REAL /clear.
  #
  # The harness externalises an oversized hook payload to a file and injects only a ~2 KB
  # PREVIEW. Observed in one session at 13.7 KB and at 100.4 KB; the laptop /clear reported
  # "Output too large (27.7KB)" and delivered the pointer plus roughly the first 30 lines.
  # Everything after that never entered the session.
  #
  # ⚠️ THIS IS DOWNSTREAM OF EVERY EARLIER FIX, AND IT INVALIDATED THE WAY THEY WERE VERIFIED.
  # #102-#105 measured the bytes the hook EMITS, and the hook emits them correctly. The cut
  # happens at the step the proxy skipped, so a green proxy was a fact about the emitter and
  # not about delivery. **Measure what the SESSION received, never what the hook produced.**
  #
  # ⚠️ PAST THE CAP, SHIPPING MORE BYTES SHIPS FEWER. Inlining the whole handoff and the whole
  # NOTES.md is what pushed the block over the threshold and cost everything after the preview.
  # So the head of this payload is a SMALL, SELF-SUFFICIENT DIGEST that survives any preview:
  # the one next action, and an IMPERATIVE instruction naming the files to open.
  #
  # ⚠️ This is NOT a return to the #102 pointer. That pointer failed because it was CONDITIONAL
  # ("read it IF the Notes do not already cover this") and buried at the END of a payload that
  # was cut anyway. This is unconditional, first, and short enough to always arrive.
  # ⛔ THE WHOLE PARAGRAPH, NOT ONE LINE, AND THE CUT IS ANNOUNCED.
  # The one-line version (awk print-then-exit) injected "All four queued next-actions DISCHARGED
  # 2026-09-05 (Poland Coder session, uncommitted —" and stopped there. The line that followed
  # said "commit needs operator approval. What remains open is the Blockers table only." A cut
  # at an em-dash INVERTED the meaning: the session read "everything is done" and did not open
  # the files this very block had just ordered it to open. Measured on a real operator /clear,
  # 2026-09-05, on both machines.
  _para_after() { # <file> <regex> -- the paragraph following a match, to the first blank line
    awk -v pat="$2" '
      started && !NF { exit }
      matched && NF { started=1 }
      started { print }
      $0 ~ pat { matched=1 }
    ' "$1" 2>/dev/null | head -c 600
  }
  # ⛔ SAY WHAT IS BELOW, NEVER ORDER A READ THAT IS ALREADY DONE. This block used to say
  # "READ THESE FILES NOW" unconditionally. When the handoff is inlined in full (it is, since
  # the cap was raised) that is an instruction contradicting reality, and this estate measured
  # on 2026-04-24 what that produces: the agent follows the RULE over the reality. So each line
  # is decided from the actual byte counts at emit time -- inlined whole, or cut and by how much.
  printf '\n### ⛔ WHAT IS BELOW, AND WHAT IS NOT\n\n'
  _hf=""
  if [ -d "$np/handoffs" ]; then _hf="$(ls -t "$np/handoffs"/*.md 2>/dev/null | head -1)"; fi
  # 4,096 (was 5,120): with the harness cap MEASURED at ~10 KiB on the additionalContext field
  # and ~3.5 KB of framing, a 5 KB handoff left no room for the NOTES reserve. See the budget
  # block below the announcements for the arithmetic.
  _hcap="${AGENT_NOTEPAD_HANDOFF_MAX_BYTES:-4096}"
  if [ -n "$_hf" ]; then
    _hsz="$(wc -c < "$_hf" 2>/dev/null | tr -d ' ')"
    if [ "${_hsz:-0}" -le "$_hcap" ]; then
      printf '  1. HANDOFF — INLINED IN FULL below (%s bytes). No read needed; it is already in\n' "$_hsz"
      printf '     your context.  %s\n' "$_hf"
    else
      printf '  1. HANDOFF — CUT: only %s of %s bytes are below. ⛔ OPEN THIS FILE before acting:\n' "$_hcap" "$_hsz"
      printf '     %s\n' "$_hf"
    fi
  fi
  # ⛔ ONE TOTAL, SPENT IN PRIORITY ORDER, MEASURED — NOT TWO CAPS THAT EACH LOOK REASONABLE.
  #
  # The harness cap on additionalContext was MEASURED on 2026-09-08 with a hook emitting exactly
  # N bytes of numbered markers into a one-turn headless session (project-level hook, real login):
  #   10,000 bytes -> every marker arrived, INLINE
  #   10,500 bytes -> Output too large, persisted to a file, ~2 KB preview (32 markers)
  # (No quotes of either kind in these comments: they sit inside the $( ) substitution.)
  # so the ceiling is in (10,000, 10,500] — almost certainly 10 KiB exactly — and it applies to the
  # additionalContext FIELD, not the whole stdout (the eso laptop delivered a 15.7 KB stdout whose
  # additionalContext was 7.6 KB). Three sessions had guessed this number before: 2,500 (starved
  # NOTES.md and the manifest on every notepad with a 2 KB DIGEST), a comment claiming 36 KB, and a
  # proposal of 6,000 that with a full-size handoff would have overflowed by itself.
  #
  # So: ONE total for the DOCUMENTS (handoff + DIGEST + manifest + NOTES), the handoff takes what
  # it takes up to its own cap, and what is LEFT is the budget for the rest. A short handoff hands
  # its unused bytes to NOTES.md instead of to nobody. AGENT_NOTEPAD_MAX_BYTES still overrides the
  # rest-budget directly, so the suites that pin it keep their meaning.
  #
  # ⚠️ THE FRAMING IS NOT IN THE TOTAL AND IT IS NOT SMALL. Headings, the orientation block, the
  # next-action quote (up to 600 bytes), the other-notepads list, every OMITTED / TRUNCATED notice:
  # measured at ~3,800 bytes with a pathological NOTES.md in the suite (6,600 for documents put
  # the field at 10,110). 6,300 for the documents keeps that worst case under 10,000. The handoff
  # cap is 4,096 so a full-size handoff plus the NOTES reserve still fits: 4,096 + 1,200 + 3,800.
  # Under-spending by a KB is a cost; over-spending by one byte is a 2 KB preview and no restore.
  #
  # ⚠️ NOTES.md GETS A RESERVED SLICE. It is emitted LAST (its top is the useful part, and it grows
  # without limit), and last meant it was the one always OMITTED. Reserving 1,200 bytes means the
  # goal and next action arrive even when DIGEST and the manifest would have spent everything.
  _hoff=0
  if [ -n "$_hf" ]; then _hoff="${_hsz:-0}"; [ "$_hoff" -gt "$_hcap" ] && _hoff="$_hcap"; fi
  _total="${AGENT_NOTEPAD_TOTAL_BYTES:-6300}"
  _default_budget=$(( _total - _hoff ))
  [ "$_default_budget" -lt 1200 ] && _default_budget=1200
  _budget="${AGENT_NOTEPAD_MAX_BYTES:-$_default_budget}"
  _reserve_notes="${AGENT_NOTEPAD_NOTES_MIN_BYTES:-1200}"
  [ "$_reserve_notes" -ge "$_budget" ] && _reserve_notes=$(( _budget / 2 ))
  # ⛔ DECIDED FROM THE SAME NUMBERS _emit_bounded WILL USE, so the announcement and the emission
  # cannot disagree. They did: this line printed NOT-inlined-too-large-for-the-budget for a
  # 174-byte file, unconditionally, directly above a full inline of that file (eso laptop,
  # 2026-09-08). The comment at the top of this block promises each line is decided from the
  # actual byte counts at emit time, and this one was not. NOTES.md is emitted LAST, after
  # DIGEST.md and the manifest digest, so what is left for it is the budget minus those two.
  if [ -f "$np/NOTES.md" ]; then
    _nsz="$(wc -c < "$np/NOTES.md" 2>/dev/null | tr -d ' ')"; _nsz="${_nsz:-0}"
    # Sizes into plain variables FIRST. A $( ) nested inside $(( )) inside this outer $( ),
    # with a jq filter carrying [])[] in single quotes, does not parse on bash 3.2 (macOS):
    # the arithmetic scanner mis-reads the brackets and the whole hook dies with
    # unexpected EOF. Found by hunk-bisecting this very block, 2026-09-08.
    _dsz=0; _msz=0
    if [ -f "$np/DIGEST.md" ]; then
      _dsz="$(wc -c < "$np/DIGEST.md" 2>/dev/null | tr -d ' ')"
    fi
    if [ -f "$np/repos.manifest.json" ] && command -v jq >/dev/null 2>&1; then
      _msz="$(jq -c '{repos: [ (.repos // [])[] | {name, path, remote, branch, role, note} | with_entries(select(.value != null)) ]}' "$np/repos.manifest.json" 2>/dev/null | wc -c | tr -d ' ')"
    fi
    _pre=$(( ${_dsz:-0} + ${_msz:-0} ))
    # DIGEST and the manifest may not spend into the NOTES reserve, so NOTES gets at least it.
    _nleft=$(( _budget - _pre ))
    [ "$_nleft" -lt "$_reserve_notes" ] && _nleft="$_reserve_notes"
    if [ "$_nleft" -le 512 ]; then
      printf '  2. NOTES.md — OMITTED below (%s bytes; DIGEST + manifest already used the budget). ⛔ OPEN IT:  %s\n' "$_nsz" "$np/NOTES.md"
    elif [ "$_nsz" -le "$_nleft" ]; then
      # WHOLE, not INLINED IN FULL: that phrase belongs to the handoff line, and a test asserts
      # it appears exactly once. Two lines with the same words is how a cut handoff got reported
      # as complete by the line beneath it. (No apostrophes here: inside the substitution.)
      printf '  2. NOTES.md — WHOLE below (%s bytes).  %s\n' "$_nsz" "$np/NOTES.md"
    else
      printf '  2. NOTES.md — CUT below: the first ~%s of %s bytes. Its top (goal, next action) is\n' "$_nleft" "$_nsz"
      printf '     there; the tail is not. ⛔ OPEN IT for anything below the fold:  %s\n' "$np/NOTES.md"
    fi
  fi
  printf '\n  Anything below may still be TRUNCATED by the harness. Every cut is ANNOUNCED where\n'
  printf '  it happens; do not conclude a fact is absent because it is not here.\n'
  if [ -f "$np/NOTES.md" ]; then
    _na="$(_para_after "$np/NOTES.md" '[Nn]ext action')"
    if [ -n "$_na" ]; then
      # WARN Framed as a QUOTE, never as the verdict of THIS session. It is copied from a file
      # may be stale, and the reader has to be able to tell those apart.
      printf '\n  NOTES.md quotes its Next action section as:\n'
      printf '%s\n' "$_na" | sed 's/^/    | /'
      if [ "$(printf '%s' "$_na" | wc -c | tr -d ' ')" -ge 600 ]; then
        printf '    | …[CUT at 600 bytes — this quote is INCOMPLETE, open NOTES.md]\n'
      fi
      # ⛔ THE GUARD THAT WAS MISSING. A next-action reading as finished is exactly what stops
      # a session opening the files, and a stale one reads as finished forever.
      printf '\n  ⚠️ That quote may be STALE, and even if it says the work is DONE that is NOT\n'
      printf '     a reason to skip the files above. It is a copy; they are the authority.\n'
    fi
  fi
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
  # ⚠️ THE CAPS MUST ADD UP TO LESS THAN THE HARNESS CAP, or they overflow together and neither
  # notices. That is why _budget is DERIVED above from one measured total minus what the
  # handoff actually took -- not set here as a second independent number. No backticks or
  # apostrophes in this comment: it is inside the $( ) substitution. (This comment used to
  # claim a 24 KB handoff cap, a 36 KB budget and a 67 KB harness; none of the three was what
  # shipped, and the harness ceiling is ~10 KiB. See the measurement above the announcements.)
  _spent=0
  _emit_bounded() {   # <path> <heading> [fence] [reserve-for-later-docs]
    local f="$1" heading="$2" fence="${3:-}" reserve="${4:-0}" sz left
    [ -f "$f" ] || return 0
    sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"; sz="${sz:-0}"
    left=$(( _budget - _spent - reserve ))
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
      _spent=$(( _spent + left ))
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
  _emit_bounded "$np/DIGEST.md"           "DIGEST.md (cross-scope, derived)" "" "$_reserve_notes"
  # WARN THE REPOS, NOT THE EDITORIAL. Measured 2026-09-05: the manifest is 4,504 bytes and 2,090
  # of them are top-level $-prefixed prose about how to EDIT it, placed FIRST. The raw-file cap
  # delivered all of that and ONE of three repo entries, cut mid-word. The repos array projected
  # to its actionable keys is 1,966 bytes for all three. The prose is pointed at, not dropped.
  _emit_manifest() {
    local f="$np/repos.manifest.json" left digest dsz
    [ -f "$f" ] || return 0
    if ! command -v jq >/dev/null 2>&1; then
      _emit_bounded "$f" "repos.manifest.json (code repos in scope)" json "$_reserve_notes"; return 0
    fi
    digest="$(jq -c '{repos: [ (.repos // [])[] | {name, path, remote, branch, role, note} | with_entries(select(.value != null)) ]}' "$f" 2>/dev/null)"
    if [ -z "$digest" ] || [ "$digest" = "null" ]; then
      _emit_bounded "$f" "repos.manifest.json (code repos in scope)" json "$_reserve_notes"; return 0
    fi
    dsz="$(printf '%s' "$digest" | wc -c | tr -d ' ')"
    left=$(( _budget - _spent - _reserve_notes ))
    if [ "$dsz" -gt "$left" ]; then
      _emit_bounded "$f" "repos.manifest.json (code repos in scope)" json "$_reserve_notes"; return 0
    fi
    printf '\n\n### repos.manifest.json — the repos in scope (DIGEST: name/path/remote/branch/role/note)\n\n'
    printf '```json\n'
    printf '%s' "$digest" | jq . 2>/dev/null || printf '%s\n' "$digest"
    printf '```\n'
    printf '  The top-level $-prefixed notes (how to RESOLVE a path, why there is no path key) are\n'
    printf '  NOT injected -- they are for editing the file. Open %s for them.\n' "$f"
    _spent=$(( _spent + dsz ))
    return 0
  }
  _emit_manifest
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
