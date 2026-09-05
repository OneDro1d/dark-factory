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
# keep looping. df-preflight checks those variables.
#
# ⚠️ CORRECTED 2026-09-04 (ESO validation run, P-4). This header used to claim the script
# "refuses to start if it reports drift". IT DOES NOT — the preflight call below is
# INFORMATIONAL on drift. The code is deliberate; the header was stale, and it is the half a
# reader skims first. **A stale claim about a SAFETY property is worse than no claim**: it gets
# relied on precisely when nobody re-reads the code underneath it.
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
# ⛔ MCP FOR THE ITERATIONS. `--setting-sources project` below loads only project-scoped
# settings, and MCP servers are configured at USER scope (~/.claude.json) — so that flag was
# silently removing EVERY MCP server from every worker. A worker booted clean with no tracker,
# no memory and no observability, and had no way to say so: it simply wrote nothing.
#
# ⚠️ THE FLAG IS RIGHT AND STAYS. It keeps ~114KB of user-level SessionStart hooks out of each
# child, which over twenty iterations is the single largest avoidable cost in the loop.
# Re-enabling user settings to get MCP back would drag the hooks back with it. MCP is passed
# EXPLICITLY instead, which composes with it.
#
# ⚠️ THE CONFIG GOES IN A PRIVATE TEMP DIR, NEVER THE MISSION DIR. It can contain LITERAL
# bearer tokens — measured on the laptop 2026-09-05, where ~/.claude.json holds real tokens and
# not the `${SYNAPSE_..._TOKEN}` references the estate's notes claim. The mission dir sits
# inside the notepad, and the notepad is pushed every session. mcp-profile-config.py refuses to
# write inside a git work tree for exactly this reason; this is the matching half.
MCPDIR="$(mktemp -d)"
chmod 700 "$MCPDIR" 2>/dev/null || true
MCP_CFG="$MCPDIR/mcp-$PROFILE.json"
MCP_OK=0
if [ -f "$SCRIPTS/mcp-profile-config.py" ]; then
  if python3 "$SCRIPTS/mcp-profile-config.py" --profile "$PROFILE" --out "$MCP_CFG"; then
    MCP_OK=1
  else
    # ⚠️ LOUD, NEVER SILENT. Running on with no MCP is a legitimate choice for a mission that
    # needs none; leaving the operator to discover it from an empty tracker is not.
    log "WARN  no MCP config for profile '$PROFILE' — iterations run with NO MCP servers."
    log "WARN  Tracker, memory and observability calls will all fail. See stderr above."
  fi
else
  log "WARN  mcp-profile-config.py not in the pinned engine — iterations run with NO MCP."
fi

trap 'rm -f "$PIDFILE"; rm -rf "$MCPDIR"' EXIT

# ── preflight — INFORMATIONAL on drift, and still never self-heals ───────────
# The headless loop has nobody to confirm a proposal with, and a loop that rewrites its
# own map will work confidently in the wrong directory for six hours. Report only.
#
# DRIFT NO LONGER ABORTS. Operator decision, 2026-09-01, after four outside installers:
# 4/4 reached LOCKED, 3/4 could not start a mission, and the reason was this gate. A kit
# ships a manifest naming its estate's repos; a fresh machine has cloned none of them; so
# drift was GUARANTEED on a first install and the kit's own worked example was unreachable.
# The gate had one level, so a repo that simply is not cloned here blocked a mission exactly
# as hard as a corrupted checkout would.
#
# ⚠️ WHAT THIS TRADES AWAY, SAID PLAINLY. A blocking gate turned "the map is wrong" into a
# stop. Informational means an iteration can now start against a partly-wrong map and burn
# budget in the wrong place. Two things bound that, and NEITHER is this gate:
#   1. Curation is now proposed (df-preflight scope.excludedRepos) so the ordinary
#      not-cloned-here case is recorded once, at install, and stops being reported at all.
#      A drift line that fires on every run is one people learn to skip, which is how a
#      real one gets skipped too.
#   2. The drift is written to preflight.json and repeated in the log every single run, so
#      it is never silently dropped.
# If a mission must not start on drift, that belongs in the MISSION's hard-stops where a
# human chose it — not as a fleet-wide default that made first runs impossible.
#
# ⚠️ STILL ABSOLUTE: an unrunnable preflight (rc>=3) aborts. That is not drift, it is the
# check itself failing, and a check that could not run is never a pass.
log "preflight (profile=$PROFILE)"
# NOT `if ! cmd; then rc=$?` — inside a negated test $? is the status of the NEGATION (0),
# so the drift branch could never be reached and the gate silently passed everything.
# Found by testing on 2026-08-22 with a real drift present. Capture rc, then branch.
python3 "$SCRIPTS/df-preflight.py" --report --profile "$PROFILE" \
        --json "$MISSION_DIR/preflight.json" >>"$LOG" 2>&1
rc=$?
case "$rc" in
  0) log "preflight clean" ;;
  1) log "preflight found DRIFT — informational, proceeding. This is not an all-clear."
     log "        Every drift row is in $MISSION_DIR/preflight.json and repeated above."
     log "        Iterations run against the map as it is, so a wrong map spends budget in"
     log "        the wrong place. Settle it interactively (/${PROFILE}-dark-factory runs the"
     log "        same probe and can apply confirmed fixes); a repo that is simply not cloned"
     log "        here can be curated out once with scope.excludedRepos and stops recurring." ;;
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
  # ⚠️ Quoted, as separate words. A split string would break on a TMPDIR containing a space,
  # and would look like a config error rather than a quoting one.
  [ "$MCP_OK" -eq 1 ] && set -- "$@" --mcp-config "$MCP_CFG" --strict-mcp-config
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
