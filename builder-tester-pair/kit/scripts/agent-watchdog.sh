#!/usr/bin/env bash
# agent-watchdog.sh — keeps this workspace's agent (builder or tester, from pair.yaml) running unattended.
# Runs in its own tmux session "watchdog-<agent>", started by start-agent.sh. No cron needed.
#  - every minute: a pending chat restart request ("<name> restart" → kit/bin/restart-request) → after 30 s, a
#    fresh claude process. Message ids already honoured are kept, so a re-read never restarts again.
#  - every 10 min: if the agent's tmux session is gone, or claude has exited, start it again
#  - at schedule.fresh_start_utc hours: replace the agent with a FRESH claude process (fresh context AND a fresh
#    usage allowance; /clear alone keeps the old process, which refuses all work once its budget is used up)
#  - builder only, if paths.heartbeat is set: a heartbeat file older than schedule.stall_minutes means the loop
#    stopped → fresh process, at most once per 2 h
# Survives the owner being locked out of the workspace UI; not a workspace rebuild (then run start-agent.sh once).
# Log: ~/.cache/agent-watchdog.log    Stop: tmux kill-session -t watchdog-<agent>   (~ = the agent's own HOME)
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PC() { python3 "$KIT/kit/lib/pairconf.py" "$@"; }
ROLE="$(PC role)"
case "$ROLE" in builder|tester) ;; *) echo "this host is neither builder.host nor tester.host in pair.yaml"; exit 1 ;; esac
# tmux session name: the agent's name as a slug ("Test Agent" -> test-agent), so it is one safe word everywhere
NAME="$(PC get "$ROLE.name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+|-+$//g')"
NAME="${NAME:-$ROLE}"
CMD="/$(PC get "$ROLE.start_command")"
ROOT="$(PC get paths.shared_root)"
HOURS="$(PC get schedule.fresh_start_utc | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin) or []))' 2>/dev/null)"
STALL_MIN="$(PC get schedule.stall_minutes)"; STALL_MIN="${STALL_MIN:-0}"
HEARTBEAT=""; [ "$ROLE" = builder ] && HEARTBEAT="$(PC get paths.heartbeat)"
STALL_COOLDOWN_MIN=120
# HOME and PAIR_CONFIG are passed explicitly: tmux starts commands from the tmux server's environment, not ours, and a
# workspace can hold several agents (each with its own HOME, see agent-home.sh) that must never read each other's pair.yaml.
UMASK_PFX=""; [ -n "$(PC get paths.share_group)" ] && UMASK_PFX="umask 002; "   # builder+tester as 2 users in one workspace
printf -v LAUNCH '%sHOME=%q PAIR_CONFIG=%q PAIR_AGENT_SESSION=%q claude --permission-mode auto %q; exec bash' "$UMASK_PFX" "$HOME" "$(PC path)" "$NAME" "$CMD"
LOG="$HOME/.cache/agent-watchdog.log"; mkdir -p "$(dirname "$LOG")"
STAMP="$HOME/.cache/agent-watchdog.last-refresh"
LAST_STALL="$HOME/.cache/agent-watchdog.last-stall-refresh"
REQ="$HOME/.cache/agent-watchdog.restart-request"
DONE_IDS="$HOME/.cache/agent-watchdog.restart-done"
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
age_min() { [ -f "$1" ] && echo $(( ( $(date +%s) - $(stat -c %Y "$1") ) / 60 )) || echo 999999; }

# a fresh process, started in the shared root so the project's .mcp.json, CLAUDE.md and pair.yaml load
# The process being replaced may hold the channel-listener lock; it is gone after this, so release the lock or the
# new agent stands down until the lock goes stale (lock_stale_minutes).
LOCK="$HOME/.claude/channel-listener/state/listener.lock"
release_lock() { [ -f "$LOCK" ] && { log "released listener lock of the replaced process: $(head -c 200 "$LOCK")"; rm -f "$LOCK"; }; return 0; }
refresh() { release_lock; tmux respawn-pane -k -c "$ROOT" -t "$NAME" "$LAUNCH"; }

check_restart_request() {
  [ -f "$REQ" ] || return 0
  [ $(( $(date +%s) - $(stat -c %Y "$REQ") )) -ge 30 ] || return 0
  local id; id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$REQ" 2>/dev/null)
  rm -f "$REQ"
  if [ -z "$id" ]; then log "restart request unreadable — dropped"; return 0; fi
  if grep -qxF "$id" "$DONE_IDS" 2>/dev/null; then log "restart request $id already honoured — dropped"; return 0; fi
  echo "$id" >> "$DONE_IDS"
  if tmux has-session -t "$NAME" 2>/dev/null; then log "restart requested from chat ($id) — fresh $CMD in $NAME"; refresh; fi
}

is_fresh_hour() { for h in $HOURS; do [ "$(date -u +%H)" = "$h" ] && return 0; done; return 1; }

log "watchdog started for $NAME ($ROLE)"
n=0
while true; do
  check_restart_request
  if [ $(( n++ % 10 )) -ne 0 ]; then sleep 60; continue; fi
  if ! tmux has-session -t "$NAME" 2>/dev/null; then
    log "session $NAME missing — starting $CMD"
    release_lock
    tmux new -d -c "$ROOT" -s "$NAME" "$LAUNCH"
    date -u +%F-%H > "$STAMP"
  elif ! pgrep -x claude -P "$(tmux display -p -t "$NAME" '#{pane_pid}')" >/dev/null; then
    log "claude not running in $NAME — fresh $CMD"
    refresh
    date -u +%F-%H > "$STAMP"
  elif is_fresh_hour && [ "$(cat "$STAMP" 2>/dev/null)" != "$(date -u +%F-%H)" ]; then
    log "scheduled fresh start: $CMD in $NAME"
    refresh
    date -u +%F-%H > "$STAMP"
  elif [ -n "$HEARTBEAT" ] && [ "$STALL_MIN" -gt 0 ] && [ "$(age_min "$HEARTBEAT")" -gt "$STALL_MIN" ] \
       && [ "$(age_min "$LAST_STALL")" -gt "$STALL_COOLDOWN_MIN" ]; then
    log "heartbeat $HEARTBEAT is $(age_min "$HEARTBEAT") min old — loop stalled, fresh $CMD"
    refresh
    touch "$LAST_STALL"
  fi
  sleep 60
done
