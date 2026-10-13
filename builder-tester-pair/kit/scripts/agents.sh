#!/usr/bin/env bash
# agents.sh — ONE command for every agent of every pair.
#
#   agents.sh status                  who is up (agent session + its watchdog), per pair
#   agents.sh start   [name ...]      start the agents that are not running
#   agents.sh stop    [name ...]      stop watchdog first, then the agent (so it is not restarted)
#   agents.sh restart [name ...]      stop, then start (a fresh process: new rules and settings are loaded)
#   add --dry-run to print what would happen.
# With no names it acts on ALL agents of ALL pairs; names are the agent names (dr-strange, wong, ultron, vision).
#
# Pairs are every $PAIRS_DIR/*/pair.yaml (default /user/shared/pairs). Each role runs as `<role>.user` (default: you) in
# `<role>.agent_home`; testers that run as another Linux user are reached with sudo. Closing terminals never stops
# anything: the agents live in detached tmux sessions. Only `stop`, or the workspace being stopped, ends them.
set -uo pipefail
KIT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"   # readlink -f: this is run via a symlink too
[ -f "$KIT/kit/lib/pairconf.py" ] || { echo "cannot find the kit next to $0 (looked in $KIT)"; exit 1; }
PAIRS_DIR="${PAIRS_DIR:-/user/shared/pairs}"
OWNER="$(id -un)"
CMD="${1:-status}"; shift || true
DRY=0; NAMES=()
for a in "$@"; do case "$a" in --dry-run|-n) DRY=1 ;; *) NAMES+=("$(echo "$a" | tr '[:upper:]' '[:lower:]')") ;; esac; done
case "$CMD" in status|start|stop|restart) ;; *) sed -n 2,13p "$0"; exit 2 ;; esac
PC() { PAIR_CONFIG="$CFG" python3 "$KIT/kit/lib/pairconf.py" "$@" 2>/dev/null; }
slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+|-+$//g'; }
as_user() {  # as_user <user> <home> <cmd...>
  local u="$1" h="$2"; shift 2
  local E=(HOME="$h" PAIR_CONFIG="$CFG" PATH="$h/.local/bin:/home/$OWNER/.local/bin:/usr/local/bin:/usr/bin:/bin")
  if [ "$u" = "$OWNER" ]; then env "${E[@]}" "$@"; else sudo -n -u "$u" -H env "${E[@]}" "$@"; fi
}
up() { as_user "$1" "$2" tmux has-session -t "$3" 2>/dev/null; }

ROWS=(); PROBLEMS=0
for CFG in "$PAIRS_DIR"/*/pair.yaml; do
  [ -f "$CFG" ] || continue
  pair="$(basename "$(dirname "$CFG")")"
  for role in builder tester; do
    name="$(slug "$(PC get "$role.name")")"; [ -n "$name" ] || continue
    if [ "${#NAMES[@]}" -gt 0 ]; then m=0; for n in "${NAMES[@]}"; do [ "$n" = "$name" ] && m=1; done; [ "$m" = 1 ] || continue; fi
    user="$(PC get "$role.user")"; user="${user:-$OWNER}"
    home="$(PC get "$role.agent_home")"; home="${home:-$(getent passwd "$user" | cut -d: -f6)}"
    stop_one() {
      for s in "watchdog-$name" "$name"; do
        if up "$user" "$home" "$s"; then
          echo "stop  $name ($pair/$role): $s"
          [ "$DRY" = 1 ] || as_user "$user" "$home" tmux kill-session -t "$s"
        fi
      done
    }
    start_one() {
      if up "$user" "$home" "$name"; then echo "ok    $name already running"; return; fi
      echo "start $name ($pair/$role) as $user"
      [ "$DRY" = 1 ] || as_user "$user" "$home" bash "$KIT/kit/scripts/start-agent.sh" </dev/null >/dev/null 2>&1 \
        || { echo "FAIL  $name did not start (run start-agent.sh by hand to see why)"; PROBLEMS=$((PROBLEMS+1)); }
    }
    case "$CMD" in
      stop)    stop_one ;;
      start)   start_one ;;
      restart) stop_one; [ "$DRY" = 1 ] || sleep 2; start_one ;;
      status)  a=down; w=down; up "$user" "$home" "$name" && a=UP; up "$user" "$home" "watchdog-$name" && w=UP
               ROWS+=("$(printf '%-12s %-9s %-8s %-8s agent=%-4s watchdog=%s' "$name" "$role" "$pair" "$user" "$a" "$w")")
               [ "$a" = UP ] && [ "$w" = UP ] || PROBLEMS=$((PROBLEMS+1)) ;;
    esac
  done
  # The pair's Argus executors / test fronts (`argus.processes` in pair.yaml): plain background processes with a pid file,
  # run as the user named for them. They are treated like agents: started, stopped and listed together.
  while IFS='|' read -r pname puser phome pstart ppid; do
    [ -n "$pname" ] || continue
    puser="${puser:-$OWNER}"; phome="${phome:-$(getent passwd "$puser" | cut -d: -f6)}"
    if [ "${#NAMES[@]}" -gt 0 ]; then m=0; for n in "${NAMES[@]}"; do [ "$n" = "$pname" ] && m=1; done; [ "$m" = 1 ] || continue; fi
    palive() { as_user "$puser" "$phome" bash -c '[ -s "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null' _ "$ppid"; }
    case "$CMD" in
      stop)    if palive; then echo "stop  $pname"; [ "$DRY" = 1 ] || as_user "$puser" "$phome" bash -c 'kill "$(cat "$1")"' _ "$ppid"; fi ;;
      start)   if palive; then echo "ok    $pname already running"; else
                 echo "start $pname as $puser"
                 [ "$DRY" = 1 ] || as_user "$puser" "$phome" bash -c "$pstart" </dev/null >/dev/null 2>&1 \
                   || { echo "FAIL  $pname did not start"; PROBLEMS=$((PROBLEMS+1)); }
               fi ;;
      restart) if palive; then echo "stop  $pname"; [ "$DRY" = 1 ] || as_user "$puser" "$phome" bash -c 'kill "$(cat "$1")"' _ "$ppid"; [ "$DRY" = 1 ] || sleep 2; fi
               echo "start $pname as $puser"
               [ "$DRY" = 1 ] || as_user "$puser" "$phome" bash -c "$pstart" </dev/null >/dev/null 2>&1 \
                 || { echo "FAIL  $pname did not start"; PROBLEMS=$((PROBLEMS+1)); } ;;
      status)  s=down; palive && s=UP
               ROWS+=("$(printf '%-12s %-9s %-8s %-8s process=%-4s %s' "${pname:0:22}" argus "$pair" "$puser" "$s" "")")
               [ "$s" = UP ] || PROBLEMS=$((PROBLEMS+1)) ;;
    esac
  done < <(PC get argus.processes | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin) or []
except Exception:
    v = []
for p in v:
    print("|".join(str(p.get(k, "")) for k in ("name", "user", "home", "start", "pidfile")))')
done
if [ "$CMD" = status ]; then
  printf '%s\n' "${ROWS[@]}"
  [ "$PROBLEMS" = 0 ] && echo "all up" || echo "$PROBLEMS agent(s) not fully up -> agents.sh start"
fi
[ "$CMD" = start ] || [ "$CMD" = restart ] && [ "$DRY" = 0 ] && echo "started; check with: agents.sh status"
exit 0
