#!/usr/bin/env bash
# start-agent.sh — one command per workspace: starts the watchdog, then this workspace's agent (builder or tester,
# decided by hostname in pair.yaml) in the shared root with `claude --permission-mode auto "/<start_command>"`.
# Detach with Ctrl-b then d; it keeps running. Run again after a workspace rebuild.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PC() { python3 "$KIT/kit/lib/pairconf.py" "$@"; }
ROLE="$(PC role)"
case "$ROLE" in builder|tester) ;; *) echo "This host ($(hostname)) is neither builder.host nor tester.host in $(PC path)."; exit 1 ;; esac
# tmux session name: the agent's name as a slug ("Test Agent" -> test-agent), so it is one safe word everywhere
NAME="$(PC get "$ROLE.name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+|-+$//g')"
NAME="${NAME:-$ROLE}"
CMD="/$(PC get "$ROLE.start_command")"
ROOT="$(PC get paths.shared_root)"
tmux has-session -t watchdog 2>/dev/null || tmux new -d -c "$ROOT" -s watchdog "bash $KIT/kit/scripts/agent-watchdog.sh"
if [ -t 0 ] && [ -t 1 ]; then ATTACH=1; else ATTACH=0; fi   # no terminal (e.g. `! …` from Claude): start detached
if tmux has-session -t "$NAME" 2>/dev/null; then
  [ "$ATTACH" = 1 ] && exec tmux attach -t "$NAME"
  echo "$NAME is already running in tmux session '$NAME' (attach: tmux attach -t $NAME)"; exit 0
fi
# No agent session exists, so a listener lock left by a replaced/killed agent is stale: release it, or the new agent
# stands down until it goes stale (lock_stale_minutes).
LOCK="$HOME/.claude/channel-listener/state/listener.lock"
[ -f "$LOCK" ] && { echo "released a listener lock left by the previous agent: $(head -c 200 "$LOCK")"; rm -f "$LOCK"; }
printf -v LAUNCH 'PAIR_AGENT_SESSION=%q claude --permission-mode auto %q; exec bash' "$NAME" "$CMD"
echo "starting $NAME ($ROLE): claude --permission-mode auto \"$CMD\" in tmux session '$NAME' (Ctrl-b then d to leave it running)"
if [ "$ATTACH" = 1 ]; then
  exec tmux new -c "$ROOT" -s "$NAME" "$LAUNCH"
fi
tmux new -d -c "$ROOT" -s "$NAME" "$LAUNCH"
echo "started detached — watch it: tmux attach -t $NAME"
