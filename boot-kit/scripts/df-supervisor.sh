#!/usr/bin/env bash
# df-supervisor.sh — the loop that makes sessions disposable.
#
# WHY
# ---
# A Claude session cannot clear its own context window; a process cannot reset itself.
# So the SESSION becomes the disposable unit and the LOOP becomes durable. Each iteration
# is a fresh `claude -p` born with an empty window: it reads the mission map, the newest
# handoff and the tracker, claims one ticket, does it, writes state, and exits. The
# supervisor is bash — it has no context window at all, so it can run for days.
#
# This replaces the manual "handoff written, safe to /clear, paste this into a new
# session" cycle. context-budget.py already forces the handoff; its own docstring names
# what was missing: "the actual /clear is the operator's action, OR THE NEXT SCHEDULED
# TICK STARTING A FRESH SESSION." This produces those ticks.
#
# TWO SHAPES, ONE MECHANISM
#   finite mission  — loop until state=DONE (or MAX_ITER / budget)
#   standing watch  — --interval <sec>; state never reaches DONE, and the notify trigger
#                     is a confirmed finding rather than completion
#
# NO CRON ON THIS MACHINE. `crontab` is absent and `systemctl --user` reports offline, so
# the watch is a detached process with a sleep, not a timer unit. CONSEQUENCE, and it is a
# real one: a detached loop DIES SILENTLY WHEN THE WORKSPACE RESTARTS. `df-mission status`
# reads the heartbeat precisely so "nothing is running" is visible instead of assumed.
#
# ENVIRONMENT IS LOAD-BEARING
# Some MCP hub entries in ~/.claude.json authenticate with `Bearer ${SOME_TOKEN_VAR}` —
# env references expanded at launch, not literal tokens. A supervisor started from a
# stripped environment spawns children that boot cleanly, fail every ticket write, and
# keep looping. df-preflight checks those variables; this script refuses to start if it
# reports drift.
#
# Usage:
#   df-supervisor.sh --mission <dir> [--interval SEC] [--max-iter N] [--max-usd N]
set -uo pipefail

# The engine ships under boot-kit/scripts/ within whatever kit/repo installs it; two
# levels up from this script's own directory is that kit/repo's own root.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
KIT_ROOT="$(cd "$(dirname "$SELF")/../.." && pwd)"
SCRIPTS="$KIT_ROOT/boot-kit/scripts"
# Set by df-mission at launch. Running detached there is no useful cwd to discover from,
# so the kit root is the fallback and it is the WRONG scope for any other notepad.
NOTEPAD="${NOTEPAD:-$KIT_ROOT}"
export NOTEPAD

MISSION_DIR=""
INTERVAL=0                 # 0 = run back-to-back (finite mission)
MAX_ITER=25
MAX_USD=""                 # per-iteration ceiling, passed to claude --max-budget-usd
MODEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mission)  MISSION_DIR="$2"; shift 2 ;;
    --interval) INTERVAL="$2";    shift 2 ;;
    --max-iter) MAX_ITER="$2";    shift 2 ;;
    --max-usd)  MAX_USD="$2";     shift 2 ;;
    --model)    MODEL="$2";       shift 2 ;;
    *) echo "df-supervisor: unknown arg $1" >&2; exit 64 ;;
  esac
done

[ -n "$MISSION_DIR" ] || { echo "df-supervisor: --mission <dir> required" >&2; exit 64; }
[ -d "$MISSION_DIR" ] || { echo "df-supervisor: no such mission dir: $MISSION_DIR" >&2; exit 66; }

STATE="$MISSION_DIR/state"
LOG="$MISSION_DIR/supervisor.log"
HEARTBEAT="$MISSION_DIR/heartbeat"
INBOX="$MISSION_DIR/inbox"
ITERS="$MISSION_DIR/iterations"
PIDFILE="$MISSION_DIR/pid"
mkdir -p "$INBOX" "$ITERS"

PROFILE="$(cat "$MISSION_DIR/profile" 2>/dev/null || echo default)"

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# ── single supervisor per mission ────────────────────────────────────────────
# Two loops on one mission double-claim tickets and interleave handoffs. Cheap to
# prevent, expensive to debug.
if [ -f "$PIDFILE" ]; then
  old="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    echo "df-supervisor: already running for this mission (pid $old)" >&2
    exit 69
  fi
  log "stale pidfile (pid $old not running) — taking over"
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# ── preflight gate — refuse to start on drift, never self-heal ───────────────
# The headless loop has nobody to confirm a proposal with, and a loop that rewrites its
# own map will work confidently in the wrong directory for six hours. Report only.
log "preflight (profile=$PROFILE)"
# NOT `if ! cmd; then rc=$?` — inside a negated test $? is the status of the NEGATION (0),
# so the drift branch could never be reached and the gate silently passed everything.
# Found by testing on 2026-08-22 with a real drift present. Capture rc, then branch.
python3 "$SCRIPTS/df-preflight.py" --report --profile "$PROFILE" \
        --json "$MISSION_DIR/preflight.json" >>"$LOG" 2>&1
rc=$?
case "$rc" in
  0) log "preflight clean" ;;
  1) log "ABORT — preflight found drift. Fix it interactively (/${PROFILE}-dark-factory"
     log "        runs the same probe and can apply confirmed fixes), then restart."
     log "        See $MISSION_DIR/preflight.json"
     echo BLOCKED > "$STATE"
     exit 1 ;;
  2) log "preflight returned unknowns only — proceeding, see preflight.json" ;;
  *) log "ABORT — preflight itself failed (rc=$rc). An unrunnable check is not a pass."
     echo BLOCKED > "$STATE"
     exit 1 ;;
esac

[ -s "$STATE" ] || echo CONTINUE > "$STATE"

# ── the loop ─────────────────────────────────────────────────────────────────
i=0
while : ; do
  s="$(cat "$STATE" 2>/dev/null || echo CONTINUE)"
  case "$s" in
    DONE|BLOCKED) log "terminal state: $s"; break ;;
    STOP)         log "stopped by operator"; break ;;
  esac
  if [ "$i" -ge "$MAX_ITER" ]; then
    log "MAX_ITER=$MAX_ITER reached without a terminal state — stopping."
    log "This is a BACKSTOP, not a completion. Nothing here claims the mission is done."
    echo BLOCKED > "$STATE"
    break
  fi

  i=$((i + 1))
  n="$(printf '%03d' "$i")"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$HEARTBEAT"

  # Operator notes are drained INTO the prompt, then archived. This is how you steer a
  # running mission without attaching a terminal or interrupting an iteration.
  notes=""
  if [ -n "$(ls -A "$INBOX" 2>/dev/null)" ]; then
    notes="$(cat "$INBOX"/* 2>/dev/null)"
    mkdir -p "$MISSION_DIR/inbox-archive"
    mv "$INBOX"/* "$MISSION_DIR/inbox-archive/" 2>/dev/null || true
    log "drained $(printf '%s' "$notes" | wc -l) lines of operator input into iteration $n"
  fi

  prompt="$(NOTES="$notes" MISSION_DIR="$MISSION_DIR" PROFILE="$PROFILE" \
            python3 "$SCRIPTS/df-render-prompt.py")"

  set -- -p "$prompt"
  set -- "$@" --permission-mode bypassPermissions
  # Only PROJECT settings: the user-level SessionStart hooks inject ~114KB (laptop boot
  # context + full notepad restore) into every child. Twenty iterations would pay ~600k
  # tokens for context the resume prompt names explicitly anyway. Explicit beats implicit.
  set -- "$@" --setting-sources project
  set -- "$@" --output-format json
  [ -n "$MAX_USD" ] && set -- "$@" --max-budget-usd "$MAX_USD"
  [ -n "$MODEL" ]   && set -- "$@" --model "$MODEL"

  log "iteration $n starting"
  ( cd "$NOTEPAD" && claude "$@" ) >"$ITERS/$n.json" 2>"$ITERS/$n.err"
  rc=$?
  log "iteration $n exited rc=$rc  state=$(cat "$STATE" 2>/dev/null || echo '?')"

  # Budget termination is NOT a crash, and conflating them is dangerous in both directions.
  # A child killed at the cap has done real work whose evidence was never written — the
  # existing doctrine is explicit that a `budget` terminal_reason means UNVERIFIED work, so
  # raising the cap and re-running is right and "two strikes then BLOCKED" is wrong. The
  # first smoke test hit this: rc=1, subtype=error_max_budget_usd, cost 3.05 against a 3.00
  # cap, while the iteration had already written DONE.
  subtype="$(jq -r '.subtype // empty' "$ITERS/$n.json" 2>/dev/null || true)"
  if [ "$subtype" = "error_max_budget_usd" ]; then
    log "iteration $n hit the per-iteration budget cap — its work is UNVERIFIED."
    log "  Raise --max-usd and re-run; never lower it. A run killed at 90% wastes"
    log "  everything already spent, so the last few dollars are the cheap ones."
    echo BLOCKED > "$STATE"
    break
  fi

  # A child that dies WITHOUT moving the state is the dangerous case: the loop would spin
  # on an unchanged world, burning budget and learning nothing. Two strikes, then stop.
  if [ "$rc" != "0" ]; then
    fails=$((${fails:-0} + 1))
    if [ "$fails" -ge 2 ]; then
      log "two consecutive non-zero iterations — stopping rather than spinning."
      echo BLOCKED > "$STATE"
      break
    fi
  else
    fails=0
  fi

  if [ "$INTERVAL" -gt 0 ]; then
    log "watch mode — sleeping ${INTERVAL}s"
    sleep "$INTERVAL"
  fi
done

date -u +%Y-%m-%dT%H:%M:%SZ > "$HEARTBEAT"
final="$(cat "$STATE" 2>/dev/null || echo '?')"
log "supervisor exiting after $i iterations — final state: $final"

# ── notify: the 2-trigger contract (VR-5) ────────────────────────────────────
# Always write the local record FIRST. A notification that only exists if an outbound
# call succeeds is a notification you cannot rely on.
{
  printf '%s  mission=%s  state=%s  iterations=%d\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$MISSION_DIR")" "$final" "$i"
} >> "$MISSION_DIR/notifications.log"

if [ -x "$SCRIPTS/df-notify.sh" ]; then
  if ! "$SCRIPTS/df-notify.sh" "$MISSION_DIR" "$final" "$i" >>"$LOG" 2>&1; then
    log "notify failed — the local record in notifications.log still stands"
    # Put the failure where the operator actually looks. `df-mission status` reads
    # notifications.log; the supervisor log is 12 tailed lines nobody greps. Without this
    # the record says the mission ended and stays silent about nobody having been told,
    # which is the same shape as the false-done this whole loop exists to prevent.
    printf '%s  mission=%s  NOTIFY-FAILED  state=%s  channel=%s  (nobody was told — see %s)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" "$final" "${CHANNEL:-unset}" "$LOG" \
      >>"$MISSION_DIR/notifications.log" 2>/dev/null || true
  fi
fi
