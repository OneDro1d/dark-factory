#!/usr/bin/env bash
# mission-tick.sh — background monitor for objective 5 (a cron tick reminds the agent
# a mission is unfinished). Declared in monitors/monitors.json as "always", so a fresh
# session (including one started by /clear) starts a new copy of this loop.
#
# STRICTLY READ-ONLY. This script only reads state files and prints lines to stdout —
# it never writes under .df/ or the notepad, and it must never gain mkdir, touch, rm,
# mv, tee, sed -i, or a shell write redirection. tests/test-mission-tick.sh asserts
# this statically. Generic on purpose: no estate names, hosts, people, or machine paths.
set -u

# Walk UP from $PWD looking for NOTES.md — the notepad root marker. $PWD is the
# session working directory the monitor starts in, per the monitors doc.
find_notepad() {
  local dir="$PWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/NOTES.md" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

tick_once() {
  local notepad f id iso now mt mins
  notepad="$(find_notepad)" || return 0
  for f in "$notepad"/.df/missions/*/state; do
    [ -f "$f" ] || continue
    [ "$(head -n1 "$f")" = "RUNNING" ] || continue
    id="${f%/state}"
    id="${id##*/}"
    iso="$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ)"
    now="$(date +%s)"
    mt="$(date -r "$f" +%s)"
    mins=$(( (now - mt) / 60 ))
    printf 'mission-tick: %s is RUNNING (state written %s, %s min ago) — read MAP.md, take the frontier ticket, or mark the state DONE\n' "$id" "$iso" "$mins"
  done
}

while true; do
  tick_once
  [ "${DF_TICK_ONCE:-0}" = "1" ] && exit 0
  sleep "${DF_TICK_SECONDS:-1020}"
done
