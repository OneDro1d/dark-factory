#!/usr/bin/env bash
# hooks/session-start.sh — agent-notepad SessionStart restore + best-effort pull (U2).
#
# Comments below cite Engram document ids as evidence for measured constants. Engram is the
# memory store; what it is and how to reach it is documented in exactly one place:
# [Engram](../../../../starter-kit/instance/AUTHENTICATION.md#engram)
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
# The event's source: startup | resume | clear | compact. Read since 2026-09-18; before that
# every source got the same cold-start payload, including a compaction mid-session.
src="$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)"
# `--part <name>` is a SECOND wiring of this same script, continuing NOTES.md where the main
# part stopped. There are two, one per restore path, and they are NOT interchangeable:
#   --part notes       matcher `compact`              — continues the post-compaction payload
#   --part cold-notes  matcher `startup|resume|clear` — continues the cold payload
# See _compact_part2 / _cold_part2 below for why each path needs a second hook at all.
#
# ⛔ TWO NAMES, NOT ONE WIDER MATCHER, AND THE REASON IS THE INSTALLER. The obvious change was
# to widen the existing `--part notes` entry's matcher to `startup|resume|clear|compact`.
# wire-settings.py merges hooks ADD-ONLY, keyed by `<file> --part <name>` — so on every machine
# that already has `--part notes` wired, a widened matcher in the template is NEVER APPLIED, and
# the entry still reads as wired. The fix would have shipped, pinned, installed and done nothing.
# A distinct `--part` name is a distinct key, so the add-only merge actually adds it.
part="main"
[ "${1:-}" = "--part" ] && part="${2:-main}"
case "$part" in
  main) ;;
  notes)
    if [ "$src" != "compact" ]; then printf '{}\n'; exit 0; fi ;;
  cold-notes)
    if [ "$src" = "compact" ]; then printf '{}\n'; exit 0; fi ;;
  *)
    # An unknown part is a wiring mistake, not a restore. Emitting the MAIN payload for it would
    # duplicate the whole cold restore into the session and look like it worked.
    printf '{}\n'; exit 0 ;;
esac

# --- resolve notepad; degrade to {} outside one ----------------------------
np="$(find_notepad "$cwd")" || np=""
if [ -z "$np" ] && [ "$part" != "main" ]; then
  printf '{}\n'; exit 0
fi
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

# ---- source=compact: the restore a CONTINUING session needs ------------------------------------
# ⛔ ADDED 2026-09-18. Until then a compaction got the cold-start payload: the handoff cut at
# 4,096 bytes and NOTES.md at ~1,200 (measured on HoP: 4,096 of 5,438 and ~1,200 of 14,008), plus
# the NOTEPAD RESOLVED / OTHER NOTEPADS / DIGEST / manifest framing that the compaction summary
# already carries. A session that is CONTINUING needs the opposite trade: the working documents
# whole, and none of the orientation.
#
# ⛔ WHY TWO PARTS, AND NOT ONE 24 KB PAYLOAD. The harness cap is ~10 KiB PER HOOK, on the
# additionalContext field. RE-MEASURED on Claude Code 2.1.276, 2026-09-18, with a hook emitting
# numbered markers into a one-turn session: 9,900 bytes arrived whole, 12,000 bytes were replaced
# by a saved-to-file note with a ~2 KB preview. A bigger single payload delivers LESS. But the cap
# is per hook: two hooks at 9,900 each both arrived whole. So the compact restore is split:
#   part 1 (the normal wiring, source=compact): PRECOMPACT.md floor + the handoff + the NOTES head
#   part 2 (`session-start.sh --part notes`, matcher compact): NOTES.md continued from the exact
#          byte where part 1 stopped
# The hooks run in parallel, so part 2 cannot read what part 1 did; it RE-COMPUTES part 1's cut
# from the same files and the same arithmetic (_compact_part1 is pure). Part 1 alone is complete
# and says what it did not deliver, so a machine without the second wiring degrades, not breaks.
#
# Byte-exact on purpose: LC_ALL=C makes ${#var} count bytes, which is what the cap counts.
# 9,600: 9,900 was measured to arrive whole; the margin covers a multi-byte character at a cut.
_COMPACT_FIELD="${AGENT_NOTEPAD_COMPACT_FIELD_BYTES:-9600}"
NL=$'\n'; NL2=$'\n\n'
_COMPACT_FLOOR_MAX="${AGENT_NOTEPAD_COMPACT_FLOOR_BYTES:-1500}"
_COMPACT_NOTES_MIN="${AGENT_NOTEPAD_COMPACT_NOTES_MIN_BYTES:-1000}"

_compact_chunk() { # <file> <offset> <max> -> bytes [offset, offset+max), cut back to a line end
  local LC_ALL=C f="$1" off="$2" max="$3" s total
  [ "$max" -gt 0 ] || return 0
  s="$(tail -c +"$((off + 1))" "$f" 2>/dev/null | head -c "$max"; printf x)"; s="${s%x}"
  total="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
  if [ $((off + ${#s})) -lt "${total:-0}" ]; then
    case "$s" in *$'\n'*) s="${s%$'\n'*}"$'\n' ;; esac
  fi
  printf '%s' "$s"
}

_P1="" ; _NOTES_USED=0 ; _NOTES_SIZE=0
_compact_part1() { # <np> -> sets _P1 (the payload) and _NOTES_USED (NOTES.md bytes it carries)
  local LC_ALL=C np="$1" hf="" hsz=0 fsz=0 floor="" hbody="" room nb head tail
  [ -d "$np/handoffs" ] && hf="$(ls -t "$np/handoffs"/*.md 2>/dev/null | head -1)"
  [ -n "$hf" ] && hsz="$(wc -c < "$hf" | tr -d ' ')"
  _NOTES_SIZE=0; [ -f "$np/NOTES.md" ] && _NOTES_SIZE="$(wc -c < "$np/NOTES.md" | tr -d ' ')"
  head="$(printf '## agent-notepad — restored after COMPACTION (%s)\n' "$(basename "$np")"
    printf 'Notepad: %s\n' "$np"
    printf 'You are CONTINUING the same session: the summary above carries the orientation, so this\n'
    printf 'restore carries only the working documents, whole where the ~10 KiB hook cap allows:\n'
    printf 'the PreCompact floor, the newest handoff, then NOTES.md (continued by part 2 if wired).\n'
    printf 'Re-check your running Monitor tasks and cron jobs; they normally survive compaction.\n')"
  if [ -f "$np/PRECOMPACT.md" ]; then
    fsz="$(wc -c < "$np/PRECOMPACT.md" | tr -d ' ')"
    # Headings are joined with $NL2 OUTSIDE the substitutions: $( ) strips trailing newlines, and
    # the first version of this ran every heading straight into its body.
    floor="$NL2### PreCompact floor — $np/PRECOMPACT.md$NL2$(_compact_chunk "$np/PRECOMPACT.md" 0 "$_COMPACT_FLOOR_MAX")"
    [ "$fsz" -gt "$_COMPACT_FLOOR_MAX" ] && floor="$floor$(printf '\n[floor CUT at ~%s of %s bytes; open the file for the rest]' "$_COMPACT_FLOOR_MAX" "$fsz")"
  fi
  if [ -n "$hf" ]; then
    # the handoff may use everything except the NOTES minimum and ~600 bytes of framing
    room=$(( _COMPACT_FIELD - ${#head} - ${#floor} - _COMPACT_NOTES_MIN - 600 ))
    hbody="$NL2### ⛔ NEWEST HANDOFF — $hf ($hsz bytes)$NL2"
    if [ "$hsz" -le "$room" ]; then
      hbody="$hbody$(cat "$hf")$NL---8<--- handoff ends: it arrived WHOLE ---8<---"
    else
      hbody="$hbody$(_compact_chunk "$hf" 0 "$room")$NL---8<--- handoff CUT at ~$room of $hsz bytes. OPEN $hf for the rest before acting. ---8<---"
    fi
  else
    hbody="$NL2### Handoff — none in $np/handoffs/"
  fi
  _P1="$head$floor$hbody"
  _NOTES_USED=0
  if [ "$_NOTES_SIZE" -gt 0 ]; then
    nb=$(( _COMPACT_FIELD - ${#_P1} - 420 ))
    tail="$(_compact_chunk "$np/NOTES.md" 0 "$nb")"
    _NOTES_USED=${#tail}
    _P1="$_P1$NL2### NOTES.md — bytes 0-$_NOTES_USED of $_NOTES_SIZE$NL2$tail"
    if [ "$_NOTES_USED" -ge "$_NOTES_SIZE" ]; then
      _P1="$_P1$NL[NOTES.md arrived WHOLE]"
    else
      _P1="$_P1$NL[NOTES.md CUT at byte $_NOTES_USED of $_NOTES_SIZE. Part 2 continues from here if it is wired; either${NL}way, OPEN $np/NOTES.md before relying on anything below the fold.]"
    fi
  fi
}

_compact_part2() { # <np> -> stdout: NOTES.md continued from _NOTES_USED
  local LC_ALL=C np="$1" head body nb
  _compact_part1 "$np"
  [ "$_NOTES_USED" -lt "$_NOTES_SIZE" ] || return 0
  head="$(printf '## agent-notepad — restored after COMPACTION, part 2: NOTES.md continued\n')"
  nb=$(( _COMPACT_FIELD - ${#head} - 400 ))
  body="$(_compact_chunk "$np/NOTES.md" "$_NOTES_USED" "$nb")"
  printf '%s\n\n### NOTES.md — bytes %s-%s of %s\n\n%s' "$head" "$_NOTES_USED" "$(( _NOTES_USED + ${#body} ))" "$_NOTES_SIZE" "$body"
  if [ $(( _NOTES_USED + ${#body} )) -lt "$_NOTES_SIZE" ]; then
    printf '\n[NOTES.md CUT at byte %s of %s. OPEN %s for the rest. It is over its own 150-line budget:\ngraduate the tail, do not rely on the restore to carry it.]' "$(( _NOTES_USED + ${#body} ))" "$_NOTES_SIZE" "$np/NOTES.md"
  else
    printf '\n[NOTES.md: parts 1 and 2 together carried it WHOLE]'
  fi
}

_compact_emit() { # <payload> <systemMessage>
  local j
  j="$(printf '%s' "$1" | jq -Rs --arg m "$2" \
        '{systemMessage:$m, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:.}}')" \
    && [ -n "$j" ] && { printf '%s\n' "$j"; return 0; }
  printf '{"systemMessage":"agent-notepad: the post-compaction restore FAILED to encode; read the notepad handoff and NOTES.md yourself."}\n'
}

if [ "$src" = "compact" ]; then
  # No pull: this is the same session a moment later, and a compaction must not wait on the network.
  if [ "$part" = "notes" ]; then
    _p2="$(_compact_part2 "$np")"
    if [ -n "$_p2" ]; then
      _compact_emit "$_p2" "agent-notepad: post-compaction restore, part 2 (NOTES.md continued)"
    else
      printf '{}\n'
    fi
  else
    _compact_part1 "$np"
    _compact_emit "$_P1" "agent-notepad: post-compaction restore — floor, handoff and NOTES.md re-injected; keep working"
  fi
  exit 0
fi

# --- the COLD budget: computed ONCE, here, read by part 1 AND part 2 -------
#
# ⛔ ONE DECISION, ONE HOME — the same rule the DIGEST verdict block below states, applied one
# level up. These four numbers used to be computed inside the payload substitution, which is a
# subshell: nothing outside could see them, so a second hook had no way to agree with the first.
# Computing them HERE, at top level, means the cold part 1 and the cold part 2 read the SAME
# variables rather than each deriving their own copy. The alternative — part 2 re-deriving the
# arithmetic — is the two-homes-for-one-number defect this file already records three times.
#
# It is PURE: file sizes and environment, no writes, no network. That matters because the hooks
# run in PARALLEL, so part 2 cannot observe anything part 1 did.
_cold_budget() { # <np> -> sets _hf _hsz _hcap _budget _reserve_notes _notes_floor
  # ⚠️ `_hoff` IS DELIBERATELY NOT LOCAL. It is one of the numbers this function computes for its
  # callers, exactly like _hcap/_hsz/_budget/_reserve_notes beside it, and the backstop below needs
  # it to know how far it may trim. It was local, and under `set -u` that made the backstop abort
  # the whole hook — which emits NOTHING and starts the session blind. Caught by the gap test.
  _hoff=0 ; _total=""
  local np="$1" _default_budget _nsz=0
  _hf=""
  if [ -d "$np/handoffs" ]; then _hf="$(ls -t "$np/handoffs"/*.md 2>/dev/null | head -1)"; fi
  # 4,096 (was 5,120): with the harness cap MEASURED at ~10 KiB on the additionalContext field
  # and ~3.5 KB of framing, a 5 KB handoff left no room for the NOTES reserve. See the budget
  # block below the announcements for the arithmetic.
  _hcap="${AGENT_NOTEPAD_HANDOFF_MAX_BYTES:-4096}"
  _hsz=0
  if [ -n "$_hf" ]; then
    _hsz="$(wc -c < "$_hf" 2>/dev/null | tr -d ' ')"; _hsz="${_hsz:-0}"
    _hoff="$_hsz"; [ "$_hoff" -gt "$_hcap" ] && _hoff="$_hcap"
  fi
  # ⛔ 6,100 → 6,000, and THE SECOND CHASE OF THIS CONSTANT IN ONE SESSION IS THE REAL FINDING.
  # The framing is not inside this total, it varies per notepad (the 600-byte next-action quote,
  # the other-notepads list, one line per OMITTED/TRUNCATED verdict), and it grew 159 bytes here
  # purely because NOTES.md was edited. So NO fixed value of `_total` is safe for every notepad:
  # tuning it fixes the notepad you measured and silently mis-sizes the next one.
  # ⇒ THE ACTUAL FIX, NOT DONE HERE: build the payload, measure the FIELD, and if it exceeds the
  # safe ceiling trim the last document (NOTES.md, which is read head-first) by the overage and
  # announce it. That converts a guess into a guarantee. Tracked as a follow-up; this commit only
  # buys headroom for the staleness line, and says so rather than implying the number is right.
  _total="${AGENT_NOTEPAD_TOTAL_BYTES:-6000}"
  _default_budget=$(( _total - _hoff ))
  [ "$_default_budget" -lt 1200 ] && _default_budget=1200
  _budget="${AGENT_NOTEPAD_MAX_BYTES:-$_default_budget}"
  _reserve_notes="${AGENT_NOTEPAD_NOTES_MIN_BYTES:-1200}"
  [ "$_reserve_notes" -ge "$_budget" ] && _reserve_notes=$(( _budget / 2 ))
  # ⛔ THE FLOOR IS A GUARANTEE, NOT A PREDICTION, and that asymmetry is the whole design.
  # Part 1 emits NOTES.md LAST with whatever is left: at least _reserve_notes (DIGEST and the
  # manifest may not spend into it), possibly much more when both of them came in small. Part 2
  # cannot know which happened. So it starts at the GUARANTEED MINIMUM and accepts that its first
  # bytes may repeat what part 1 already carried.
  # ⚠️ OVERLAP IS CHEAP; A GAP IS SILENT LOSS. Starting part 2 at a predicted cut would, whenever
  # the prediction ran high, skip a stretch of NOTES.md that NEITHER hook delivered — and nothing
  # in the transcript would say so. Repeating a kilobyte of the top matter is the safe error.
  _notes_floor=0
  [ -f "$np/NOTES.md" ] && _nsz="$(wc -c < "$np/NOTES.md" 2>/dev/null | tr -d ' ')"
  _nsz="${_nsz:-0}"
  # _emit_bounded OMITS a document outright when fewer than 512 bytes remain, so below that the
  # guaranteed floor is zero, not _reserve_notes.
  if [ "$_reserve_notes" -gt 512 ] && [ "$_nsz" -gt 0 ]; then
    _notes_floor="$_reserve_notes"
    [ "$_notes_floor" -gt "$_nsz" ] && _notes_floor="$_nsz"
  fi
}

_cold_part2() { # <np> -> stdout: NOTES.md continued from the floor part 1 guarantees
  local LC_ALL=C np="$1" head body nb nsz
  nsz=0; [ -f "$np/NOTES.md" ] && nsz="$(wc -c < "$np/NOTES.md" 2>/dev/null | tr -d ' ')"
  nsz="${nsz:-0}"
  [ "$nsz" -gt "$_notes_floor" ] || return 0
  head="$(printf '## agent-notepad — restored working memory, part 2: NOTES.md continued (%s)\n' "$(basename "$np")"
    printf 'Part 1 carried the orientation, the handoff and the HEAD of NOTES.md. Its slice is\n'
    printf 'whatever the budget left after the handoff, DIGEST and the manifest — at least %s\n' "$_notes_floor"
    printf 'bytes, sometimes more, so the first lines below may REPEAT what you already have.\n'
    printf 'That overlap is deliberate: a gap here would be a stretch of NOTES.md that neither\n'
    printf 'hook delivered and nothing announced.\n')"
  nb=$(( _COMPACT_FIELD - ${#head} - 400 ))
  body="$(_compact_chunk "$np/NOTES.md" "$_notes_floor" "$nb")"
  [ -n "$body" ] || return 0
  printf '%s\n\n### NOTES.md — bytes %s-%s of %s\n\n%s' "$head" "$_notes_floor" "$(( _notes_floor + ${#body} ))" "$nsz" "$body"
  if [ $(( _notes_floor + ${#body} )) -lt "$nsz" ]; then
    printf '\n[NOTES.md CUT at byte %s of %s. OPEN %s for the rest. It is over its own 150-line\nbudget: graduate the tail, do not rely on the restore to carry it.]' "$(( _notes_floor + ${#body} ))" "$nsz" "$np/NOTES.md"
  else
    printf '\n[NOTES.md: parts 1 and 2 together carried it WHOLE]'
  fi
}

_cold_budget "$np"

# ⛔ THE COLD PART 2 RETURNS BEFORE THE PULL, ON PURPOSE. Part 1 already does the best-effort
# `git pull --ff-only`, and the two hooks run in PARALLEL: a second pull in this process would
# race part 1 for .git/index.lock and could make part 1's pull fail for no reason. Part 2 reads
# files only. It is also why it is safe for part 2 to read a NOTES.md part 1 may be re-pulling:
# worst case it carries the pre-pull bytes, which is exactly what part 1 carried too.
if [ "$part" = "cold-notes" ]; then
  _p2="$(_cold_part2 "$np")"
  if [ -n "$_p2" ]; then
    _compact_emit "$_p2" "agent-notepad: restore part 2 (NOTES.md continued)"
  else
    printf '{}\n'
  fi
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

# ---- the notepad's credential pre-commit ------------------------------------------------------
# A notepad commits its session journals, and a journal is a transcript. secret-guard.py
# --install-precommit puts a pre-commit in this notepad that re-redacts staged journals and refuses
# any other staged credential (an existing pre-commit is kept as pre-commit.local and still runs).
# Idempotent, local, silent: stdout here is the hook's JSON, so nothing may print. Skipped when the
# guard is not installed and under AGENT_NOTEPAD_DRY_RUN=1, which promises no writes.
_guard="${AGENT_NOTEPAD_SECRET_GUARD:-$HOME/.claude/hooks/secret-guard.py}"
if [ "${AGENT_NOTEPAD_DRY_RUN:-0}" != "1" ] && [ -f "$_guard" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$_guard" --install-precommit "$np" >/dev/null 2>&1 || true
fi

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
# ⛔ CALLABLE, AND A SUBSHELL, so a second pass is byte-for-byte a fresh build. It used to be an
# inline `combined="$( … )"`. Wrapping it changes nothing about what it emits — every `return`
# inside belongs to a nested helper, and `_spent` is re-initialised at the top of the emitters —
# but it lets the BACKSTOP below rebuild the payload once it knows how big the first one came out.
_build_combined() { (
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
  # ⛔ THE FLOOR VERDICT IS COMPUTED HERE, ABOVE ITS OWN ANNOUNCEMENT, because the announcement
  # block that follows runs BEFORE the DIGEST/manifest verdicts further down. The first version of
  # this patch put it beside those and printed _fspend eleven lines before assigning it: under
  # `set -u` that is an unbound-variable death, and the hook is on the session critical path.
  # The rule this file already states applies to ORDER as well as to count — one home, and it has
  # to come before every reader of it.
  _fcap="${AGENT_NOTEPAD_COLD_FLOOR_BYTES:-900}"
  _fsz=0
  [ -f "$np/PRECOMPACT.md" ] && _fsz="$(wc -c < "$np/PRECOMPACT.md" 2>/dev/null | tr -d ' ')"
  _fsz="${_fsz:-0}"
  _fspend=0
  if [ "$_fsz" -gt 0 ] && [ "$_fcap" -gt 0 ]; then
    _fspend="$_fsz"
    [ "$_fspend" -gt "$_fcap" ] && _fspend="$_fcap"
    # never at the cost of the NOTES reserve
    if [ "$_fspend" -gt $(( _budget - _reserve_notes )) ]; then
      _fspend=$(( _budget - _reserve_notes ))
      [ "$_fspend" -lt 0 ] && _fspend=0
    fi
  fi
  printf '\n### ⛔ WHAT IS BELOW, AND WHAT IS NOT\n\n'
  # Announced from the SAME _fspend the emitter uses, per the one-decision-one-home rule that the
  # DIGEST block below states and that this file has already been bitten by twice.
  if [ "${_fspend:-0}" -gt 0 ]; then
    if [ "${_fsz:-0}" -le "${_fspend:-0}" ]; then
      printf '  0. SESSION FLOOR — INLINED IN FULL below (%s bytes): what the session that wrote it\n' "$_fsz"
      printf '     was doing at the moment it ended.  %s\n' "$np/PRECOMPACT.md"
    else
      printf '  0. SESSION FLOOR — CUT: %s of %s bytes below. ⛔ OPEN IT for the rest:  %s\n' "$_fspend" "$_fsz" "$np/PRECOMPACT.md"
    fi
    # ⛔ SAY HOW OLD IT IS, BECAUSE THIS LINE USED TO CLAIM MORE THAN THE FILE SUPPORTS. It read
    # "what the PREVIOUS SESSION was doing", which is true after a /clear and FALSE after a
    # restart: `pre-compact.sh` writes a floor only for SessionEnd reason=clear (the guard that
    # stops a near-empty transcript destroying a good one), so a restart writes NO floor and the
    # reader is served the last CLEAR's — measured 2026-09-20, two sessions and 40 minutes back.
    # ⚠️ SAME DEFECT CLASS AS THE ONE FIXED TWO COMMITS AGO: an announcement asserting more than
    # the artifact supports. There it was "already in your context" for a handoff that was not;
    # here it is "the previous session" for a floor that is older than that. ⛔ A STALE ARTIFACT
    # IS NOT ABSENT — it is wrong AND present, and it is still served, which is harder to notice.
    # The session id cannot decide this (it differs from the current one on BOTH paths). Age can:
    # a /clear writes the floor 20-29 ms before SessionStart, a restart minutes or hours earlier.
    # ⚠️ `date -r <file>` is GNU. On BSD/macOS -r means "seconds since epoch", so it FAILS on a
    # path — hence the `stat -f %m` second try. ⛔ AND THE UNKNOWN CASE IS ANNOUNCED, NOT ASSUMED
    # FRESH: the first draft fell back to "now", which makes the age 0 and the warning silently
    # never fire. A warning that cannot fire is indistinguishable from one that is absent, and
    # this file would have shipped it to every macOS install without a single failing test.
    _fmt="$(date -r "$np/PRECOMPACT.md" +%s 2>/dev/null || stat -f %m "$np/PRECOMPACT.md" 2>/dev/null || true)"
    case "$_fmt" in
      ''|*[!0-9]*)
        printf '     ⚠️ AGE UNREADABLE here — may predate the session that just ended; see its header.\n' ;;
      *)
        _fage=$(( $(date +%s) - _fmt ))
        # ⚠️ ONE LINE, DELIBERATELY. The framing is NOT inside _total, so anything printed here is
        # an UNBUDGETED consumer of the same field the documents are rationed out of — the exact
        # shape of the overspend fixed two commits ago. Measured: the two-line draft took this
        # notepad's field from 9,928 to ~10,078, back into the unverified (10,000, 10,500] band.
        # It fires only on the restart path, and a worst case that only happens sometimes is still
        # the worst case a hard cap is judged by.
        if [ "$_fage" -gt 120 ]; then
          printf '     ⚠️ WRITTEN %s MIN AGO — NOT the session that just ended; a restart writes no floor.\n' "$(( _fage / 60 ))"
        fi ;;
    esac
  fi
  # _hf, _hsz and _hcap come from _cold_budget, which ran at top level. They used to be computed
  # HERE, inside this subshell, which is why part 2 could not agree with part 1 about anything.
  if [ -n "$_hf" ]; then
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
  # the field at 10,110). The handoff cap is 4,096 so a full-size handoff plus the NOTES reserve
  # still fits: 4,096 + 1,200 + 3,800.
  # Under-spending by a KB is a cost; over-spending by one byte is a 2 KB preview and no restore.
  #
  # ⛔ 6,300 → 6,100, MEASURED 2026-09-20. The line above used to end "6,300 for the documents
  # keeps that worst case under 10,000" and ITS OWN ARITHMETIC REFUTES IT: 6,300 + 3,800 = 10,100.
  # On the real notepad, framing measured 3,754 and the field came out at 10,054.
  # ⚠️ THAT IS NOT SAFE JUST BECAUSE IT IS UNDER 10,240. The cap was measured as an INTERVAL —
  # 10,000 arrived, 10,500 did not (`9834b409`) — so everything in (10,000, 10,500] is UNVERIFIED,
  # and 10,054 sits inside it. 10 KiB is the best guess at the ceiling, never an observation.
  # ⚠️ The failure is not graceful: one byte over and the WHOLE field becomes a 2 KB preview, so
  # the right target is the largest value actually OBSERVED to arrive (~9,900, `2fc96e95`), not
  # the smallest believed to fail. 6,100 + 3,800 = 9,900. It costs NOTES.md 200 cold bytes and
  # buys delivery certainty — and against a floor, those 200 bytes were never the binding
  # constraint on what NOTES.md carries; ORDER is (`a3af5e14`).
  #
  # ⚠️ NOTES.md GETS A RESERVED SLICE. It is emitted LAST (its top is the useful part, and it grows
  # without limit), and last meant it was the one always OMITTED. Reserving 1,200 bytes means the
  # goal and next action arrive even when DIGEST and the manifest would have spent everything.
  # _budget and _reserve_notes come from _cold_budget at top level — see the comment there for
  # why they cannot be computed in this subshell any more.
  # ⛔ ONE DECISION, ONE HOME. The DIGEST verdict is computed HERE, once, and BOTH the
  # announcement below and the emitter further down read these variables. It used to be decided
  # twice, the announcement recomputing it from raw sizes, and that is exactly how a 174-byte
  # file got announced as too large directly above its own full inline (eso laptop, 2026-09-08).
  # Two homes for one number is the defect; the arithmetic was never the hard part.
  _minslice="${AGENT_NOTEPAD_MIN_USEFUL_SLICE:-2000}"
  # ⛔ THE FLOOR IS FIRST IN THE CHAIN, AND ON THIS PATH IT OUTRANKS DIGEST AND THE MANIFEST.
  # ADDED with the SessionEnd(clear) wiring: until then nothing wrote a floor before a /clear and
  # nothing read one on a cold start, so both halves were missing and each one alone is useless.
  #
  # ⚠️ WHY IT RANKS HIGHER HERE THAN ON THE COMPACTION PATH. After a compaction a summary carries
  # the orientation and the floor is a safety net UNDER it. After a /clear there is no summary at
  # all — the floor is the only record of what was in flight. Same file, different worth, because
  # what survives alongside it is different.
  #
  # ⚠️ IT IS CAPPED SMALLER THAN COMPACTION'S 1,500. The cold field is tighter: the documents
  # budget is 6,300 and a real restore was measured filling ~8,830 of the ~9,600 hook cap once
  # framing is counted, so the true headroom is ~800 bytes, not 1,500. A number that fits one
  # path is not a number that fits the other — which is why this is its own knob and not a reuse
  # of _COMPACT_FLOOR_MAX.
  #
  # ⚠️ THIS IS A NEW CONSUMER AT THE FRONT OF AN ORDERED BUDGET, so it is paid for by whoever is
  # LAST — the trap this file already records one block down ("fixing one greedy consumer in a
  # priority chain just moves the waste one step down"). Here it lands on DIGEST and the manifest,
  # both of which already degrade to pointers through the verdicts below. NOTES.md is protected:
  # _nleft clamps to _reserve_notes regardless of what the earlier consumers spent.
  #
  # ⛔ AND THE INVARIANT THAT MUST NOT MOVE: cold part 2 starts at _notes_floor, which is
  # _reserve_notes and does NOT depend on _budget or on anything spent here. So adding this
  # consumer cannot shift part 2's start and cannot open a GAP — the failure that is invisible by
  # construction. A test pins it; do not "optimise" _notes_floor to track the real cut.
  _dsz=0
  [ -f "$np/DIGEST.md" ] && _dsz="$(wc -c < "$np/DIGEST.md" 2>/dev/null | tr -d ' ')"
  _dsz="${_dsz:-0}"
  _dleft=$(( _budget - _fspend - _reserve_notes ))
  _digest_mode=omit ; _dspend=0
  if [ "$_dsz" -gt 0 ]; then
    if [ "$_dleft" -le 512 ]; then
      _digest_mode=omit ; _dspend=0
    elif [ "$_dsz" -le "$_dleft" ]; then
      _digest_mode=whole ; _dspend="$_dsz"
    elif [ "$_dleft" -lt "$_minslice" ]; then
      # ⛔ A CAVEAT CUT MID-SENTENCE IS A COMPRESSED CAVEAT, and compressing one is the single
      # thing the notepad rule forbids. MEASURED 2026-09-20 on a real notepad:
      # DIGEST.md was 240,713 bytes, the cold budget left 1,036 for it, and the slice that
      # arrived broke off mid-word inside a CORRECTION, at the text "That was wrong a" - so a
      # reader could carry away the half that says the opposite of what the block concludes.
      # 0.4 percent of a document is not a document. A pointer costs ~200 bytes of framing
      # instead of the whole remaining budget, cannot be misread, and hands the bytes to NOTES.
      # ⚠️ NOTES.md deliberately gets NO such rule: it is read head-first (goal and next action
      # live at the top), so its head is useful at any size. DIGEST.md is a pile of independent
      # blocks, and that is what makes a partial one dangerous rather than merely incomplete.
      _digest_mode=pointer ; _dspend=0
    else
      _digest_mode=slice ; _dspend="$_dleft"
    fi
  fi
  # ⚠️ THE SAME VERDICT FOR THE MANIFEST, AND IT IS NOT OPTIONAL. Measured 2026-09-20: freeing
  # DIGEST alone did NOT reach NOTES.md - the manifest simply absorbed the 1,036 bytes instead,
  # and spent them on a RAW slice whose first 2,090 bytes are the $-prefixed prose about how to
  # EDIT the file. Fixing one greedy consumer in a priority chain just moves the waste one step
  # down; the rule has to hold for every document ahead of the one with the floor.
  _mraw=0
  [ -f "$np/repos.manifest.json" ] && _mraw="$(wc -c < "$np/repos.manifest.json" 2>/dev/null | tr -d ' ')"
  _mraw="${_mraw:-0}"
  _msz=0
  if [ -f "$np/repos.manifest.json" ] && command -v jq >/dev/null 2>&1; then
    _msz="$(jq -c '{repos: [ (.repos // [])[] | {name, path, remote, branch, role, note} | with_entries(select(.value != null)) ]}' "$np/repos.manifest.json" 2>/dev/null | wc -c | tr -d ' ')"
  fi
  _msz="${_msz:-0}"
  _mleft=$(( _budget - _fspend - _dspend - _reserve_notes ))
  _manifest_mode=omit ; _mspend=0
  if [ "$_mraw" -gt 0 ]; then
    if [ "$_mleft" -le 512 ]; then
      _manifest_mode=omit ; _mspend=0
    elif [ "$_msz" -gt 0 ] && [ "$_msz" -le "$_mleft" ]; then
      _manifest_mode=digest ; _mspend="$_msz"
    elif [ "$_mleft" -lt "$_minslice" ]; then
      _manifest_mode=pointer ; _mspend=0
    else
      _manifest_mode=slice ; _mspend="$_mleft"
    fi
  fi
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
    # _dspend and _mspend come from the two single decisions above -- NOT recomputed here. Using
    # the raw sizes was survivable only by accident: it made _nleft hugely negative, which clamped
    # to the reserve and happened to be the right answer for the wrong reason. With pointer
    # verdicts in play that accident stops holding, and a recomputation would disagree with the
    # emitter -- which is the exact defect the 2026-09-08 comment above this block records.
    _pre=$(( ${_fspend:-0} + ${_dspend:-0} + ${_mspend:-0} ))
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
  # Reads the ONE verdict computed with the budget above; it does not decide again.
  # ⛔ THE FLOOR IS EMITTED FIRST — ahead of DIGEST, the manifest and NOTES. It is the smallest
  # document here and the only one describing THIS machine's last few minutes rather than the
  # objective in general. On a restore after /clear it is the only such record that exists.
  if [ "${_fspend:-0}" -gt 0 ]; then
    printf '\n\n### SESSION FLOOR — %s\n\n' "$np/PRECOMPACT.md"
    _compact_chunk "$np/PRECOMPACT.md" 0 "$_fspend"
    [ "${_fsz:-0}" -gt "${_fspend:-0}" ] && printf '\n[floor CUT at ~%s of %s bytes; open the file for the rest]\n' "$_fspend" "$_fsz"
    # ⛔ THE FLOOR MUST RECORD WHAT IT SPENT. _emit_bounded derives every later document's slice
    # from `_budget - _spent - reserve`, so a consumer that emits without adding to _spent is
    # INVISIBLE to the ordered budget and every document after it is handed bytes that are
    # already gone. MEASURED 2026-09-20, the first live /clear after this branch was wired:
    # the verdict above said _digest_mode=omit (_dleft=179), the emitter recomputed 1,079 from a
    # _spent still at 0, and DIGEST.md took 1,079 UNBUDGETED bytes. Field: 10,818 against a cap
    # measured at 10 KiB (Engram `9834b409`) — so the whole of part 1 was replaced by a 2 KB
    # preview. ⚠️ THE OVERSPEND DESTROYS MORE THAN IT TAKES: 1,079 bytes of DIGEST cost the
    # handoff, the floor and the head of NOTES.md — everything the restore exists to deliver.
    # ⚠️ It also silently broke the announcement/emission contract this file states twice: the
    # banner promised NOTES.md 1,379 bytes (from _pre, which DOES count the floor) and the
    # emitter delivered 1,200. Two homes for one number, exactly as recorded three blocks up.
    _spent=$(( _spent + _fspend ))
  fi
  if [ "$_digest_mode" = "pointer" ]; then
    printf '\n\n### DIGEST.md (cross-scope, derived) — POINTER ONLY, %s bytes NOT injected\n' "$_dsz"
    printf '  Deliberate: only %s bytes of budget remained, and a slice that small ends\n' "$_dleft"
    printf '  mid-sentence. Half a caveat is worse than a pointer to the whole one, so these\n'
    printf '  bytes go to NOTES.md instead. ⛔ OPEN IT:  %s\n' "$np/DIGEST.md"
  else
    _emit_bounded "$np/DIGEST.md"         "DIGEST.md (cross-scope, derived)" "" "$_reserve_notes"
  fi
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
  # Reads the ONE verdict computed with the budget above; it does not decide again.
  if [ "$_manifest_mode" = "pointer" ]; then
    printf '\n\n### repos.manifest.json — POINTER ONLY, %s bytes NOT injected\n' "$_mraw"
    printf '  Deliberate: %s bytes of budget remained, and a raw slice that small delivers the\n' "$_mleft"
    printf '  $-prefixed editorial about how to EDIT the file rather than the repos themselves.\n'
    printf '  Those bytes go to NOTES.md instead. ⛔ OPEN IT:  %s\n' "$np/repos.manifest.json"
  else
    _emit_manifest
  fi
  _emit_bounded "$np/NOTES.md"            "NOTES.md"
); }

combined="$(_build_combined)"

# ⛔ THE BACKSTOP: MEASURE THE FIELD, DO NOT PREDICT IT.
#
# `_total` budgets the DOCUMENTS. The framing — headings, the orientation block, the 600-byte
# next-action quote, one line per OMITTED/TRUNCATED verdict — is NOT in it, varies per notepad,
# and on 2026-09-20 grew 159 bytes purely because NOTES.md was edited. So `_total` was tuned
# THREE TIMES in one session (6300 → 6100 → 6000), each time correct for the notepad in front of
# me and a guess for every other one. ⚠️ A CONSTANT CHASED REPEATEDLY IS NOT A CONSTANT; it is a
# measurement nobody is taking. This takes it: build, measure, and if the field is over the
# ceiling, hand back the overage and build again.
#
# ⛔ WHAT IT MAY NEVER TOUCH — `_reserve_notes`. The cold part 2 runs in a SEPARATE PROCESS with
# the unmodified environment, and starts at `_notes_floor` = `_reserve_notes`. If a second pass
# shrank that, part 1 would end before part 2 begins and the bytes between would be delivered by
# NEITHER hook, with nothing announcing it — the silent-loss failure this file calls invisible by
# construction. So the retry floor is `_hoff + _reserve_notes + 1`: enough that `_budget` stays
# strictly above the reserve and the `-ge` clamp inside `_cold_budget` can never fire. Part 1 then
# still delivers at least `_reserve_notes`, so the worst case is a repeated byte, never a gap.
#
# ⚠️ CEILING, not the cap. 10,240 is the best guess at the harness limit; (10,000, 10,500] was
# never verified. 9,920 is the largest payload OBSERVED to arrive whole (this notepad, the
# 2026-09-21 restore, read back out of the delivered context). Aim at what was seen to work.
_CEILING="${AGENT_NOTEPAD_FIELD_CEILING:-9900}"
_pass=0
while [ "${#combined}" -gt "$_CEILING" ] && [ "$_pass" -lt 2 ]; do
  _pass=$(( _pass + 1 ))
  _floor_total=$(( _hoff + _reserve_notes + 1 ))
  _new_total=$(( _total - ( ${#combined} - _CEILING ) - 16 ))
  [ "$_new_total" -lt "$_floor_total" ] && _new_total="$_floor_total"
  # Nothing left to give: say so in the transcript rather than spinning or silently overflowing.
  if [ "$_new_total" -ge "$_total" ]; then break; fi
  AGENT_NOTEPAD_TOTAL_BYTES="$_new_total" _cold_budget "$np"
  combined="$(_build_combined)"
done
if [ "${#combined}" -gt "$_CEILING" ]; then
  # ⚠️ ANNOUNCE THE OVERFLOW RATHER THAN SHIPPING IT QUIETLY. If the harness does drop this
  # payload the reader never sees this line — but if it squeaks through, the next session is told
  # its restore was not guaranteed, which is the only warning anyone can act on.
  _over_len="${#combined}"
  combined="$combined
[⚠️ THIS RESTORE IS $_over_len BYTES, OVER THE $_CEILING-BYTE CEILING, AND COULD NOT BE TRIMMED
 FURTHER WITHOUT MOVING THE NOTES.md RESERVE THAT COLD PART 2 STARTS FROM — which would open a
 silent gap. It may arrive as a ~2 KB preview instead. Shrink the newest handoff or NOTES.md.]"
fi

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
